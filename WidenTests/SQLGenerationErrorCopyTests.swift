import Foundation
import Testing

@testable import WidenKit

@Suite("SQLGenerationErrorCopy")
struct SQLGenerationErrorCopyTests {
    /// One row of the copy table: a Particle failure, a phrase its copy must
    /// contain, and whether it earns "Try Again".
    struct CopyCase: Sendable, CustomTestStringConvertible {
        var category: CloudRequestFailure.Category
        var providerCode: String?
        var httpStatus: Int?
        var copy: String
        var retryable: Bool

        var testDescription: String {
            "\(category.rawValue) \(providerCode ?? "-")"
        }
    }

    static let copyTable: [CopyCase] = [
        CopyCase(
            category: .authentication,
            providerCode: "invalid_bearer_credential",
            httpStatus: 401,
            copy: "Particle rejected your API key. Re-enter it in Settings › LLM, or create a new key at platform.particle.ai.",
            retryable: false
        ),
        CopyCase(
            category: .paymentRequired,
            providerCode: "insufficient_credits",
            httpStatus: 402,
            copy: "Your Particle account is out of credits. Add credits at platform.particle.ai, then try again.",
            retryable: false
        ),
        CopyCase(
            category: .permissionDenied,
            providerCode: "insufficient_scope",
            httpStatus: 403,
            copy: "Your Particle API key isn't allowed to run inference. Create a key with inference access at platform.particle.ai and save it in Settings › LLM.",
            retryable: false
        ),
        CopyCase(
            category: .rateLimited,
            providerCode: "fleet_capacity_exhausted",
            httpStatus: 429,
            copy: "Particle-1 is having a temporary outage. Your question is safe — try again in a moment.",
            retryable: true
        ),
        CopyCase(
            category: .serverFailure,
            providerCode: "internal_error",
            httpStatus: 500,
            copy: "Particle-1 is having a temporary outage. Your question is safe — try again in a moment.",
            retryable: true
        ),
        CopyCase(
            category: .providerUnavailable,
            providerCode: "invalid_upstream_response",
            httpStatus: 502,
            copy: "Particle-1 is having a temporary outage. Your question is safe — try again in a moment.",
            retryable: true
        ),
        CopyCase(
            category: .providerOverloaded,
            httpStatus: 503,
            copy: "Particle-1 is having a temporary outage. Your question is safe — try again in a moment.",
            retryable: true
        ),
        CopyCase(
            category: .timeout,
            httpStatus: 504,
            copy: "Particle-1 is having a temporary outage. Your question is safe — try again in a moment.",
            retryable: true
        ),
        CopyCase(
            category: .malformedStructuredResponse,
            providerCode: "invalid_model_output",
            httpStatus: 502,
            copy: "Particle-1 returned a response Widen couldn't use. Try again, or rephrase the question.",
            retryable: true
        ),
        CopyCase(
            category: .malformedStructuredResponse,
            copy: "Particle-1 returned a response Widen couldn't use. Try again, or rephrase the question.",
            retryable: true
        ),
        CopyCase(
            category: .modelVersionMismatch,
            copy: "Particle answered with a model other than Particle-1 (particle-ai/particle-1), so Widen discarded the response. Check Settings › General › Check for Updates Now…; you can still browse schemas and run SQL.",
            retryable: false
        ),
        CopyCase(
            category: .contextWindow,
            providerCode: "request_too_large",
            httpStatus: 413,
            copy: "This request is too large for Particle-1. Narrow the open schema or ask about fewer tables.",
            retryable: false
        ),
        CopyCase(
            category: .modelNotFound,
            providerCode: "model_not_found",
            httpStatus: 404,
            copy: "Particle-1 isn't available to your key right now. Check platform.particle.ai.",
            retryable: false
        ),
        CopyCase(
            category: .providerLimit,
            httpStatus: 403,
            copy: "Your API key reached its usage limit. Raise the limit with your provider, then try again.",
            retryable: false
        ),
    ]

    private static func cloudFailure(_ copyCase: CopyCase, message: String) -> CloudRequestFailure {
        CloudRequestFailure(
            category: copyCase.category,
            message: message,
            httpStatus: copyCase.httpStatus,
            providerCode: copyCase.providerCode
        )
    }

    private func pipelineFailure(
        cloudFailure: CloudRequestFailure? = nil,
        message: String
    ) -> TextToSQLPipelineFailure {
        TextToSQLPipelineFailure(
            stage: .modelGeneration,
            category: .transport,
            message: message,
            openRouterFailure: cloudFailure?.diagnostic
        )
    }

