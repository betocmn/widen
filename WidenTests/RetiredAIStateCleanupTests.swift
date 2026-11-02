import Foundation
import Testing

@testable import WidenKit

@Suite("Retired AI state cleanup")
@MainActor
struct RetiredAIStateCleanupTests {
    private static let particleKey = "pai-test-0123456789abcdef"
    private static let removedKeyFlag = RetiredAIStateCleanup.didRemoveOpenRouterAPIKeyKey
    private static let compatibilityAlertKeys = [
        "WidenDidShowInstallLLMCompatibilityAlert.0.1.0.1.v1",
        "WidenDidShowInstallLLMCompatibilityAlert.0.1.1.2.v1",
    ]

    private struct KeychainPromptCancelled: Error {}

    private final class KeychainRecorder {
        var deletions = 0
    }

    /// Each test gets its own defaults suite, so nothing here reads or writes
    /// the shared standard defaults.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "widen-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// For tests with no files to clean: a folder that never exists.
    private func missingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-missing-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeState(
        directory: URL, cleanup: RetiredAIStateCleanup? = nil
    ) -> AppState {
        AppState(
            connectionStore: ConnectionStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            schemaStore: SchemaStore(directory: directory),
            retiredAIStateCleanup: cleanup
        )
    }

    /// Reads only the suite's own domain, never the defaults it falls back to.
    private func storedValue(_ key: String, suite: String, in defaults: UserDefaults) -> Any? {
        defaults.persistentDomain(forName: suite)?[key]
    }

    private func writeCatalogCache(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("openrouter-model-catalog-cache.json")
        try Data(#"{"models":[]}"#.utf8).write(to: url)
        return url
    }

    @Test func removesRetiredPreferencesAndCompatibilityAlertFlags() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let retiredKeys = [
            "WidenOpenRouterModelID", "WidenOpenRouterSchemaToolAgentEnabled",
            "WidenExperimentalCloudSchemaAgentEnabled", "WidenAIBackendMode",
            "WidenCloudAIProvider",
        ]
        #expect(RetiredAIStateCleanup.retiredPreferenceKeys == retiredKeys)
        for key in retiredKeys + Self.compatibilityAlertKeys {
            defaults.set("retired", forKey: key)
        }
        defaults.set(true, forKey: "WidenUseMockAI")
        defaults.set("kept", forKey: "WidenSelectedSessionID")
        let cleanup = RetiredAIStateCleanup(
            defaults: defaults,
            applicationSupportDirectory: missingDirectory(),
            deleteLegacyOpenRouterAPIKey: {}
        )

        cleanup.run()

        for key in retiredKeys + Self.compatibilityAlertKeys {
            #expect(storedValue(key, suite: suite, in: defaults) == nil, "\(key) survived")
        }
        #expect(storedValue("WidenUseMockAI", suite: suite, in: defaults) as? Bool == true)
        #expect(
            storedValue("WidenSelectedSessionID", suite: suite, in: defaults) as? String == "kept")
    }

    @Test func removesTheOpenRouterCatalogCacheAndToleratesItsAbsence() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try writeCatalogCache(in: dir)
        let connections = dir.appendingPathComponent("connections.json")
        try Data("[]".utf8).write(to: connections)
        let cleanup = RetiredAIStateCleanup(
            defaults: defaults,
            applicationSupportDirectory: dir,
            deleteLegacyOpenRouterAPIKey: {}
        )

        cleanup.run()
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: connections.path))

        // A missing cache, or a missing folder, is the normal case later on.
        cleanup.run()
        RetiredAIStateCleanup(
            defaults: defaults,
            applicationSupportDirectory: missingDirectory(),
            deleteLegacyOpenRouterAPIKey: {}
        ).run()
        #expect(FileManager.default.fileExists(atPath: connections.path))
    }

    @Test func launchDeletesTheOpenRouterKeyOnceAndLeavesTheParticleKeyAlone() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = KeychainRecorder()
        let cleanup = RetiredAIStateCleanup(
            defaults: defaults,
            applicationSupportDirectory: dir,
            deleteLegacyOpenRouterAPIKey: { recorder.deletions += 1 }
        )
        #expect(KeychainService.service == "Widen")
        #expect(KeychainService.legacyOpenRouterAccount == "openrouter-api-key")
        #expect(KeychainService.particleAccount != KeychainService.legacyOpenRouterAccount)

        let first = makeState(directory: dir, cleanup: cleanup)
        first.particleAPIKeyOverride = .some(nil)
        await first.onLaunch()

        #expect(recorder.deletions == 1)
        #expect(storedValue(Self.removedKeyFlag, suite: suite, in: defaults) as? Bool == true)
        // Nothing moves into the empty Particle slot.
        #expect(first.loadParticleAPIKey() == nil)
        #expect(first.textToSQLStatus == .notConfigured(AppState.missingParticleAPIKeyMessage))

        let second = makeState(directory: dir, cleanup: cleanup)
        second.particleAPIKeyOverride = .some(Self.particleKey)
        await second.onLaunch()

        #expect(recorder.deletions == 1)
        #expect(second.loadParticleAPIKey() == Self.particleKey)
        #expect(second.textToSQLStatus == .ready)
    }

    @Test func aFailedOrCancelledKeyDeletionIsNeverRetried() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = KeychainRecorder()
        let cleanup = RetiredAIStateCleanup(
            defaults: defaults,
            applicationSupportDirectory: missingDirectory(),
            deleteLegacyOpenRouterAPIKey: {
                recorder.deletions += 1
                throw KeychainPromptCancelled()
            }
        )

        cleanup.run()
        cleanup.run()

        #expect(recorder.deletions == 1)
        #expect(storedValue(Self.removedKeyFlag, suite: suite, in: defaults) as? Bool == true)
    }

    /// The test initializer's default cleanup works on the temporary directory
    /// the stores use, with a no-op Keychain deleter.
    @Test func testInitializerCleansItsOwnDirectory() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try writeCatalogCache(in: dir)
        let state = makeState(directory: dir)
        state.particleAPIKeyOverride = .some(nil)

        await state.onLaunch()

        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(state.loadParticleAPIKey() == nil)
    }
}
