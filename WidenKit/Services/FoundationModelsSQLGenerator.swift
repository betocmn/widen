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

    struct LocalSQLDecision: Equatable, Sendable {
        enum Action: String, Equatable, Sendable {
            case generateSQL
            case clarify
        }

        var action: Action
        var sql: String
        var clarificationQuestion: String?

        init(generated: GeneratedSQLResponse) {
            let trimmedSQL = generated.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            let clarification = generated.clarificationQuestion?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if generated.needsClarification || (trimmedSQL.isEmpty && clarification?.isEmpty == false) {
                self.action = .clarify
                self.sql = ""
                self.clarificationQuestion = clarification
            } else {
                self.action = .generateSQL
                self.sql = trimmedSQL
                self.clarificationQuestion = clarification
            }
        }
    }

    /// Generates SQL with Apple's on-device Foundation Model. Local-only: no
    /// network, no external LLM APIs.
    public final class FoundationModelsSQLGenerator: ConstrainedLocalSQLGenerator, Sendable {
        private static let maxModelCalls = GeneratedSQLRepairSupport.constrainedLocalModelCallBudget
        private static let maxDetailedSchemaTables = 4

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

        static func cumulativeModelCallCountAfterContextRetry(
            startingModelCallCount: Int,
            failedAttemptSpentCalls: Int,
            retrySpentCalls: Int
        ) -> Int {
            max(0, startingModelCallCount)
                + max(0, failedAttemptSpentCalls)
                + max(0, retrySpentCalls)
        }

        struct SQLResponseModelCallAccounting: Equatable {
            var startingModelCalls: Int
            var discoveryCallsSpent: Int
            var cumulativeModelCallsAfterSQL: Int
            var spentModelCalls: Int
            var exceedsBudget: Bool
        }

        static func canStartSQLResponse(startingModelCallCount: Int) -> Bool {
            max(0, startingModelCallCount) < maxModelCalls
        }

        static func canRetryAfterContextWindow(
            startingModelCallCount: Int,
            failedAttemptSpentCalls: Int
        ) -> Bool {
            max(0, startingModelCallCount) + max(0, failedAttemptSpentCalls) < maxModelCalls
        }

        static func sqlResponseModelCallAccounting(
            startingModelCallCount: Int,
            generationContextModelCallCount: Int
        ) -> SQLResponseModelCallAccounting {
            let startingModelCalls = max(0, startingModelCallCount)
            let discoveryCallsSpent = max(
                0,
                max(0, generationContextModelCallCount) - startingModelCalls
            )
            let cumulativeModelCallsAfterSQL = startingModelCalls + discoveryCallsSpent + 1
            return SQLResponseModelCallAccounting(
                startingModelCalls: startingModelCalls,
                discoveryCallsSpent: discoveryCallsSpent,
                cumulativeModelCallsAfterSQL: cumulativeModelCallsAfterSQL,
                spentModelCalls: cumulativeModelCallsAfterSQL - startingModelCalls,
                exceedsBudget: cumulativeModelCallsAfterSQL > maxModelCalls
            )
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
                throw SQLGenerationFailure.backendUnavailable(Self.message(for: reason))
            }

            do {
                return try await respond(
                    question: question, schema: schema, context: context, config: config,
                    model: model, maxSchemaCharacters: 8_000, inputScale: 1.0,
                    allowDiscovery: true
                ).result
            } catch let error as GenerationAttemptError {
                if case .exceededContextWindowSize = error.error {
                    guard Self.canRetryAfterContextWindow(
                        startingModelCallCount: context.modelCallCount,
                        failedAttemptSpentCalls: error.spentModelCalls
                    ) else {
                        throw Self.map(error.error)
                    }
                    // Retry once with a smaller whole-prompt target. Discovery is
                    // skipped here so a context-window retry cannot spend another
                    // model call before SQL generation.
                    do {
                        let retry = try await respond(
                            question: question, schema: schema, context: context, config: config,
                            model: model, maxSchemaCharacters: 8_000, inputScale: 0.8,
                            allowDiscovery: false)
                        var result = retry.result
                        result.generationCallCount =
                            Self.cumulativeModelCallCountAfterContextRetry(
                                startingModelCallCount: context.modelCallCount,
                                failedAttemptSpentCalls: error.spentModelCalls,
                                retrySpentCalls: retry.spentModelCalls
                            )
                        return result
                    } catch let retryError as GenerationAttemptError {
                        throw Self.map(retryError.error)
                    }
                }
                throw Self.map(error.error)
            }
        }

        private struct GenerationAttempt {
            var result: SQLGenerationResult
            var spentModelCalls: Int
        }

        private struct GenerationAttemptError: Error {
            var error: LanguageModelSession.GenerationError
            var spentModelCalls: Int
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
        ) async throws -> GenerationAttempt {
            let startingModelCalls = max(0, context.modelCallCount)
            guard Self.canStartSQLResponse(startingModelCallCount: startingModelCalls) else {
                throw Self.localModelCallBudgetFailure()
            }
            // A fresh session per request keeps the context window small and
            // the generation stateless; follow-up awareness comes from the
            // compact context section in the prompt instead.
            let instructions = SQLPromptBuilder.compactInstructions(
                defaultRowLimit: config.defaultRowLimit
            )
            var generationContext = try await contextWithOptionalDiscovery(
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
            try Task.checkCancellation()
            let accounting = Self.sqlResponseModelCallAccounting(
                startingModelCallCount: startingModelCalls,
                generationContextModelCallCount: generationContext.modelCallCount
            )
            guard !accounting.exceedsBudget else {
                throw Self.localModelCallBudgetFailure()
            }
            generationContext.modelCallCount = accounting.cumulativeModelCallsAfterSQL
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
                var result = Self.result(from: response.content)
                result.generationCallCount = accounting.cumulativeModelCallsAfterSQL
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: result.logDescription,
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                    telemetry: PromptTelemetry(
                        phase: generationContext.mode,
                        package: bundle.schemaPackage,
                        context: generationContext,
                        callCount: generationContext.modelCallCount,
                        stopReason: result.needsClarification ? "clarification" : "success"
                    ))
                return GenerationAttempt(result: result, spentModelCalls: accounting.spentModelCalls)
            } catch let error as LanguageModelSession.GenerationError {
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: "error: \(error)",
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                    telemetry: PromptTelemetry(
                        phase: generationContext.mode,
                        package: bundle.schemaPackage,
                        context: generationContext,
                        callCount: generationContext.modelCallCount,
                        stopReason: "error"
                    ))
                throw GenerationAttemptError(error: error, spentModelCalls: accounting.spentModelCalls)
            } catch {
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: "error: \(error)",
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                    telemetry: PromptTelemetry(
                        phase: generationContext.mode,
                        package: bundle.schemaPackage,
                        context: generationContext,
                        callCount: generationContext.modelCallCount,
                        stopReason: "error"
                    ))
                throw error
            }
        }

        private static func localModelCallBudgetFailure() -> SQLGenerationFailure {
            SQLGenerationFailure.generation(
                "On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud."
            )
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
                context.mode == .initial || context.mode == .followUp,
                Self.canSpendOptionalDiscoveryCall(context: context)
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
            let shouldDiscover = Self.needsSchemaDiscovery(
                question: question,
                schema: schema,
                databaseContext: config.databaseContext,
                instructions: instructions,
                initialPromptCharacters: initialBundle.prompt.count,
                inputScale: inputScale
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
                var copy = context
                copy.modelCallCount = max(0, context.modelCallCount) + 1
                guard !queries.isEmpty else { return copy }
                let searchResults = SchemaDiscoveryService.search(
                    schema: schema,
                    queries: queries,
                    limit: Self.maxDetailedSchemaTables
                )
                guard !searchResults.isEmpty else { return copy }
                copy.schemaSearchQueries = queries + searchResults.map(\.qualifiedName)
                return copy
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var copy = context
                copy.modelCallCount = max(0, context.modelCallCount) + 1
                return copy
            }
        }

        private static func needsSchemaDiscovery(
            question: String,
            schema: DatabaseSchema,
            databaseContext: String,
            instructions: String,
            initialPromptCharacters: Int,
            inputScale: Double
        ) -> Bool {
            let budget = PromptBudget.localFoundationModels
            if !budget.fits(
                inputCharacters: instructions.count + initialPromptCharacters,
                scale: inputScale
            ) {
                return true
            }
            if schema.tables.count > 25 {
                return true
            }
            guard schema.tables.count > 8 else {
                return false
            }
            return !hasConfidentDeterministicCoverage(
                question: question,
                schema: schema,
                databaseContext: databaseContext
            )
        }

        private static func hasConfidentDeterministicCoverage(
            question: String,
            schema: DatabaseSchema,
            databaseContext: String
        ) -> Bool {
            let ranked = SchemaRelevanceRanker.rank(
                schema: schema,
                input: SchemaRankingInput(question: question, databaseContext: databaseContext)
            )
            guard let top = ranked.first, top.score >= 150 else { return false }
            let schemaTokens = schema.tables.reduce(into: Set<String>()) { result, table in
                result.formUnion(SchemaIndex.tokens(in: table.schema))
                result.formUnion(SchemaIndex.tokens(in: table.name))
                for column in table.columns {
                    result.formUnion(SchemaIndex.tokens(in: column.name))
                    for constraint in column.valueConstraints ?? [] {
                        for value in constraint.values {
                            result.formUnion(SchemaIndex.tokens(in: value))
                        }
                    }
                }
            }.union(Set(SchemaIndex.tokens(in: databaseContext)))

            let requiredTokens = Set(SchemaIndex.tokens(in: question))
                .subtracting(discoveryStopWords)
                .filter { !$0.allSatisfy(\.isNumber) }
            guard !requiredTokens.isEmpty else { return true }
            return requiredTokens.allSatisfy { token in
                schemaTokens.contains(token)
                    || schemaTokens.contains { candidate in
                        token.count >= 4
                            && (candidate.hasPrefix(token) || token.hasPrefix(candidate))
                    }
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
                maxSchemaCharacters: schemaCharacters,
                maxPrimarySchemaTables: Self.maxDetailedSchemaTables,
                maxDetailedSchemaTables: Self.maxDetailedSchemaTables
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
                    maxSchemaCharacters: schemaCharacters,
                    maxPrimarySchemaTables: Self.maxDetailedSchemaTables,
                    maxDetailedSchemaTables: Self.maxDetailedSchemaTables
                )
            }

            if throwIfOversized {
                throw SQLGenerationFailure.contextWindow(
                    Self.contextWindowMessage(package: latest.schemaPackage)
                )
            }
            return latest
        }

        static func canSpendOptionalDiscoveryCall(context: SQLGenerationContext) -> Bool {
            max(0, context.modelCallCount) < maxModelCalls - 1
        }

        /// Shared with `PrivateCloudComputeSQLGenerator`, which produces the
        /// same structured response from the server-side model.
        static func result(from generated: GeneratedSQLResponse) -> SQLGenerationResult {
            let decision = LocalSQLDecision(generated: generated)
            return SQLGenerationResult(
                sql: decision.sql,
                explanation: generated.explanation,
                assumptions: generated.assumptions,
                referencedTables: generated.referencedTables,
                confidence: min(max(generated.confidence, 0), 1),
                riskLevel: SQLRiskLevel(rawValue: generated.riskLevel) ?? .medium,
                needsClarification: decision.action == .clarify,
                clarificationQuestion: decision.clarificationQuestion
            )
        }

        private static let discoveryStopWords: Set<String> = [
            "a", "about", "after", "all", "and", "any", "are", "as", "at", "be", "by",
            "can", "could", "day", "days", "do", "does", "each", "for", "from", "get",
            "give", "have", "how", "i", "in", "is", "it", "last", "latest", "limit",
            "list", "me", "month", "months", "most", "newest", "of", "on", "or", "our",
            "over", "per", "please", "recent", "show", "since", "sort", "the", "this",
            "to", "top", "us", "week", "weeks", "what", "when", "where", "which", "with",
            "year", "years",
        ]

        private static func contextWindowMessage(package: SchemaPromptPackage) -> String {
            let tables = package.includedTables.prefix(6).joined(separator: ", ")
            let tableText = tables.isEmpty ? "the selected schema" : tables
            return
                "The local model needs narrower schema context before it can safely generate SQL. Relevant tables selected: \(tableText). Try adding more database context, choosing a narrower schema, or using the cloud model for this request."
        }

        /// Shared with `PrivateCloudComputeSQLGenerator`.
        static func map(_ error: LanguageModelSession.GenerationError) -> SQLGenerationFailure {
            switch error {
            case .exceededContextWindowSize:
                .contextWindow(
                    "The schema and question exceed the local model's context window. Try a smaller database or a shorter question."
                )
            case .assetsUnavailable:
                .backendUnavailable(
                    "Model assets are not downloaded yet. Check Apple Intelligence in System Settings and try again."
                )
            case .guardrailViolation:
                .generation(
                    "The request was blocked by Apple's safety guardrails. Try rephrasing the question."
                )
            case .unsupportedLanguageOrLocale:
                .generation("This language is not supported by the local model.")
            case .rateLimited, .concurrentRequests:
                .generation("The local model is busy. Try again in a moment.")
            case .refusal:
                .generation("The local model declined to answer. Try rephrasing the question.")
            case .decodingFailure, .unsupportedGuide:
                .structuredResponseParsing(error.errorDescription ?? "Generation failed.")
            @unknown default:
                .generation(error.errorDescription ?? "Generation failed.")
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
