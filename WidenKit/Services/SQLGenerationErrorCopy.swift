import Foundation

/// Display-time mapping from typed generation failures to plain-language
/// chat and Settings copy. Generator and pipeline messages are composed for
/// diagnostics and prompt context; this map rewrites the common failure
/// modes into copy that says what happened and what to do next, keeping the
/// original technical message as a trailing detail line so diagnostics are
/// never lost. The copy keys on the failure category and Particle's error
/// code, and names the model and provider from the production profile.
/// Mapping happens only at display time — the typed failures, retry policy,
/// and fail-closed behavior are untouched.
public enum SQLGenerationErrorCopy {
    /// Provider-side failures a plain retry of the same question is likely
    /// to resolve. These get the outage copy.
    private static let transientCategories: Set<CloudRequestFailure.Category> = [
        .providerUnavailable, .providerOverloaded, .serverFailure, .timeout, .rateLimited,
    ]

    /// Failures that earn the "Try Again" button on the error bubble: the
    /// transient ones, plus a reply Widen could not use, which a fresh run
    /// usually fixes.
    private static let retryableCategories = transientCategories.union([.malformedStructuredResponse])

    /// The typed provider failure behind a generation error: its category
    /// and the provider's own error code, when it sent one.
    private struct ProviderFailure {
        var category: CloudRequestFailure.Category
        var providerCode: String?

        init(_ diagnostic: CloudRequestFailureDiagnostic) {
            category = diagnostic.category
            providerCode = diagnostic.providerCode?.lowercased()
        }
    }

    /// User-facing text for a chat error bubble produced by a failed
    /// pipeline run.
    public static func chatText(for failure: TextToSQLPipelineFailure) -> String {
        mappedText(
            for: failure.openRouterFailure.map(ProviderFailure.init),
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
            for: providerFailure(of: failure),
            message: failure.localizedDescription
        ) ?? failure.localizedDescription
    }

    /// True when resubmitting the same question is a reasonable next step.
    public static func isRetryable(_ failure: TextToSQLPipelineFailure) -> Bool {
        isRetryable(
            failure.openRouterFailure.map(ProviderFailure.init),
            message: failure.message
        )
    }

    public static func isRetryable(_ error: any Error) -> Bool {
        guard let failure = SQLGenerationFailure.typed(error) else { return false }
        return isRetryable(providerFailure(of: failure), message: failure.localizedDescription)
    }

    /// The provider failure category behind a thrown generation error, if any.
    static func cloudFailureCategory(of error: any Error) -> CloudRequestFailure.Category? {
        SQLGenerationFailure.typed(error).flatMap(providerFailure(of:))?.category
    }

    /// Short human label for the Settings › LLM "Test Connection" rows. A
    /// Particle error code that says more than its category gets its own
    /// label. The raw category and code stay available in the row tooltip.
    public static func testConnectionLabel(
        for category: CloudRequestFailure.Category,
        providerCode: String?
    ) -> String {
        switch providerCode?.lowercased() {
        case "insufficient_scope":
            return "No inference access"
        case "fleet_capacity_exhausted":
            return "\(providerName) at capacity"
        case "invalid_model_output":
            return "Invalid model output"
        default:
            break
        }
        return switch category {
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
            "Another model answered"
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
            "\(providerName) overloaded"
        case .providerUnavailable:
            "\(providerName) outage"
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
            "\(providerName) server error"
        }
    }

    private static var modelName: String {
        CloudModelCatalog.productionProfile.displayName
    }

    private static var providerName: String {
        CloudModelCatalog.productionProfile.provider.displayName
    }

    private static var expectedModelID: String {
        let profile = CloudModelCatalog.productionProfile
        return profile.expectedReturnedModelID ?? profile.requestedModelID
    }

    /// The plain-language copy for a provider failure, or nil when the
    /// technical message already says it best.
    private static func copy(for failure: ProviderFailure) -> String? {
        if transientCategories.contains(failure.category) {
            return "\(modelName) is having a temporary outage. Your question is safe — try again in a moment."
        }
        switch failure.category {
        case .authentication:
            return "\(providerName) rejected your API key. Re-enter it in Settings › LLM, or create a new key at platform.particle.ai."
        case .paymentRequired:
            return "Your \(providerName) account is out of credits. Add credits at platform.particle.ai, then try again."
        case .permissionDenied:
            return "Your \(providerName) API key isn't allowed to run inference. Create a key with inference access at platform.particle.ai and save it in Settings › LLM."
        case .malformedStructuredResponse:
            // Includes Particle's invalid_model_output, already resent once.
            return "\(modelName) returned a response Widen couldn't use. Try again, or rephrase the question."
        case .modelVersionMismatch:
            return "\(providerName) answered with a model other than \(modelName) (\(expectedModelID)), so Widen discarded the response. Check Settings › General › Check for Updates Now…; you can still browse schemas and run SQL."
        case .contextWindow:
            return "This request is too large for \(modelName). Narrow the open schema or ask about fewer tables."
        case .modelNotFound:
            return "\(modelName) isn't available to your key right now. Check platform.particle.ai."
        case .providerLimit:
            // Only eval providers report key limits; keep it provider-neutral.
            return "Your API key reached its usage limit. Raise the limit with your provider, then try again."
        default:
            return nil
        }
    }

    private static func mappedText(for providerFailure: ProviderFailure?, message: String) -> String? {
        if let providerFailure, let copy = copy(for: providerFailure) {
            return withDetail(copy, message)
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

    private static func isRetryable(_ providerFailure: ProviderFailure?, message: String) -> Bool {
        if let providerFailure, retryableCategories.contains(providerFailure.category) {
            return true
        }
        // The agent's wall-clock timeout usually clears on a retry (repeat
        // runs reuse warmed schema context); budget exhaustion needs a
        // simpler question, not a retry of the same one.
        return message.contains("schema-tool agent") && message.contains("timed out")
    }

    private static func providerFailure(of failure: SQLGenerationFailure) -> ProviderFailure? {
        switch failure {
        case .cloudRequest(let cloudFailure):
            ProviderFailure(cloudFailure.diagnostic)
        case .schemaToolAgent(let agentFailure):
            agentFailure.cloudFailure.map { ProviderFailure($0.diagnostic) }
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
