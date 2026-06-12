#if canImport(FoundationModels)

    import Foundation
    import FoundationModels

    /// Structured output schema for the on-device model. Mirrors
    /// `SQLGenerationResult`, with guides keeping the model inside the rails.
    @Generable(description: "A single safe read-only PostgreSQL query answering the user's question.")
    struct GeneratedSQLResponse {
        @Guide(
            description:
                "Exactly one PostgreSQL SELECT or WITH ... SELECT statement. No semicolons, no data modification, only tables and columns from the provided schema.")
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
                    model: model, maxSchemaCharacters: 8_000)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    // Retry once with a heavily truncated schema before
                    // surfacing the error.
                    do {
                        return try await respond(
                            question: question, schema: schema, context: context, config: config,
                            model: model, maxSchemaCharacters: 4_000)
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
            maxSchemaCharacters: Int
        ) async throws -> SQLGenerationResult {
            // A fresh session per request keeps the context window small and
            // the generation stateless; follow-up awareness comes from the
            // compact context section in the prompt instead.
            let session = LanguageModelSession(
                model: model,
                instructions: SQLPromptBuilder.instructions(defaultRowLimit: config.defaultRowLimit)
            )
            let prompt = SQLPromptBuilder.prompt(
                question: question,
                schema: schema,
                context: context,
                maxSchemaCharacters: maxSchemaCharacters
            )
            let started = Date()
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedSQLResponse.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_024)
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
