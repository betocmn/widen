#if canImport(FoundationModels)

    import Foundation
    import FoundationModels

    /// Structured output schema for paste-autofill extraction.
    @Generable(description: "PostgreSQL connection details found in the pasted text.")
    struct GeneratedConnectionDetails {
        @Guide(
            description:
                "A short nickname for the connection, only when the text clearly names the database or app.")
        var name: String?

        @Guide(description: "Hostname or IP address of the PostgreSQL server.")
        var host: String?

        @Guide(description: "TCP port number, e.g. 5432.")
        var port: Int?

        @Guide(description: "Database name, without a leading slash.")
        var database: String?

        @Guide(description: "Username or role.")
        var username: String?

        @Guide(description: "Password, percent-decoded when it came from a URL.")
        var password: String?

        @Guide(
            description: "SSL mode mentioned in the text, or unknown when SSL is not mentioned.",
            .anyOf(["disable", "prefer", "require", "unknown"]))
        var sslMode: String
    }

    /// Extracts connection details with Apple's on-device Foundation Model.
    /// Local-only by design: the pasted text can contain credentials, so the
    /// feature is disabled rather than ever falling back to a remote model.
    /// For the same reason nothing here is written to `GenerationLog` — the
    /// prompt would put passwords in a plain-text file.
    public final class FoundationModelsConnectionParser: ConnectionDetailsParsing, Sendable {
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

        public func parse(_ text: String) async throws -> ParsedConnectionDetails {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw AppError.modelUnavailable(Self.message(for: reason))
            }

            // A fresh session per request keeps the context window small and
            // the extraction stateless.
            let session = LanguageModelSession(
                model: model,
                instructions: ConnectionAutofillPromptBuilder.instructions
            )
            do {
                let response = try await session.respond(
                    to: ConnectionAutofillPromptBuilder.prompt(for: text),
                    generating: GeneratedConnectionDetails.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
                )
                return Self.details(from: response.content)
            } catch let error as LanguageModelSession.GenerationError {
                throw Self.map(error)
            }
        }

        private static func details(
            from generated: GeneratedConnectionDetails
        ) -> ParsedConnectionDetails {
            .sanitized(
                name: generated.name,
                host: generated.host,
                port: generated.port,
                database: generated.database,
                username: generated.username,
                password: generated.password,
                sslModeText: generated.sslMode
            )
        }

        private static func map(_ error: LanguageModelSession.GenerationError) -> AppError {
            switch error {
            case .exceededContextWindowSize:
                .autofillFailed(
                    "The pasted text is too long for the local model. Paste only the connection details."
                )
            case .assetsUnavailable:
                .modelUnavailable(
                    "Model assets are not downloaded yet. Check Apple Intelligence in System Settings and try again."
                )
            case .guardrailViolation:
                .autofillFailed(
                    "The request was blocked by Apple's safety guardrails. Try pasting only the connection details."
                )
            case .unsupportedLanguageOrLocale:
                .autofillFailed("This language is not supported by the local model.")
            case .rateLimited, .concurrentRequests:
                .autofillFailed("The local model is busy. Try again in a moment.")
            case .refusal:
                .autofillFailed("The local model declined to read the pasted text.")
            case .decodingFailure, .unsupportedGuide:
                .autofillFailed(error.errorDescription ?? "Extraction failed.")
            @unknown default:
                .autofillFailed(error.errorDescription ?? "Extraction failed.")
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
            return
                "For privacy, paste autofill runs only on the local Apple model — never a cloud service. \(detail)"
        }
    }

#endif
