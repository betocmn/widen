import Foundation

/// Display-time mapping from typed generation failures to plain-language
/// chat and Settings copy. Generator and pipeline messages are composed for
/// diagnostics and prompt context; this map rewrites the common failure
/// modes into copy that says what happened and what to do next, keeping the
/// original technical message as a trailing detail line so diagnostics are
/// never lost. Mapping happens only at display time — the typed failures,
/// retry policy, routing, and fail-closed behavior are untouched.
public enum SQLGenerationErrorCopy {
    /// Provider-side failures a plain retry of the same question is likely
    /// to resolve. These earn the "Try Again" button on the error bubble.
    private static let transientCategories: Set<CloudRequestFailure.Category> = [
        .providerUnavailable, .providerOverloaded, .serverFailure, .timeout, .rateLimited,
    ]

    /// User-facing text for a chat error bubble produced by a failed
    /// pipeline run.
    public static func chatText(for failure: TextToSQLPipelineFailure) -> String {
        mappedText(
            openRouterCategory: failure.openRouterFailure?.category,
            message: failure.message
        ) ?? failure.message
    }

    /// User-facing text for errors thrown outside the pipeline (direct
    /// generator calls, e.g. the failed-write repair path).
    public static func chatText(for error: any Error) -> String {
        guard let failure = SQLGenerationFailure.typed(error) else {
            return error.localizedDescription
        }
        return mappedText(
            openRouterCategory: openRouterCategory(of: failure),
            message: failure.localizedDescription
        ) ?? failure.localizedDescription
    }

    /// True when the failure is transient and resubmitting the same
    /// question is a reasonable next step.
    public static func isRetryable(_ failure: TextToSQLPipelineFailure) -> Bool {
        isRetryable(
            openRouterCategory: failure.openRouterFailure?.category,
            message: failure.message
        )
    }

    public static func isRetryable(_ error: any Error) -> Bool {
        guard let failure = SQLGenerationFailure.typed(error) else { return false }
        return isRetryable(
            openRouterCategory: openRouterCategory(of: failure),
            message: failure.localizedDescription
        )
    }

    /// The provider failure category behind a thrown generation error, if any.
    static func cloudFailureCategory(of error: any Error) -> CloudRequestFailure.Category? {
        SQLGenerationFailure.typed(error).flatMap(openRouterCategory(of:))
    }

    /// Short human label for the Settings › LLM "Test Model" error row. The
    /// raw category and provider message stay available in the row tooltip.
    public static func testModelLabel(for category: CloudRequestFailure.Category) -> String {
        switch category {
        case .authentication:
            "API key rejected"
        case .paymentRequired:
            "Out of credits"
        case .providerLimit:
            "Key limit reached"
        case .permissionDenied:
            "Access denied"
        case .guardrailBlocked:
            "Blocked by a provider guardrail"
        case .modelNotFound:
            "Model not available"
        case .modelVersionMismatch:
            "Model version changed"
        case .invalidRequest:
            "Request rejected"
        case .unsupportedFeature:
            "Feature not supported"
        case .contextWindow:
            "Request too large for the model"
        case .maxTokensExceeded:
            "Response length limit reached"
        case .rateLimited:
            "Rate limited"
        case .providerOverloaded:
            "Provider overloaded"
        case .providerUnavailable:
            "Provider outage"
        case .timeout:
            "Request timed out"
        case .contentPolicy:
            "Blocked by content policy"
        case .refusal:
            "Model declined the request"
        case .noContent:
            "Empty model response"
        case .malformedStructuredResponse:
            "Malformed model response"
        case .networkTransport:
            "Network error"
        case .serverFailure:
            "Provider server error"
        }
    }

    private static var modelName: String {
        CloudModelCatalog.productionProfile.displayName
    }

    private static var expectedModelID: String {
        let profile = CloudModelCatalog.productionProfile
        return profile.expectedReturnedModelID ?? profile.requestedModelID
    }

    private static func mappedText(
        openRouterCategory: CloudRequestFailure.Category?,
        message: String
    ) -> String? {
        // ZDR routing failures already explain the fail-closed policy, but
        // present a usually-transient provider gap as a permanent stalemate;
        // lead with the transient framing. Detection keys on the fixed
        // prefix CloudSQLGenerator injects for data-policy routing
        // failures, so it holds for both the 404 and 503 shapes.
        if message.contains("private-routing requirements") {
            return withDetail(
                "No provider currently offers \(modelName) with the zero-data-retention guarantee Widen requires, so the request was not sent. This is usually a temporary provider outage — try again in a few minutes. Widen never relaxes this privacy requirement.",
                message
            )
        }
        if let openRouterCategory {
            if transientCategories.contains(openRouterCategory) {
                return withDetail(
                    "\(modelName) is having a temporary outage. Your question is safe — try again in a moment.",
                    message
                )
            }
            switch openRouterCategory {
            case .authentication:
                return withDetail(
                    "Particle rejected your API key. Re-enter it in Settings › LLM, or create a new key at platform.particle.ai.",
                    message
                )
            case .paymentRequired:
                return withDetail(
                    "Your Particle account is out of credits. Add credits at platform.particle.ai, then try again.",
                    message
                )
            case .providerLimit:
                return withDetail(
                    "Your API key hit its spending or usage limit. Raise the limit with your provider, then try again.",
                    message
                )
            case .modelVersionMismatch:
                return withDetail(
                    "Particle answered with a model other than \(modelName) (\(expectedModelID)), so Widen discarded the response. Check Settings › General › Check for Updates Now…; you can still browse schemas and run SQL directly.",
                    message
                )
            default:
                break
            }
        }
        // The schema agent's typed category is flattened into the pipeline
        // failure message, and the pipeline types are pinned by the eval
        // scorer-source hash; match the fixed phrases the agent emits
        // (pinned by unit tests) instead of widening those types.
        if message.contains("schema-tool agent"), message.contains("timed out") {
            return withDetail(
                "Widen ran out of time exploring your schema for this question. Try again — repeat runs are usually faster — or ask a more specific question.",
                message
            )
        }
        if message.contains("HTTP-attempt budget") || message.contains("model-turn budget")
            || message.contains("tool call budget exhausted")
            || message.contains("tool byte budget exhausted")
        {
            return withDetail(
                "This question needed more model calls than Widen allows per request. Try again with a simpler or more specific question.",
                message
            )
        }
        return nil
    }

    private static func isRetryable(
        openRouterCategory: CloudRequestFailure.Category?,
        message: String
    ) -> Bool {
        if message.contains("private-routing requirements") {
            return true
        }
        if let openRouterCategory, transientCategories.contains(openRouterCategory) {
            return true
        }
        // The agent's wall-clock timeout usually clears on a retry (repeat
        // runs reuse warmed schema context); budget exhaustion needs a
        // simpler question, not a retry of the same one.
        return message.contains("schema-tool agent") && message.contains("timed out")
    }

    private static func openRouterCategory(
        of failure: SQLGenerationFailure
    ) -> CloudRequestFailure.Category? {
        switch failure {
        case .cloudRequest(let openRouterFailure):
            openRouterFailure.category
        case .schemaToolAgent(let agentFailure):
            agentFailure.cloudFailure?.category
        default:
            nil
        }
    }

    /// Keeps the original technical message under the friendly copy so
    /// diagnostics (HTTP status, provider text, request IDs) survive.
    private static func withDetail(_ text: String, _ original: String) -> String {
        "\(text)\n\nDetail: \(original)"
    }
}
