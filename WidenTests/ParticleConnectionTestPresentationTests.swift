import Foundation
import Testing

@testable import WidenKit

@Suite("Particle connection test presentation")
struct ParticleConnectionTestPresentationTests {
    private typealias Presentation = ParticleConnectionTestPresentation

    private static func result(
        keyAccepted: Bool = true,
        modelListed: Bool = true,
        toolCallingAdvertised: Bool? = true,
        contextWindowTokens: Int? = 1_048_576,
        returnedModelID: String? = ParticleTestSupport.returnedModelID,
        completionVerified: Bool = true,
        latencyMs: Int = 412,
        error: CloudRequestFailure? = nil
    ) -> CloudConnectivityCheck.Result {
        CloudConnectivityCheck.Result(
            keyAccepted: keyAccepted,
            modelListed: modelListed,
            toolCallingAdvertised: toolCallingAdvertised,
            contextWindowTokens: contextWindowTokens,
            defaultReasoningEffort: "high",
            returnedModelID: returnedModelID,
            completionVerified: completionVerified,
            latencyMs: latencyMs,
            error: error
        )
    }

    private static func value(_ title: String, in presentation: Presentation) -> String? {
        presentation.rows.first { $0.title == title }?.value
    }

    @Test func successfulRunShowsEveryCheckAndAnswers() {
        let presentation = Presentation(Self.result())

        #expect(presentation.rows.map(\.title) == [
            "Key", "Particle-1", "Context", "Tools", "Inference", "Returned model", "Latency",
        ])
        #expect(Self.value("Key", in: presentation) == "accepted")
        #expect(Self.value("Particle-1", in: presentation) == "listed")
        #expect(Self.value("Context", in: presentation) == "\(1_048_576.formatted()) tokens")
        #expect(Self.value("Tools", in: presentation) == "supported")
        #expect(Self.value("Inference", in: presentation) == "ok")
        #expect(Self.value("Returned model", in: presentation) == "particle-ai/particle-1 ✓")
        #expect(Self.value("Latency", in: presentation) == "412 ms")
        #expect(presentation.rows.allSatisfy { !$0.isWarning && $0.help == nil })
        #expect(presentation.succeeded)
        #expect(presentation.outcome == .answered)
    }

    @Test func rejectedKeyStopsBeforeTheModelChecksAndRecordsTheIssue() throws {
        let presentation = Presentation(
            Self.result(
                keyAccepted: false,
                modelListed: false,
                toolCallingAdvertised: nil,
                contextWindowTokens: nil,
                returnedModelID: nil,
                completionVerified: false,
                error: CloudRequestFailure(
                    category: .authentication,
                    message: "Invalid bearer credential.",
                    httpStatus: 401,
                    providerCode: "invalid_bearer_credential"
                )
            )
        )

        #expect(presentation.rows.map(\.title) == ["Key", "Particle-1", "Inference", "Latency", "Error"])
        #expect(Self.value("Key", in: presentation) == "rejected")
        #expect(Self.value("Particle-1", in: presentation) == "not checked")
        #expect(Self.value("Inference", in: presentation) == "not run")
        let error = try #require(presentation.rows.last)
        #expect(error.value == "API key rejected")
        #expect(error.isWarning)
        let help = try #require(error.help)
        #expect(help.contains("authentication"))
        #expect(help.contains("invalid_bearer_credential"))
        #expect(help.contains("HTTP 401"))
        #expect(!presentation.succeeded)
        #expect(presentation.outcome == .failed(.authentication))
    }

    @Test func networkFailureDoesNotClaimTheKeyWasRejected() {
        let presentation = Presentation(
            Self.result(
                keyAccepted: false,
                modelListed: false,
                toolCallingAdvertised: nil,
                contextWindowTokens: nil,
                returnedModelID: nil,
                completionVerified: false,
                error: CloudRequestFailure(category: .networkTransport, message: "The Internet connection appears to be offline.")
            )
        )

        #expect(Self.value("Key", in: presentation) == "not checked")
        #expect(Self.value("Error", in: presentation) == "Network error")
        #expect(presentation.outcome == .failed(.networkTransport))
    }

    @Test func unlistedModelNeverReachesInference() {
        let presentation = Presentation(
            Self.result(
                modelListed: false,
                toolCallingAdvertised: nil,
                contextWindowTokens: nil,
                returnedModelID: nil,
                completionVerified: false,
                error: CloudRequestFailure(category: .modelNotFound, message: "Particle-1 is not listed.")
            )
        )

        #expect(Self.value("Key", in: presentation) == "accepted")
        #expect(Self.value("Particle-1", in: presentation) == "not listed")
        #expect(presentation.rows.first { $0.title == "Particle-1" }?.isWarning == true)
        #expect(Self.value("Context", in: presentation) == nil)
        #expect(Self.value("Inference", in: presentation) == "not run")
        #expect(Self.value("Error", in: presentation) == "Model not available")
    }

    @Test func modelWithoutToolCallingNeverReachesInference() {
        let presentation = Presentation(
            Self.result(
                toolCallingAdvertised: false,
                contextWindowTokens: nil,
                returnedModelID: nil,
                completionVerified: false,
                error: CloudRequestFailure(category: .unsupportedFeature, message: "No tool calling.")
            )
        )

        #expect(Self.value("Context", in: presentation) == "not reported")
        #expect(Self.value("Tools", in: presentation) == "not advertised")
        #expect(Self.value("Inference", in: presentation) == "not run")
    }

    @Test func failedInferenceShowsTheFailureLabel() {
        let presentation = Presentation(
            Self.result(
                returnedModelID: nil,
                completionVerified: false,
                error: CloudRequestFailure(
                    category: .paymentRequired,
                    message: "Insufficient credits.",
                    httpStatus: 402,
                    providerCode: "insufficient_credits"
                )
            )
        )

        #expect(Self.value("Key", in: presentation) == "accepted")
        #expect(Self.value("Inference", in: presentation) == "Out of credits")
        #expect(presentation.rows.first { $0.title == "Inference" }?.isWarning == true)
        #expect(presentation.outcome == .failed(.paymentRequired))
    }

    @Test func otherReturnedModelIsAMismatch() {
        let presentation = Presentation(
            Self.result(
                returnedModelID: "particle-ai/particle-2",
                completionVerified: false,
                error: CloudRequestFailure(category: .modelVersionMismatch, message: "Particle answered with particle-ai/particle-2.")
            )
        )

        let returned = presentation.rows.first { $0.title == "Returned model" }
        #expect(returned?.value == "particle-ai/particle-2 — mismatch")
        #expect(returned?.isWarning == true)
        #expect(Self.value("Inference", in: presentation) == "Model version changed")
        #expect(!presentation.succeeded)
    }

    @Test func modelRowsDescribeTheProductionProfile() {
        let rows = Presentation.modelRows()

        #expect(rows.map(\.title) == ["Model", "Model ID", "Verified response model", "Context"])
        #expect(rows.map(\.value) == [
            "Particle-1", "particle-1", "particle-ai/particle-1", "\(1_048_576.formatted()) tokens",
        ])
    }

    @Test(arguments: ["", "   ", "pai-0123456789abcdef", "  PAI-0123\n"])
    func particleKeysGetNoHint(draft: String) {
        #expect(Presentation.apiKeyHint(for: draft) == nil)
        #expect(!Presentation.isForeignAPIKey(draft))
    }

    @Test(arguments: ["sk-or-v1-0123456789abcdef", " SK-OR-V1-0123"])
    func openRouterKeysGetTheirOwnHint(draft: String) throws {
        let hint = try #require(Presentation.apiKeyHint(for: draft))
        #expect(hint.contains("OpenRouter key"))
        #expect(hint.contains("pai-"))
        #expect(Presentation.isForeignAPIKey(draft))
    }

    @Test func otherKeysGetANonBlockingHint() throws {
        let hint = try #require(Presentation.apiKeyHint(for: "0123456789abcdef"))
        #expect(hint.contains("start with pai-"))
        #expect(!Presentation.isForeignAPIKey("0123456789abcdef"))
    }

    @Test @MainActor func outcomesRecordAndClearTheRuntimeIssue() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        state.particleAPIKeyOverride = .some("pai-test-0123456789abcdef")
        // Another suite may have mock mode on while this state initializes.
        state.useMockAI = false

        let rejected = Presentation(
            Self.result(
                keyAccepted: false,
                modelListed: false,
                completionVerified: false,
                error: CloudRequestFailure(category: .authentication, message: "Invalid bearer credential.", httpStatus: 401)
            )
        )
        state.noteTextToSQLOutcome(rejected.outcome)
        #expect(state.particleRuntimeIssue == .keyRejected)
        #expect(state.textToSQLStatus.needsAttention)

        state.noteTextToSQLOutcome(Presentation(Self.result()).outcome)
        #expect(state.particleRuntimeIssue == nil)
        #expect(state.textToSQLStatus == .ready)
    }
}
