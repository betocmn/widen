#if canImport(FoundationModels)

    import Foundation
    import FoundationModels

    /// Structured output schema for session titles.
    @available(macOS 26.0, *)
    @Generable(description: "A short descriptive title for a database query session.")
    struct GeneratedSessionTitle {
        @Guide(
            description:
                "A title of two to five words in Title Case summarizing the question. No quotes, no punctuation, no SQL.")
        var title: String
    }

    /// Names sessions with Apple's on-device Foundation Model. Local-only:
    /// no network, no external LLM APIs.
    @available(macOS 26.0, *)
    public final class FoundationModelsTitleGenerator: SessionTitleGenerating, Sendable {
        public init() {}

        public func generateTitle(for question: String) async throws -> String {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable:
                throw AppError.modelUnavailable(
                    "The local model is unavailable, so the session keeps a fallback title.")
            }

            // A fresh session per request keeps the context window small and
            // the generation stateless.
            let session = LanguageModelSession(
                model: model,
                instructions: """
                    You name database query sessions. Given the user's question, \
                    answer with a short descriptive title of two to five words in \
                    Title Case. Never use quotes, punctuation, or SQL keywords.
                    """
            )
            let response = try await session.respond(
                to: "Name a session for this question: \(question)",
                generating: GeneratedSessionTitle.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64)
            )
            return response.content.title
        }
    }

#endif
