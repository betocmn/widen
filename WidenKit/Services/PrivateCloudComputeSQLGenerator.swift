// Private Cloud Compute symbols ship with the macOS 27 SDK (Xcode 27,
// Swift 6.4). The compiler gate keeps this file inert when building with
// Xcode 26, and the @available gate keeps it inert on macOS 26 at runtime.
#if compiler(>=6.4) && canImport(FoundationModels)

    import Foundation
    import FoundationModels

    /// Generates SQL with Apple's server-side foundation model on Private
    /// Cloud Compute: same prompts and structured response as the on-device
    /// generator, but a 32K context and no per-request token cost. Requires
    /// macOS 27, Apple Intelligence, and a build signed with the
    /// `com.apple.developer.private-cloud-compute` entitlement.
    @available(macOS 27.0, *)
    final class PrivateCloudComputeSQLGenerator: SQLGenerator, Sendable {
        /// The 32K-token server context leaves room for far more schema than
        /// the on-device budget, while still bounding pathological databases.
        static let schemaCharacterBudget = 24_000

        init() {}

        /// nil when the server model is ready; otherwise a user-readable reason.
        static var availabilityMessage: String? {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                nil
            case .unavailable(let reason):
                message(for: reason)
            }
        }

        /// A blocker when the user has exhausted the daily limit.
        static var quotaLimitReachedMessage: String? {
            let usage = PrivateCloudComputeLanguageModel().quotaUsage
            if usage.isLimitReached {
                return quotaReachedMessage(resetDate: usage.resetDate)
            }
            return nil
        }

        /// A short warning when the user is near the daily limit.
        static var quotaWarning: String? {
            let usage = PrivateCloudComputeLanguageModel().quotaUsage
            if case .belowLimit(let info) = usage.status, info.isApproachingLimit {
                return "You're approaching today's Private Cloud Compute limit."
            }
            return nil
        }

        /// True when the OS offers a way to raise the daily limit.
        static var hasLimitIncreaseSuggestion: Bool {
            PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion != nil
        }

        /// Opens Apple's limit-increase UI when the OS offers one.
        static func showLimitIncreaseSuggestion() {
            PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show()
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw AppError.modelUnavailable(Self.message(for: reason))
            }
            let usage = model.quotaUsage
            if usage.isLimitReached {
                throw AppError.modelUnavailable(
                    Self.quotaReachedMessage(resetDate: usage.resetDate))
            }

            let session = LanguageModelSession(
                model: model,
                instructions: SQLPromptBuilder.instructions(defaultRowLimit: config.defaultRowLimit)
            )
            let bundle = SQLPromptBuilder.promptBundle(
                question: question,
                schema: schema,
                context: context,
                databaseContext: config.databaseContext,
                maxSchemaCharacters: Self.schemaCharacterBudget
            )
            let prompt = bundle.prompt
            let started = Date()
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedSQLResponse.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_024)
                )
                var result = FoundationModelsSQLGenerator.result(from: response.content)
                result.generationCallCount = max(1, context.modelCallCount)
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: result.logDescription,
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                    telemetry: PromptTelemetry(
                        phase: context.mode,
                        package: bundle.schemaPackage,
                        context: context,
                        callCount: max(1, context.modelCallCount),
                        stopReason: result.needsClarification ? "clarification" : "success"
                    ))
                return result
            } catch {
                await GenerationLog.shared.append(
                    prompt: prompt,
                    outcome: "error: \(error)",
                    durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                    telemetry: PromptTelemetry(
                        phase: context.mode,
                        package: bundle.schemaPackage,
                        context: context,
                        callCount: max(1, context.modelCallCount),
                        stopReason: "error"
                    ))
                throw Self.map(error)
            }
        }

        private static func map(_ error: any Error) -> any Error {
            if let generationError = error as? LanguageModelSession.GenerationError {
                return FoundationModelsSQLGenerator.map(generationError)
            }
            guard let pccError = error as? PrivateCloudComputeLanguageModel.Error else {
                return error
            }
            switch pccError {
            case .networkFailure:
                return AppError.modelGenerationFailed(
                    "Private Cloud Compute could not be reached. Check your internet connection and try again."
                )
            case .quotaLimitReached(let info):
                return AppError.modelUnavailable(quotaReachedMessage(resetDate: info.resetDate))
            case .serviceUnavailable:
                return AppError.modelUnavailable(
                    "Private Cloud Compute is temporarily unavailable. Try again later or switch to the local model."
                )
            @unknown default:
                return AppError.modelGenerationFailed(
                    pccError.errorDescription ?? "Generation failed.")
            }
        }

        private static func quotaReachedMessage(resetDate: Date?) -> String {
            var message = "You've reached today's Private Cloud Compute limit."
            if let resetDate {
                message +=
                    " It resets \(resetDate.formatted(.relative(presentation: .named)))."
            }
            return message + " Switch to the local model or try again later."
        }

        private static func message(
            for reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
        ) -> String {
            switch reason {
            case .deviceNotEligible:
                "This Mac is not eligible for Private Cloud Compute."
            case .systemNotReady:
                "Private Cloud Compute is not ready. Check Apple Intelligence in System Settings, and note that this build must be signed with the approved Private Cloud Compute entitlement."
            @unknown default:
                "Private Cloud Compute is unavailable for an unknown reason."
            }
        }
    }

#endif
