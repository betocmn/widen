import Foundation
import Testing

@testable import WidenKit

@Suite("Particle backend selection", .serialized)
@MainActor
struct ParticleBackendSelectionTests {
    private static let defaultsKeys = [
        "WidenAIBackendMode", "WidenCloudAIProvider", "WidenOpenRouterModelID",
        "WidenUseMockAI", "WidenOpenRouterSchemaToolAgentEnabled",
        "WidenExperimentalCloudSchemaAgentEnabled", compatibilityAlertKey,
    ]
    private static let compatibilityAlertKey = "WidenDidShowInstallLLMCompatibilityAlert.0.1.1.2.v1"

    private static let particleKey = "pai-test-0123456789abcdef"

    private func clearDefaults() {
        for key in Self.defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Every state starts with no stored key, so no test reads or writes the
    /// real Keychain.
    private func makeState() -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        state.particleAPIKeyOverride = .some(nil)
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

    private static func ordersSchema() -> DatabaseSchema {
        DatabaseSchema(schemas: [SchemaInfo(name: "public")], tables: [ordersTable()])
    }

    // MARK: - Generator selection

    @Test func mockModeWinsOverParticle() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.useMockAI = true
        state.particleAPIKeyOverride = .some(Self.particleKey)

        #expect(state.sqlGenerator is MockSQLGenerator)
        #expect(state.activeBackendDisplayName == "the mock generator")
        #expect(state.modelAvailabilityMessage == nil)
        #expect(state.textToSQLStatus == .mock)
        #expect(state.textToSQLStatus.chipTitle == "Mock AI")
        #expect(!state.textToSQLStatus.needsAttention)
        state.useMockAI = false
    }

    @Test func particleKeyWithoutConnectionContextSelectsTheOneShotGenerator() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.particleAPIKeyOverride = .some(Self.particleKey)

