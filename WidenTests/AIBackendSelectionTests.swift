import Foundation
import Testing

@testable import WidenKit

@Suite("AI backend selection", .serialized)
@MainActor
struct AIBackendSelectionTests {
    private static let defaultsKeys = [
        "WidenAIBackendMode", "WidenCloudAIProvider", "WidenOpenRouterModelID",
        "WidenUseMockAI", "WidenOpenRouterSchemaToolAgentEnabled",
        "WidenExperimentalCloudSchemaAgentEnabled",
    ]

    private func clearDefaults() {
        for key in Self.defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(
            forKey: AppState.didShowInstallLLMCompatibilityAlertKey)
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

    private static func ordersTable() -> TableInfo {
        TableInfo(
            schema: "public",
            name: "orders",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "public",
                    tableName: "orders",
                    name: "id",
                    dataType: "integer",
                    isNullable: false,
                    ordinalPosition: 1
                )
            ]
        )
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

    @Test func cloudOpenRouterWithKeySelectsLegacyGeneratorWithoutConnectionContext() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        #expect(state.cloudBackendStatus == .ready)
        let generator = state.sqlGenerator as? OpenRouterSQLGenerator
        #expect(generator != nil)
        #expect(generator?.model == OpenRouterCatalog.productionProfile.requestedModelID)
        #expect(
            generator?.expectedCanonicalModelID
                == OpenRouterCatalog.productionProfile.expectedCanonicalModelID
        )
        #expect(state.activeBackendDisplayName.contains("via OpenRouter"))
        #expect(state.modelAvailabilityMessage == nil)
    }

    @Test func cloudOpenRouterConnectedSessionUsesSchemaToolAgentByDefault() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        state.connections = [connection]
        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        let generator = state.sqlGenerator(
            connectionID: connection.id,
            schema: DatabaseSchema(
                schemas: [SchemaInfo(name: "public")],
                tables: [Self.ordersTable()]
            )
        )

        let agent = generator as? OpenRouterSchemaToolSQLAgent
        #expect(agent != nil)
        #expect(agent?.model == OpenRouterCatalog.productionProfile.requestedModelID)
        #expect(
            agent?.expectedCanonicalModelID
                == OpenRouterCatalog.productionProfile.expectedCanonicalModelID
        )
    }

    @Test func legacyModelAndAgentPreferencesCannotChangeRuntimeProfile() {
        clearDefaults()
        UserDefaults.standard.set("custom/model-id", forKey: "WidenOpenRouterModelID")
        UserDefaults.standard.set(false, forKey: "WidenOpenRouterSchemaToolAgentEnabled")
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        state.connections = [connection]
        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        let generator = state.sqlGenerator(
            connectionID: connection.id,
            schema: DatabaseSchema(
                schemas: [SchemaInfo(name: "public")],
                tables: [Self.ordersTable()]
            )
        )

        let agent = generator as? OpenRouterSchemaToolSQLAgent
        #expect(agent != nil)
        #expect(agent?.model == OpenRouterCatalog.productionProfile.requestedModelID)
        #expect(
            agent?.expectedCanonicalModelID
                == OpenRouterCatalog.productionProfile.expectedCanonicalModelID
        )
    }

    @Test func connectionCloudSchemaMetadataOptOutBlocksCloudGeneration() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(
            database: "widen_test",
            username: "beto",
            allowCloudSchemaMetadata: false
        )
        state.connections = [connection]
        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")

        let generator = state.sqlGenerator(
            connectionID: connection.id,
            schema: DatabaseSchema(schemas: [SchemaInfo(name: "public")])
        )

        #expect(generator is UnavailableSQLGenerator)
    }

    @Test func cloudInspectionDatabaseRequiresConnectedConnection() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(
            database: "widen_test",
            username: "beto",
            allowLocalDataInspection: true,
            allowCloudDataInspection: true
        )
        state.connections = [connection]

        let disconnectedDatabase = state.databaseInspectionDatabase(
            for: connection.id,
            connection: connection
        )
        #expect(disconnectedDatabase == nil)

        state.connectionStates[connection.id] = .connected
        let connectedDatabase = state.databaseInspectionDatabase(
            for: connection.id,
            connection: connection
        )
        #expect(connectedDatabase != nil)
    }

    @Test func cloudApplePCCQuotaReachedIsUnavailable() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .applePCC
        state.pccAvailabilityMessageOverride = .some(nil)
        state.pccQuotaLimitReachedMessageOverride =
            .some("You've reached today's Private Cloud Compute limit.")
        state.localModelAvailabilityMessageOverride = .some(nil)

        guard case .unavailable(let message) = state.cloudBackendStatus else {
            Issue.record("expected unavailable, got \(state.cloudBackendStatus)")
            return
        }
        #expect(message.contains("limit"))
        #expect(state.activeBackendDisplayName == "Apple Private Cloud Compute")
        #expect(state.modelAvailabilityMessage?.contains("limit") == true)
    }

    @Test func cloudOpenRouterWithoutKeyReportsConfigurationProblem() {
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
        #expect(state.sqlGenerator is UnavailableSQLGenerator)
        #expect(state.activeBackendDisplayName.contains("via OpenRouter"))
        #expect(state.modelAvailabilityMessage?.contains("API key") == true)
        #expect(state.modelAvailabilityMessage?.contains("on-device") == false)
    }

    @Test func cloudStatusDoesNotMentionLocalFallback() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some(nil)
        state.localModelAvailabilityMessageOverride = .some("Local model is unavailable.")

        let message = state.modelAvailabilityMessage ?? ""
        #expect(message.contains("API key"))
        #expect(!message.contains("on-device fallback"))
        #expect(!message.contains("Using the on-device model until then."))
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
        #expect(state.sqlGenerator is UnavailableSQLGenerator)
        #expect(state.activeBackendDisplayName == "Apple Private Cloud Compute")
        #expect(state.modelAvailabilityMessage?.contains("OpenRouter") == true)
    }

    @Test func localModeIgnoresCloudConfiguration() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .local
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")
        state.localLLMEligibilityOverride = .ready

        #expect(!(state.sqlGenerator is OpenRouterSQLGenerator))
        #expect(state.activeBackendDisplayName == "On-Device — Experimental")
    }

    @Test func connectionAutofillStaysAvailableWithoutLocalModel() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.localLLMEligibilityOverride = .appleIntelligenceDisabled

        #expect(state.connectionDetailsParser != nil)
        #expect(state.connectionAutofillUnavailableMessage == nil)
    }

    @Test func freshPreferencesDefaultToCloudBackend() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        #expect(state.aiBackendMode == .cloud)
        #expect(state.activeBackendDisplayName.contains("via OpenRouter"))
        #expect(state.cloudProvider == .openRouter)
        #expect(OpenRouterCatalog.productionProfile.requestedModelID == "openai/gpt-5.6-sol")
        #expect(
            OpenRouterCatalog.productionProfile.expectedCanonicalModelID
                == "openai/gpt-5.6-sol-20260709"
        )
    }

    @Test func firstLaunchWithCloudDefaultDoesNotShowLocalCompatibilityAlert() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.localLLMEligibilityOverride = .appleIntelligenceDisabled

        await state.onLaunch()

        #expect(state.aiBackendMode == .cloud)
        #expect(state.llmCompatibilityAlert == nil)
    }

    @Test func firstLaunchWithAppleIntelligenceDisabledShowsSettingsPath() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .local
        state.localLLMEligibilityOverride = .appleIntelligenceDisabled

        await state.onLaunch()

        #expect(state.aiBackendMode == .local)
        #expect(state.llmCompatibilityAlert?.kind == .appleIntelligenceDisabled)
        #expect(
            state.llmCompatibilityAlert?.message.contains(
                "System Settings › Apple Intelligence & Siri") == true)
    }

    @Test func storedLocalModeRemainsSelectedWhenReady() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .local
        state.localLLMEligibilityOverride = .ready

        await state.onLaunch()

        #expect(state.aiBackendMode == .local)
        #expect(state.isLocalBackendVisible)
        #expect(state.llmCompatibilityAlert == nil)
    }

    @Test func launchFallsBackToCloudWhenStoredLocalModeIsHidden() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .local
        state.localLLMEligibilityOverride = .osUnsupported("macOS 14")

        await state.onLaunch()

        #expect(state.aiBackendMode == .cloud)
        #expect(!state.isLocalBackendVisible)
        #expect(state.llmCompatibilityAlert == nil)
    }

    @Test func selectingLocalWithAppleIntelligenceDisabledFailsAndShowsAlert() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.localLLMEligibilityOverride = .appleIntelligenceDisabled

        let selected = state.requestAIBackendMode(.local)

        #expect(!selected)
        #expect(state.aiBackendMode == .cloud)
        #expect(state.llmCompatibilityAlert?.kind == .appleIntelligenceDisabled)
        #expect(
            state.llmCompatibilityAlert?.message.contains(
                "System Settings › Apple Intelligence & Siri") == true)
    }

    @Test func selectingLocalOnUnsupportedHostFailsAndLeavesCloudSelected() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.localLLMEligibilityOverride = .osUnsupported("macOS 14")

        let selected = state.requestAIBackendMode(.local)

        #expect(!selected)
        #expect(state.aiBackendMode == .cloud)
        #expect(!state.isLocalBackendVisible)
        #expect(state.llmCompatibilityAlert?.kind == .localUnavailable)
        #expect(state.llmCompatibilityAlert?.message.contains("macOS 26") == true)
    }

    @Test func selectingLocalWhenReadySucceedsWithoutAlert() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.localLLMEligibilityOverride = .ready

        let selected = state.requestAIBackendMode(.local)

        #expect(selected)
        #expect(state.aiBackendMode == .local)
        #expect(state.llmCompatibilityAlert == nil)
    }

    /// OpenRouter works on every Mac today, so it is the default; Apple
    /// PCC is an explicit opt-in.
    @Test func defaultCloudProviderIsOpenRouter() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        #expect(state.cloudProvider == .openRouter)
    }

    @Test func launchRemovesObsoleteOpenRouterPreferences() async {
        clearDefaults()
        UserDefaults.standard.set("custom/model-id", forKey: "WidenOpenRouterModelID")
        UserDefaults.standard.set(false, forKey: "WidenOpenRouterSchemaToolAgentEnabled")
        UserDefaults.standard.set(false, forKey: "WidenExperimentalCloudSchemaAgentEnabled")
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        await state.onLaunch()

        #expect(UserDefaults.standard.object(forKey: "WidenOpenRouterModelID") == nil)
        #expect(UserDefaults.standard.object(forKey: "WidenOpenRouterSchemaToolAgentEnabled") == nil)
        #expect(UserDefaults.standard.object(forKey: "WidenExperimentalCloudSchemaAgentEnabled") == nil)
    }

    @Test func supportedBackendPreferencesPersistAcrossStates() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter

        let (reloaded, dir2) = makeState()
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(reloaded.aiBackendMode == .cloud)
        #expect(reloaded.cloudProvider == .openRouter)
    }

    @Test func cloudLocalCloudSwitchKeepsBothEligiblePathsAvailable() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.aiBackendMode = .cloud
        state.cloudProvider = .openRouter
        state.openRouterAPIKeyOverride = .some("sk-test")
        state.localLLMEligibilityOverride = .ready

        #expect(state.sqlGenerator is OpenRouterSQLGenerator)
        #expect(state.requestAIBackendMode(.local))
        #expect(state.aiBackendMode == .local)
        #expect(!(state.sqlGenerator is UnavailableSQLGenerator))
        #expect(state.requestAIBackendMode(.cloud))
        #expect(state.aiBackendMode == .cloud)
        #expect(state.sqlGenerator is OpenRouterSQLGenerator)
    }
}
