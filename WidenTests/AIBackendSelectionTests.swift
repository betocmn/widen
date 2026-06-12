import Foundation
import Testing

@testable import WidenKit

@Suite("AI backend selection", .serialized)
@MainActor
struct AIBackendSelectionTests {
    private static let defaultsKeys = [
        "WidenAIBackendMode", "WidenCloudAIProvider", "WidenOpenRouterModelID",
    ]

    private func clearDefaults() {
        for key in Self.defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeState() -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        return (state, dir)
    }

    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        clearDefaults()
    }

    @Test func mockModeWinsOverCloud() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.useMockAI = true
        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        #expect(state.sqlGenerator is MockSQLGenerator)
        #expect(state.activeBackendDisplayName == "the mock generator")
        #expect(state.modelAvailabilityMessage == nil)
        state.useMockAI = false
    }

    @Test func cloudOpenRouterWithKeySelectsOpenRouterGenerator() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        #expect(state.cloudBackendStatus == .ready)
        #expect(state.sqlGenerator is OpenRouterSQLGenerator)
        #expect(state.activeBackendDisplayName.contains("via OpenRouter"))
        #expect(state.modelAvailabilityMessage == nil)
    }

    @Test func cloudOpenRouterWithoutKeyFallsBackToLocal() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some(nil)

        guard case .notConfigured = state.cloudBackendStatus else {
            Issue.record("expected notConfigured, got \(state.cloudBackendStatus)")
            return
        }
        #expect(!(state.sqlGenerator is OpenRouterSQLGenerator))
        #expect(state.activeBackendDisplayName == "the local model")
        #expect(state.modelAvailabilityMessage?.contains("API key") == true)
        #expect(state.modelAvailabilityMessage?.contains("on-device") == true)
    }

    /// True under both toolchains on this machine: a macOS 26 SDK build has
    /// no PCC symbols, and a macOS 27 SDK build still runs on macOS 26.
    @Test func cloudApplePCCIsUnavailableWithoutMacOS27() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .applePCC

        if PCCSupport.isRuntimeSupported {
            return  // Running on macOS 27+: availability depends on the host.
        }
        guard case .unavailable(let message) = state.cloudBackendStatus else {
            Issue.record("expected unavailable, got \(state.cloudBackendStatus)")
            return
        }
        #expect(message.contains("OpenRouter"))
        #expect(!(state.sqlGenerator is OpenRouterSQLGenerator))
        #expect(state.activeBackendDisplayName == "the local model")
        #expect(state.modelAvailabilityMessage?.contains("on-device") == true)
    }

    @Test func localModeIgnoresCloudConfiguration() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .local
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        #expect(!(state.sqlGenerator is OpenRouterSQLGenerator))
        #expect(state.activeBackendDisplayName == "the local model")
    }

    @Test func backendPreferencesPersistAcrossStates() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterModelID = "custom/model-id"

        let (reloaded, dir2) = makeState()
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(reloaded.aiBackendMode == .cloud)
        #expect(reloaded.cloudProvider == .openRouter)
        #expect(reloaded.openRouterModelID == "custom/model-id")
    }
}