        #expect(state.textToSQLStatus == .ready)
        let generator = state.sqlGenerator as? CloudSQLGenerator
        #expect(generator != nil)
        #expect(generator?.model == "particle-1")
        #expect(generator?.expectedCanonicalModelID == "particle-ai/particle-1")
        #expect(state.activeBackendDisplayName == "Particle-1")
        #expect(state.modelAvailabilityMessage == nil)
    }

    @Test func connectedSessionUsesTheSchemaToolAgentOnParticle() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        state.connections = [connection]
        state.particleAPIKeyOverride = .some(Self.particleKey)

        let generator = state.sqlGenerator(connectionID: connection.id, schema: Self.ordersSchema())

        let agent = generator as? SchemaToolSQLAgent
        #expect(agent != nil)
        #expect(agent?.profile == .particle)
        #expect(agent?.model == "particle-1")
        #expect(agent?.expectedCanonicalModelID == "particle-ai/particle-1")
    }

    @Test func retiredBackendAndModelPreferencesCannotChangeTheRuntimeProfile() {
        clearDefaults()
        UserDefaults.standard.set("local", forKey: "WidenAIBackendMode")
        UserDefaults.standard.set("applePCC", forKey: "WidenCloudAIProvider")
        UserDefaults.standard.set("custom/model-id", forKey: "WidenOpenRouterModelID")
        UserDefaults.standard.set(false, forKey: "WidenOpenRouterSchemaToolAgentEnabled")
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        state.connections = [connection]
        state.particleAPIKeyOverride = .some(Self.particleKey)

        let generator = state.sqlGenerator(connectionID: connection.id, schema: Self.ordersSchema())

        let agent = generator as? SchemaToolSQLAgent
        #expect(agent?.profile == .particle)
        #expect((state.sqlGenerator as? CloudSQLGenerator)?.model == "particle-1")
        #expect(state.activeBackendDisplayName == "Particle-1")
    }

    @Test func productionProfileIsParticle1() {
        let profile = CloudModelCatalog.productionProfile
        #expect(profile == .particle)
        #expect(profile.displayName == "Particle-1")
        #expect(profile.requestedModelID == "particle-1")
        #expect(profile.expectedReturnedModelID == "particle-ai/particle-1")
        #expect(profile.baseURL.host == "api.particle.ai")
    }

    @Test func connectionSchemaMetadataOptOutBlocksTextToSQL() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let optedOut = DatabaseConnectionConfig(
            database: "widen_test",
            username: "beto",
            allowCloudSchemaMetadata: false
        )
        let allowed = DatabaseConnectionConfig(database: "widen_other", username: "beto")
        state.connections = [optedOut, allowed]
        state.particleAPIKeyOverride = .some(Self.particleKey)

        let generator = state.sqlGenerator(connectionID: optedOut.id, schema: Self.ordersSchema())

        #expect(generator is UnavailableSQLGenerator)
        do {
            _ = try await generator.generateSQL(
                question: "count orders",
                schema: Self.ordersSchema(),
                context: SQLGenerationContext(),
                config: SQLGenerationConfig()
            )
            Issue.record("expected the opted-out connection to refuse generation")
        } catch {
            #expect(error.localizedDescription.contains("Particle-1 SQL generation is disabled"))
            #expect(error.localizedDescription.contains("schema metadata sharing is turned off"))
        }
        #expect(
            state.textToSQLUnavailableMessage(for: optedOut.id)?
                .contains("schema metadata sharing is turned off") == true
        )
        #expect(state.textToSQLUnavailableMessage(for: allowed.id) == nil)
        #expect(state.sqlGenerator(connectionID: allowed.id, schema: Self.ordersSchema()) is SchemaToolSQLAgent)

        state.useMockAI = true
        #expect(state.textToSQLUnavailableMessage(for: optedOut.id) == nil)
        state.useMockAI = false
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

    @Test(arguments: [String?.none, ""])
    func missingParticleKeyReportsNotConfigured(storedKey: String?) {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        state.particleAPIKeyOverride = .some(storedKey)

        guard case .notConfigured(let message) = state.textToSQLStatus else {
            Issue.record("expected notConfigured, got \(state.textToSQLStatus)")
            return
        }
        #expect(message.contains("Particle API key"))
        #expect(message.contains("Settings › LLM"))
        #expect(state.textToSQLStatus.needsAttention)
        #expect(state.textToSQLStatus.chipTitle == "Particle-1")
        #expect(state.sqlGenerator is UnavailableSQLGenerator)
        #expect(!(state.sqlGenerator is CloudSQLGenerator))
        #expect(state.activeBackendDisplayName == "Particle-1")
        #expect(state.modelAvailabilityMessage?.contains("Particle API key") == true)
        #expect(state.modelAvailabilityMessage?.contains("on-device") == false)
    }

    @Test func connectionAutofillParserIsDeterministic() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        #expect(state.connectionDetailsParser is MockConnectionDetailsParser)
        #expect(state.titleGenerator(for: .naturalLanguage, connectionID: nil) is MockTitleGenerator)
        state.particleAPIKeyOverride = .some(Self.particleKey)
        #expect(state.connectionDetailsParser is MockConnectionDetailsParser)
    }

    @Test func launchRemovesRetiredAIPreferences() async {
        clearDefaults()
        UserDefaults.standard.set("local", forKey: "WidenAIBackendMode")
        UserDefaults.standard.set("applePCC", forKey: "WidenCloudAIProvider")
        UserDefaults.standard.set("custom/model-id", forKey: "WidenOpenRouterModelID")
        UserDefaults.standard.set(false, forKey: "WidenOpenRouterSchemaToolAgentEnabled")
        UserDefaults.standard.set(false, forKey: "WidenExperimentalCloudSchemaAgentEnabled")
        UserDefaults.standard.set(true, forKey: Self.compatibilityAlertKey)
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        await state.onLaunch()

        for key in Self.defaultsKeys where key != "WidenUseMockAI" {
            #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key) survived launch")
        }
        #expect(state.loadParticleAPIKey() == nil)
    }

    // MARK: - Key storage

    @Test func savingAndRemovingTheKeyGoesThroughTheTestSeam() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }

        #expect(state.setParticleAPIKey("  \(Self.particleKey)\n"))
        #expect(state.loadParticleAPIKey() == Self.particleKey)
        #expect(state.textToSQLStatus == .ready)

        #expect(state.setParticleAPIKey(""))
        #expect(state.loadParticleAPIKey() == nil)
        #expect(state.textToSQLStatus == .notConfigured(AppState.missingParticleAPIKeyMessage))
        #expect(state.errorBanner == nil)
    }

    @Test(arguments: ["sk-or-v1-0123456789abcdef", "SK-OR-V1-0123", "  sk-or-v1-0123"])
    func openRouterKeysAreRefused(key: String) {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        state.particleAPIKeyOverride = .some(Self.particleKey)

        #expect(!state.setParticleAPIKey(key))
        #expect(state.loadParticleAPIKey() == Self.particleKey)
        #expect(state.errorBanner?.contains("OpenRouter key") == true)
        #expect(state.errorBanner?.contains("pai-") == true)
        #expect(state.textToSQLStatus == .ready)
    }

    // MARK: - Runtime issues

    @Test func rejectedKeyBecomesARuntimeIssueUntilARunAnswers() async {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        state.connections = [connection]
        state.schemas[connection.id] = Self.ordersSchema()
        state.particleAPIKeyOverride = .some(Self.particleKey)
        let controller = SessionController(session: QuerySession(connectionID: connection.id))

        state.sqlGeneratorOverride = ThrowingGenerator(
            failure: CloudRequestFailure(
                category: .authentication,
                message: "Invalid bearer credential.",
                httpStatus: 401
            )
        )
        await ask("count orders", controller: controller, state: state)

        #expect(state.particleRuntimeIssue == .keyRejected)
        guard case .unavailable(let message) = state.textToSQLStatus else {
            Issue.record("expected unavailable, got \(state.textToSQLStatus)")
            return
        }
        #expect(message.contains("rejected"))
        #expect(state.textToSQLStatus.needsAttention)
        #expect(state.modelAvailabilityMessage == message)

        // A transient failure says nothing new about the key.
        state.sqlGeneratorOverride = ThrowingGenerator(
            failure: CloudRequestFailure(category: .providerUnavailable, message: "Upstream down.", httpStatus: 503)
        )
        await ask("count orders again", controller: controller, state: state)
        #expect(state.particleRuntimeIssue == .keyRejected)

        state.sqlGeneratorOverride = AnsweringGenerator()
        await ask("count all orders", controller: controller, state: state)

        #expect(state.particleRuntimeIssue == nil)
        #expect(state.textToSQLStatus == .ready)
    }

    @Test func runtimeIssueClearsWhenTheKeyChanges() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        state.particleAPIKeyOverride = .some(Self.particleKey)

        state.noteTextToSQLOutcome(.failed(.paymentRequired))
        #expect(state.textToSQLStatus == .unavailable(ParticleRuntimeIssue.outOfCredits.message))
        #expect(state.textToSQLStatus.message?.contains("out of credits") == true)

        #expect(state.setParticleAPIKey("pai-replacement-key"))
        #expect(state.particleRuntimeIssue == nil)
        #expect(state.textToSQLStatus == .ready)

        state.noteTextToSQLOutcome(.failed(.permissionDenied))
        #expect(state.textToSQLStatus == .unavailable(ParticleRuntimeIssue.inferenceNotAllowed.message))
        #expect(state.setParticleAPIKey(""))
        #expect(state.particleRuntimeIssue == nil)
        #expect(state.textToSQLStatus == .notConfigured(AppState.missingParticleAPIKeyMessage))
    }

    @Test func mockRunsDoNotChangeTheRuntimeIssue() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        state.particleAPIKeyOverride = .some(Self.particleKey)

        state.noteTextToSQLOutcome(.failed(.authentication))
        state.useMockAI = true
        state.noteTextToSQLOutcome(.answered)
        state.useMockAI = false

        #expect(state.particleRuntimeIssue == .keyRejected)
        state.noteTextToSQLOutcome(.failed(nil))
        state.noteTextToSQLOutcome(.failed(.rateLimited))
        #expect(state.particleRuntimeIssue == .keyRejected)
    }

    // MARK: - Chat notice

    @Test func chatNoticeLeadsWithTheKeyThenTheConnection() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let optedOut = DatabaseConnectionConfig(
            database: "widen_test",
            username: "beto",
            allowCloudSchemaMetadata: false
        )
        let allowed = DatabaseConnectionConfig(database: "widen_other", username: "beto")
        state.connections = [optedOut, allowed]

        // No key blocks every connection, opted out or not.
        let missingKey = TextToSQLChatNotice(appState: state, connectionID: optedOut.id)
        #expect(missingKey == .model(.notConfigured(AppState.missingParticleAPIKeyMessage)))
        #expect(missingKey?.title == "Text-to-SQL needs a Particle API key")
        #expect(missingKey?.message == AppState.missingParticleAPIKeyMessage)
        #expect(missingKey?.detail == nil)
        #expect(missingKey?.actionTitle == "Open LLM Settings…")

        state.particleAPIKeyOverride = .some(Self.particleKey)
        state.noteTextToSQLOutcome(.failed(.authentication))
        let rejected = TextToSQLChatNotice(appState: state, connectionID: allowed.id)
        #expect(rejected?.title == "Particle-1 needs attention")
        #expect(rejected?.detail == ParticleRuntimeIssue.keyRejected.message)
        #expect(rejected?.message == ParticleRuntimeIssue.keyRejected.message)
        #expect(rejected?.actionTitle == "Open LLM Settings…")

        state.noteTextToSQLOutcome(.answered)
        let connectionMessage =
            "Text-to-SQL is off for this connection because schema metadata sharing is turned off."
        #expect(state.textToSQLUnavailableMessage(for: optedOut.id) == connectionMessage)
        let notice = TextToSQLChatNotice(appState: state, connectionID: optedOut.id)
        #expect(notice == .connection(connectionMessage))
        #expect(notice?.title == connectionMessage)
        #expect(notice?.message == connectionMessage)
        #expect(notice?.detail == nil)
        #expect(notice?.actionTitle == "Open Database Settings…")
        #expect(TextToSQLChatNotice(appState: state, connectionID: allowed.id) == nil)
        #expect(state.textToSQLUnavailableMessage(for: UUID()) == nil)
    }

    @Test func mockModeShowsNoChatNotice() {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let optedOut = DatabaseConnectionConfig(
            database: "widen_test",
            username: "beto",
            allowCloudSchemaMetadata: false
        )
        state.connections = [optedOut]

        state.useMockAI = true
        #expect(TextToSQLChatNotice(appState: state, connectionID: optedOut.id) == nil)
        state.useMockAI = false
        #expect(TextToSQLChatNotice(appState: state, connectionID: optedOut.id) != nil)
    }

    // MARK: - Credential leak

    /// Runs one agent generation and one one-shot generation through the app's
    /// own generator selection, then checks that every request the Particle key
    /// signed went to api.particle.ai and nowhere else.
    @Test func particleGenerationsOnlyEverContactParticle() async throws {
        clearDefaults()
        let (state, dir) = makeState()
        defer { cleanUp(dir) }
        let connection = DatabaseConnectionConfig(database: "widen_test", username: "beto")
        let schema = Self.ordersSchema()
        state.connections = [connection]
        state.schemas[connection.id] = schema
        state.particleAPIKeyOverride = .some(Self.particleKey)
        let transport = RecordingTransport { request, _ in
            (try ParticleLeakFixtures.response(to: request), RecordingTransport.response(to: request))
        }
        state.cloudTransportOverride = transport

        let agent = state.sqlGenerator(connectionID: connection.id, schema: schema)
        #expect(agent is SchemaToolSQLAgent)
        let agentResult = try await agent.generateSQL(
            question: "How many orders are there?",
            schema: schema,
            context: SQLGenerationContext(),
            config: SQLGenerationConfig()
        )
        #expect(agentResult.sql == ParticleLeakFixtures.agentSQL)

        let oneShot = state.sqlGenerator
        #expect(oneShot is CloudSQLGenerator)
        let oneShotResult = try await oneShot.generateSQL(
            question: "List order ids",
            schema: schema,
            context: SQLGenerationContext(),
            config: SQLGenerationConfig()
        )
        #expect(oneShotResult.sql == ParticleLeakFixtures.oneShotSQL)

        let requests = transport.requests
        #expect(requests.count == 4)
        for request in requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "api.particle.ai")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.particleKey)")
            let headers = (request.allHTTPHeaderFields ?? [:])
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let url = request.url?.absoluteString ?? ""
            for text in [url, headers, body] {
                #expect(!text.lowercased().contains("openrouter"))
            }
        }
    }

    private func ask(_ question: String, controller: SessionController, state: AppState) async {
        controller.chatVM.input = question
        await controller.submit(appState: state)
    }
}

