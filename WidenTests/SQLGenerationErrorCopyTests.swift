import Foundation
import Testing

@testable import WidenKit

@Suite("SQLGenerationErrorCopy")
struct SQLGenerationErrorCopyTests {
    private let modelName = OpenRouterCatalog.productionProfile.displayName

    private func pipelineFailure(
        openRouterCategory: OpenRouterFailure.Category? = nil,
        message: String
    ) -> TextToSQLPipelineFailure {
        TextToSQLPipelineFailure(
            stage: .modelGeneration,
            category: .transport,
            message: message,
            openRouterFailure: openRouterCategory.map {
                OpenRouterFailure(category: $0, message: message).diagnostic
            }
        )
    }

    @Test(arguments: [
        OpenRouterFailure.Category.providerUnavailable,
        .providerOverloaded,
        .serverFailure,
        .timeout,
        .rateLimited,
    ])
    func transientProviderFailuresGetOutageCopyAndRetry(category: OpenRouterFailure.Category) {
        let failure = pipelineFailure(
            openRouterCategory: category,
            message: "SQL generation failed: OpenRouter returned HTTP 502."
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("temporary outage"))
        #expect(text.contains("try again in a moment"))
        // The original technical message survives as the detail line.
        #expect(text.contains("OpenRouter returned HTTP 502."))
        #expect(SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func authenticationFailurePointsAtSettings() {
        let failure = pipelineFailure(
            openRouterCategory: .authentication,
            message: "SQL generation failed: No auth credentials found"
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("OpenRouter rejected your API key"))
        #expect(text.contains("Settings › LLM"))
        #expect(text.contains("openrouter.ai/keys"))
        #expect(text.contains("No auth credentials found"))
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func paymentRequiredFailureSaysOutOfCredits() {
        let failure = pipelineFailure(
            openRouterCategory: .paymentRequired,
            message: "SQL generation failed: Insufficient credits"
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("out of credits"))
        #expect(text.contains("openrouter.ai"))
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func providerLimitFailureSaysKeyLimit() {
        let failure = pipelineFailure(
            openRouterCategory: .providerLimit,
            message: "SQL generation failed: Key limit exceeded"
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("spending or usage limit"))
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func canonicalMismatchFailureExplainsPauseAndUpdatePath() {
        let failure = pipelineFailure(
            openRouterCategory: .modelVersionMismatch,
            message:
                "SQL generation failed: OpenRouter reports the fixed model now resolves to an unevaluated version. Update Widen before using this cloud model."
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("new \(modelName) version that Widen hasn't verified yet"))
        #expect(text.contains("Check for Updates Now"))
        #expect(text.contains("run SQL directly"))
        #expect(text.contains("unevaluated version"))
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func privateRoutingFailureLeadsWithTransientFraming() {
        // The ZDR routing failure arrives with the fixed prefix injected by
        // OpenRouterSQLGenerator, under a non-retryable category (404).
        let failure = pipelineFailure(
            openRouterCategory: .modelNotFound,
            message:
                "SQL generation failed: No OpenRouter endpoint met Widen's private-routing requirements for this model. Widen requires zero data retention, no provider data collection, and full request-parameter support, and fails closed rather than relaxing them. No endpoints found matching your data policy."
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("zero-data-retention guarantee"))
        #expect(text.contains("usually a temporary provider outage"))
        #expect(text.contains("never relaxes this privacy requirement"))
        #expect(text.contains("No endpoints found matching your data policy."))
        #expect(SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func schemaAgentTimeoutGetsExplorationCopyAndRetry() {
        let failure = pipelineFailure(
            message: "SQL generation failed: The schema-tool agent timed out."
        )

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("ran out of time exploring your schema"))
        #expect(text.contains("more specific question"))
        #expect(SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test(arguments: [
        "SQL generation failed: The schema-tool agent exhausted its OpenRouter HTTP-attempt budget.",
        "SQL generation failed: The schema-tool agent exhausted its model-turn budget.",
        "SQL generation failed: Schema or inspection tool call budget exhausted.",
        "SQL generation failed: Schema or inspection tool byte budget exhausted.",
    ])
    func schemaAgentBudgetExhaustionGetsSimplerQuestionCopy(message: String) {
        let failure = pipelineFailure(message: message)

        let text = SQLGenerationErrorCopy.chatText(for: failure)
        #expect(text.contains("more model calls than Widen allows"))
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func unmappedFailuresPassThroughUnchanged() {
        let message = "SQL generation failed: No internet connection. Check your network and try again."
        let failure = pipelineFailure(openRouterCategory: .networkTransport, message: message)

        #expect(SQLGenerationErrorCopy.chatText(for: failure) == message)
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func thrownOpenRouterErrorsMapThroughTypedCategory() {
        let error = OpenRouterFailure(
            category: .providerUnavailable,
            message: "Provider returned error",
            httpStatus: 502
        )

        let text = SQLGenerationErrorCopy.chatText(for: error)
        #expect(text.contains("temporary outage"))
        #expect(text.contains("Provider returned error"))
        #expect(SQLGenerationErrorCopy.isRetryable(error))
    }

    @Test func thrownAgentTimeoutMapsToExplorationCopy() {
        let error = OpenRouterSchemaToolAgentFailure(
            category: .wallClockTimeout,
            message: "The schema-tool agent timed out."
        )

        let text = SQLGenerationErrorCopy.chatText(for: error)
        #expect(text.contains("ran out of time exploring your schema"))
        #expect(SQLGenerationErrorCopy.isRetryable(error))
    }

    @Test func thrownUntypedErrorsPassThroughUnchanged() {
        let error = AppError.modelGenerationFailed("The model returned no SQL.")

        #expect(
            SQLGenerationErrorCopy.chatText(for: error)
                == "SQL generation failed: The model returned no SQL.")
        #expect(!SQLGenerationErrorCopy.isRetryable(error))
    }

    @Test(arguments: [
        (OpenRouterFailure.Category.providerUnavailable, "Provider outage"),
        (.authentication, "API key rejected"),
        (.paymentRequired, "Out of credits"),
        (.modelVersionMismatch, "Model version changed"),
        (.malformedStructuredResponse, "Malformed model response"),
    ])
    func testModelLabelsAreHumanReadable(category: OpenRouterFailure.Category, label: String) {
        #expect(SQLGenerationErrorCopy.testModelLabel(for: category) == label)
    }
}