    @Test(arguments: copyTable)
    func pipelineFailuresGetTheirTableCopy(copyCase: CopyCase) {
        let detail = "SQL generation failed: Particle returned HTTP \(copyCase.httpStatus ?? 200)."
        let failure = pipelineFailure(
            cloudFailure: Self.cloudFailure(copyCase, message: detail),
            message: detail
        )

        #expect(SQLGenerationErrorCopy.chatText(for: failure) == "\(copyCase.copy)\n\nDetail: \(detail)")
        #expect(SQLGenerationErrorCopy.isRetryable(failure) == copyCase.retryable)
    }

    @Test(arguments: copyTable)
    func thrownFailuresGetTheSameCopy(copyCase: CopyCase) {
        let error = Self.cloudFailure(copyCase, message: "Provider returned error")

        let text = SQLGenerationErrorCopy.chatText(for: error)
        #expect(text.hasPrefix(copyCase.copy))
        #expect(text.hasSuffix("Detail: SQL generation failed: Provider returned error"))
        #expect(SQLGenerationErrorCopy.isRetryable(error) == copyCase.retryable)
        #expect(SQLGenerationErrorCopy.cloudFailureCategory(of: error) == copyCase.category)
    }

    @Test func copyNamesNoRetiredProvider() {
        for copyCase in Self.copyTable {
            let lowered = copyCase.copy.lowercased()
            #expect(!lowered.contains("openrouter"))
            #expect(!lowered.contains("openai"))
            #expect(!lowered.contains("zero-data-retention"))
        }
    }

    @Test func agentFailureWithCloudCauseUsesTheCauseCopy() {
        let error = SchemaToolAgentFailure(
            category: .cloudRequestFailure,
            message: "The schema-tool agent's model request failed.",
            cloudFailure: CloudRequestFailure(
                category: .malformedStructuredResponse,
                message: "The cloud model returned a malformed tool call."
            )
        )

        let text = SQLGenerationErrorCopy.chatText(for: error)
        #expect(text.contains("returned a response Widen couldn't use"))
        #expect(SQLGenerationErrorCopy.isRetryable(error))
        #expect(SQLGenerationErrorCopy.cloudFailureCategory(of: error) == .malformedStructuredResponse)
    }

    @Test func formerPrivateRoutingWordingIsNoLongerSpecial() {
        let message =
            "SQL generation failed: No endpoint met Widen's private-routing requirements for this model."
        let failure = pipelineFailure(message: message)

        #expect(SQLGenerationErrorCopy.chatText(for: failure) == message)
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
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
        "SQL generation failed: The schema-tool agent exhausted its HTTP-attempt budget.",
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

    @Test(arguments: [
        CloudRequestFailure.Category.networkTransport, .invalidRequest, .unsupportedFeature, .refusal,
    ])
    func unmappedFailuresPassThroughUnchanged(category: CloudRequestFailure.Category) {
        let message = "SQL generation failed: No internet connection. Check your network and try again."
        let failure = pipelineFailure(
            cloudFailure: CloudRequestFailure(category: category, message: message),
            message: message
        )

        #expect(SQLGenerationErrorCopy.chatText(for: failure) == message)
        #expect(!SQLGenerationErrorCopy.isRetryable(failure))
    }

    @Test func thrownAgentTimeoutMapsToExplorationCopy() {
        let error = SchemaToolAgentFailure(
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
        #expect(SQLGenerationErrorCopy.cloudFailureCategory(of: error) == nil)
    }

    @Test(arguments: [
        (CloudRequestFailure.Category.authentication, "invalid_bearer_credential", "API key rejected"),
        (.paymentRequired, "insufficient_credits", "Out of credits"),
        (.permissionDenied, "insufficient_scope", "No inference access"),
        (.permissionDenied, nil, "Access denied"),
        (.rateLimited, "fleet_capacity_exhausted", "Particle at capacity"),
        (.rateLimited, nil, "Rate limited"),
        (.malformedStructuredResponse, "INVALID_MODEL_OUTPUT", "Invalid model output"),
        (.malformedStructuredResponse, nil, "Malformed model response"),
        (.providerUnavailable, "invalid_upstream_response", "Particle outage"),
        (.modelVersionMismatch, nil, "Another model answered"),
        (.contextWindow, "request_too_large", "Request too large for the model"),
    ] as [(CloudRequestFailure.Category, String?, String)])
    func testConnectionLabelsAreHumanReadable(
        category: CloudRequestFailure.Category,
        providerCode: String?,
        label: String
    ) {
        #expect(SQLGenerationErrorCopy.testConnectionLabel(for: category, providerCode: providerCode) == label)
    }
}