private struct ThrowingGenerator: SQLGenerator {
    let failure: CloudRequestFailure

    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        throw failure
    }
}

private struct AnsweringGenerator: SQLGenerator {
    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "SELECT id FROM public.orders LIMIT 100",
            explanation: "Lists order ids.",
            assumptions: [],
            referencedTables: ["public.orders"],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
    }
}

/// Particle-1 replies for the leak test: the agent searches, describes the
/// orders table, then submits SQL; the one-shot request gets a JSON answer.
private enum ParticleLeakFixtures {
    static let agentSQL = "SELECT COUNT(*) AS order_count FROM public.orders"
    static let oneShotSQL = "SELECT id FROM public.orders LIMIT 100"

    static func response(to request: URLRequest) throws -> Data {
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard body["tools"] != nil else {
            return completion(message: [
                "role": "assistant",
                "content": jsonString([
                    "sql": oneShotSQL,
                    "explanation": "Lists order ids.",
                    "assumptions": [String](),
                    "referencedTables": ["public.orders"],
                    "confidence": 0.9,
                    "riskLevel": "low",
                    "needsClarification": false,
                    "clarificationQuestion": NSNull(),
                ]),
            ], finishReason: "stop")
        }
        let messages = try #require(body["messages"] as? [[String: Any]])
        let toolResults = messages.filter { $0["role"] as? String == "tool" }
        let call: [String: Any]
        switch toolResults.count {
        case 0:
            call = toolCall("search_schema", ["query": "orders", "limit": 4])
        case 1:
            call = toolCall("describe_tables", ["table_ids": [try ordersHandle(in: toolResults)]])
        default:
            call = toolCall(
                SchemaToolSQLAgent.terminalToolName,
                ["action": "sql", "sql": agentSQL, "clarification_question": ""]
            )
        }
        return completion(
            message: ["role": "assistant", "tool_calls": [call]],
            finishReason: "tool_calls"
        )
    }

    private static func ordersHandle(in toolResults: [[String: Any]]) throws -> String {
        for message in toolResults {
            guard let content = message["content"] as? String,
                let result = try? JSONDecoder().decode(SchemaToolResult.self, from: Data(content.utf8)),
                let hits = result.payload?["hits"]?.arrayValue
            else { continue }
            for hit in hits where hit["sql_name"]?.stringValue == #""public"."orders""# {
                if let handle = hit["table_id"]?.stringValue {
                    return handle
                }
            }
        }
        throw URLError(.cannotParseResponse)
    }

    private static func toolCall(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        [
            "id": "call_0",
            "type": "function",
            "function": ["name": name, "arguments": jsonString(arguments)],
        ]
    }

    private static func completion(message: [String: Any], finishReason: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "model": ParticleTestSupport.returnedModelID,
            "choices": [["index": 0, "finish_reason": finishReason, "message": message]],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15,
                "prompt_tokens_details": ["cached_tokens": 0],
                "completion_tokens_details": ["reasoning_tokens": 1],
            ],
        ])
    }

    private static func jsonString(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
