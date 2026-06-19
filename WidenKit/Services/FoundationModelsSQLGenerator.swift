#if canImport(FoundationModels)

    import Foundation
    import FoundationModels

    /// Structured output schema for the on-device model. Mirrors
    /// `SQLGenerationResult`, with guides keeping the model inside the rails.
    @Generable(description: "A single safe PostgreSQL statement answering the user's question.")
    struct GeneratedSQLResponse {
        @Guide(
            description:
                "Exactly one PostgreSQL statement: a SELECT/WITH read, or an INSERT/UPDATE/DELETE write only when the user asks to modify data. No semicolons, no DDL, only tables and columns from the provided schema. For average counts per day, use a CTE/subquery and never AVG(COUNT(...)) or DAY(...).")
        var sql: String

        @Guide(description: "One or two sentences explaining what the query does.")
        var explanation: String

        @Guide(
            description: "Assumptions made about ambiguous parts of the question.",
            .maximumCount(5))
        var assumptions: [String]

        @Guide(
            description: "Schema-qualified table names used by the query, e.g. public.users.",
            .maximumCount(10))
        var referencedTables: [String]

        @Guide(
            description: "Confidence that the query answers the question, between 0 and 1.",
            .range(0.0...1.0))
        var confidence: Double

        @Guide(
            description: "Risk that the query is slow or wrong.",
            .anyOf(["low", "medium", "high"]))
        var riskLevel: String

        @Guide(
            description: "True only if the question cannot be answered with the provided schema.")
        var needsClarification: Bool

        @Guide(description: "A short clarifying question when needsClarification is true.")
        var clarificationQuestion: String?
    }

    @Generable(description: "Schema search queries needed before SQL generation.")
    struct GeneratedSchemaDiscoveryResponse {
        @Guide(
            description: "Short schema search phrases, not SQL. Use table, column, metric, and relationship words.",
            .maximumCount(3))
        var searchQueries: [String]

        @Guide(description: "One short sentence explaining why these schema searches are needed.")
        var reason: String
    }

    /// Generates SQL with Apple's on-device Foundation Model. Local-only: no
    /// network, no external LLM APIs.
    public final class FoundationModelsSQLGenerator: SQLGenerator, Sendable {
        public init() {}

        /// nil when the model is ready; otherwise a user-readable reason.
        public static var availabilityMessage: String? {
            switch SystemLanguageModel.default.availability {
            case .available:
                nil
            case .unavailable(let reason):
                message(for: reason)
            }
        }

        public func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw AppError.modelUnavailable(Self.message(for: reason))
            }

            do {
                return try await respond(
                    question: question, schema: schema, context: context, config: config,
                    model: model, maxSchemaCharacters: 8_000, inputScale: 1.0,
                    allowDiscovery: true)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    // Retry once with a smaller whole-prompt target while
                    // preserving the same deterministic ranking and pins.
                    do {
                        return try await respond(
                            question: question, schema: schema, context: context, config: config,
                            model: model, maxSchemaCharacters: 8_000, inputScale: 0.8,
                            allowDiscovery: true)
                    } catch let retryError as LanguageModelSession.GenerationError {
                        throw Self.map(retryError)
                    }
                }
                throw Self.map(error)
            }
        }

        private func respond(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig,
            model: SystemLanguageModel,
            maxSchemaCharacters: Int,
            inputScale: Double,
            allowDiscovery: Bool
        ) async throws -> SQLGenerationResult {
            // A fresh session per request keeps the context window small and
            // the generation stateless; follow-up awareness comes from the
            // compact context section in the prompt instead.
            let instructions = SQLPromptBuilder.compactInstructions(
                defaultRowLimit: config.defaultRowLimit
            )
            let generationContext = try await contextWithOptionalDiscovery(
                question: question,
                schema: schema,
                context: context,
                config: config,
                model: model,
                instructions: instructions,
                maxSchemaCharacters: maxSchemaCharacters,
                inputScale: inputScale,
                allowDiscovery: allowDiscovery
            )
            let session = LanguageModelSession(
                model: model,
                instructions: instructions
            )
            let bundle = try promptBundle(
                question: question,
                schema: schema,
                context: generationContext,
                databaseContext: config.databaseContext,
                instructions: instructions,
                maxSchemaCharacters: maxSchemaCharacters,
                inputScale: inputScale
            )
            let prompt = bundle.prompt
            let started = Date()
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedSQLResponse.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
                )
                let result = Self.result(from: response.content)
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: result.logDescription,
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000))
                return result
            } catch {
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: "error: \(error)",
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000))
                throw error
            }
        }

        private func contextWithOptionalDiscovery(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig,
            model: SystemLanguageModel,
            instructions: String,
            maxSchemaCharacters: Int,
            inputScale: Double,
            allowDiscovery: Bool
        ) async throws -> SQLGenerationContext {
            guard allowDiscovery,
                context.mode == .initial || context.mode == .followUp
            else { return context }

            let initialBundle = try promptBundle(
                question: question,
                schema: schema,
                context: context,
                databaseContext: config.databaseContext,
                instructions: instructions,
                maxSchemaCharacters: maxSchemaCharacters,
                inputScale: inputScale,
                throwIfOversized: false
            )
            let budget = PromptBudget.localFoundationModels
            let shouldDiscover =
                schema.tables.count > 25
                || !budget.fits(
                    inputCharacters: instructions.count + initialBundle.prompt.count,
                    scale: inputScale
                )
            guard shouldDiscover else { return context }

            let discoveryCharacters = min(
                5_000,
                budget.schemaCharacterAllowance(
                    fixedPromptCharacters: instructions.count + question.count + config.databaseContext.count + 1_000,
                    scale: inputScale
                )
            )
            let catalog = SchemaDiscoveryService.compactCatalog(
                schema: schema,
                question: question,
                databaseContext: config.databaseContext,
                maxCharacters: discoveryCharacters
            )
            let discoveryPrompt = [
                "<schema_discovery_task>",
                SQLPromptBuilder.taggedCDATASectionForGenerator("user_request", question),
                SQLPromptBuilder.taggedCDATASectionForGenerator("schema_catalog", catalog),
                SQLPromptBuilder.taggedCDATASectionForGenerator(
                    "instruction",
                    "Return up to 3 short schema search queries that Widen should use to retrieve detailed table definitions. Do not write SQL."
                ),
                "</schema_discovery_task>",
            ].joined(separator: "\n")

            guard budget.fits(
                inputCharacters: instructions.count + discoveryPrompt.count,
                scale: inputScale
            ) else {
                return context
            }

            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: instructions
                )
                let response = try await session.respond(
                    to: discoveryPrompt,
                    generating: GeneratedSchemaDiscoveryResponse.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)
                )
                let discovery = SchemaDiscoveryRequestResult(
                    searchQueries: response.content.searchQueries,
                    reason: response.content.reason
                )
                let queries = discovery.sanitizedSearchQueries
                guard !queries.isEmpty else { return context }
                let searchResults = SchemaDiscoveryService.search(schema: schema, queries: queries)
                guard !searchResults.isEmpty else { return context }
                var copy = context
                copy.schemaSearchQueries = queries + searchResults.map(\.qualifiedName)
                return copy
            } catch {
                return context
            }
        }

        private func promptBundle(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            databaseContext: String,
            instructions: String,
            maxSchemaCharacters: Int,
            inputScale: Double,
            throwIfOversized: Bool = true
        ) throws -> SQLPromptBuilder.PromptBundle {
            let budget = PromptBudget.localFoundationModels
            let fixedPromptCharacters =
                instructions.count
                + question.count
                + databaseContext.count
                + context.recentQuestions.joined(separator: "\n").count
                + (context.originalQuestion?.count ?? 0)
                + context.conversationMessages.map(\.text.count).reduce(0, +)
                + (context.currentSQL?.count ?? 0)
                + (context.lastRunError?.count ?? 0)
                + (context.repairContext?.failedSQL?.count ?? 0)
                + (context.repairContext?.diagnostic?.displayMessage.count ?? 0)
                + context.schemaSearchQueries.joined(separator: "\n").count
                + 1_600
            var schemaCharacters = min(
                maxSchemaCharacters,
                budget.schemaCharacterAllowance(
                    fixedPromptCharacters: fixedPromptCharacters,
                    scale: inputScale
                )
            )
            var latest = SQLPromptBuilder.promptBundle(
                question: question,
                schema: schema,
                context: context,
                databaseContext: databaseContext,
                maxSchemaCharacters: schemaCharacters
            )
            for _ in 0..<4 {
                let inputCharacters = instructions.count + latest.prompt.count
                if budget.fits(inputCharacters: inputCharacters, scale: inputScale) {
                    return latest
                }
                let allowed = budget.inputCharacterAllowance(scale: inputScale)
                let excess = max(0, inputCharacters - allowed)
                let nextSchemaCharacters = max(500, schemaCharacters - excess - 500)
                guard nextSchemaCharacters < schemaCharacters else { break }
                schemaCharacters = nextSchemaCharacters
                latest = SQLPromptBuilder.promptBundle(
                    question: question,
                    schema: schema,
                    context: context,
                    databaseContext: databaseContext,
                    maxSchemaCharacters: schemaCharacters
                )
            }

            if throwIfOversized {
                throw AppError.modelGenerationFailed(
                    Self.contextWindowMessage(package: latest.schemaPackage)
                )
            }
            return latest
        }

        /// Shared with `PrivateCloudComputeSQLGenerator`, which produces the
        /// same structured response from the server-side model.
        static func result(from generated: GeneratedSQLResponse) -> SQLGenerationResult {
            SQLGenerationResult(
                sql: generated.sql.trimmingCharacters(in: .whitespacesAndNewlines),
                explanation: generated.explanation,
                assumptions: generated.assumptions,
                referencedTables: generated.referencedTables,
                confidence: min(max(generated.confidence, 0), 1),
                riskLevel: SQLRiskLevel(rawValue: generated.riskLevel) ?? .medium,
                needsClarification: generated.needsClarification,
                clarificationQuestion: generated.clarificationQuestion
            )
        }

        private static func contextWindowMessage(package: SchemaPromptPackage) -> String {
            let tables = package.includedTables.prefix(6).joined(separator: ", ")
            let tableText = tables.isEmpty ? "the selected schema" : tables
            return
                "The local model needs narrower schema context before it can safely generate SQL. Relevant tables selected: \(tableText). Try adding more database context, choosing a narrower schema, or using the cloud model for this request."
        }

        /// Shared with `PrivateCloudComputeSQLGenerator`.
        static func map(_ error: LanguageModelSession.GenerationError) -> AppError {
            switch error {
            case .exceededContextWindowSize:
                .modelGenerationFailed(
                    "The schema and question exceed the local model's context window. Try a smaller database or a shorter question."
                )
            case .assetsUnavailable:
                .modelUnavailable(
                    "Model assets are not downloaded yet. Check Apple Intelligence in System Settings and try again."
                )
            case .guardrailViolation:
                .modelGenerationFailed(
                    "The request was blocked by Apple's safety guardrails. Try rephrasing the question."
                )
            case .unsupportedLanguageOrLocale:
                .modelGenerationFailed("This language is not supported by the local model.")
            case .rateLimited, .concurrentRequests:
                .modelGenerationFailed("The local model is busy. Try again in a moment.")
            case .refusal:
                .modelGenerationFailed("The local model declined to answer. Try rephrasing the question.")
            case .decodingFailure, .unsupportedGuide:
                .modelGenerationFailed(error.errorDescription ?? "Generation failed.")
            @unknown default:
                .modelGenerationFailed(error.errorDescription ?? "Generation failed.")
            }
        }

        private static func message(
            for reason: SystemLanguageModel.Availability.UnavailableReason
        ) -> String {
            let detail =
                switch reason {
                case .deviceNotEligible:
                    "This Mac does not support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    "Apple Intelligence is turned off. Enable it in System Settings › Apple Intelligence & Siri."
                case .modelNotReady:
                    "The local model is still downloading or preparing. Try again shortly."
                @unknown default:
                    "The local model is unavailable for an unknown reason."
                }
            return "Local Apple model is unavailable. You can still write SQL manually, or enable mock mode for development. (\(detail))"
        }
    }

#endif
