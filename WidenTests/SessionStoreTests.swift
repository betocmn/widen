import Foundation
import Testing

@testable import WidenKit

@Suite("SessionStore")
struct SessionStoreTests {
    private func makeTempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        return (SessionStore(directory: dir), dir)
    }

    private func makeGeneration() -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "SELECT id FROM users LIMIT 10",
            explanation: "Lists user ids.",
            assumptions: ["Assumes id is the primary key."],
            referencedTables: ["public.users"],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
    }

    @Test func loadFromEmptyDirectoryReturnsNoSessions() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load().isEmpty)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let connectionID = UUID()
        var session = QuerySession(connectionID: connectionID)
        session.title = "Top spenders"
        session.titleWasManuallySet = true
        session.messages = [
            ChatMessage(role: .user, text: "Which users have spent the most?"),
            ChatMessage(
                role: .assistant, text: "Lists user ids.", generation: makeGeneration()),
        ]
        session.sqlText = "SELECT id FROM users LIMIT 10"
        session.lastGeneration = makeGeneration()
        session.viewDataTarget = QuerySession.ViewDataTarget(schema: "public", table: "users")
        session.isArchived = true
        session.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        session.updatedAt = Date(timeIntervalSince1970: 1_750_000_100)

        try store.save([session])
        let loaded = try store.load()

        #expect(loaded.count == 1)
        let restored = try #require(loaded.first)
        #expect(restored.id == session.id)
        #expect(restored.connectionID == connectionID)
        #expect(restored.title == "Top spenders")
        #expect(restored.titleWasManuallySet)
        #expect(restored.messages.count == 2)
        #expect(restored.messages[0].role == .user)
        #expect(restored.messages[1].generation == makeGeneration())
        #expect(restored.sqlText == "SELECT id FROM users LIMIT 10")
        #expect(restored.lastGeneration == makeGeneration())
        #expect(restored.viewDataTarget == QuerySession.ViewDataTarget(schema: "public", table: "users"))
        #expect(restored.isArchived)
        #expect(restored.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(restored.updatedAt == Date(timeIntervalSince1970: 1_750_000_100))
    }

    @Test func legacySessionWithoutViewDataTargetDecodes() throws {
        let legacy = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "connectionID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "title": "New Session",
              "titleWasManuallySet": false,
              "messages": [],
              "sqlText": "",
              "isArchived": false,
              "createdAt": "2025-06-15T12:00:00Z",
              "updatedAt": "2025-06-15T12:00:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(QuerySession.self, from: Data(legacy.utf8))

        #expect(decoded.viewDataTarget == nil)
    }

    @Test func saveOverwritesPreviousContents() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([QuerySession(connectionID: UUID()), QuerySession(connectionID: UUID())])
        let survivor = QuerySession(connectionID: UUID(), title: "Only one")
        try store.save([survivor])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Only one")
    }

    @Test func corruptedFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) {
            try store.load()
        }
    }
}

@Suite("ChatMessage codable")
struct ChatMessageCodableTests {
    @Test func roundTripPreservesAllFields() throws {
        var message = ChatMessage(
            role: .assistant,
            text: "Lists user ids.",
            generation: SQLGenerationResult(
                sql: "SELECT 1",
                explanation: "Constant.",
                assumptions: [],
                referencedTables: [],
                confidence: 1.0,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            )
        )
        message.timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ChatMessage.self, from: encoder.encode(message))

        #expect(decoded == message)
    }

    @Test func roleRawValuesAreStable() {
        // Raw values are the on-disk format — changing them breaks old files.
        #expect(ChatMessage.Role.user.rawValue == "user")
        #expect(ChatMessage.Role.assistant.rawValue == "assistant")
        #expect(ChatMessage.Role.error.rawValue == "error")
        #expect(ChatMessage.Role.activity.rawValue == "activity")
        #expect(ChatMessage.Role.result.rawValue == "result")
    }

    @Test func activityMessagesAreExcludedFromPromptContext() {
        let messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .activity, text: "Focused repair started."),
            ChatMessage(role: .assistant, text: "Lists users."),
        ]

        let context = messages.sqlConversationMessages()
        let roles: [SQLConversationMessage.Role] = context.map { $0.role }
        let texts = context.map { $0.text }

        #expect(roles == [.user, .assistant])
        #expect(texts.contains("Focused repair started.") == false)
    }

    @Test func runRecordRoundTripPreservesSummary() throws {
        let summary = ChatMessage.RunSummary(
            rowCount: 42, executionTimeMs: 123, truncated: true,
            sql: "SELECT id FROM users LIMIT 100")
        var message = ChatMessage.runRecord(summary)
        message.timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: encoder.encode(message))

        #expect(decoded == message)
        #expect(decoded.role == .result)
        #expect(decoded.runSummary == summary)
        #expect(decoded.text == "Returned 42 rows in 123 ms (truncated at row limit)")
    }

    @Test func runRecordTextForSingleUntruncatedRow() {
        let message = ChatMessage.runRecord(
            ChatMessage.RunSummary(
                rowCount: 1, executionTimeMs: 7, truncated: false, sql: "SELECT 1"))
        #expect(message.text == "Returned 1 row in 7 ms")
    }

    @Test func runRecordUsesAffectedTextForUpsertUpdates() {
        let message = ChatMessage.runRecord(
            ChatMessage.RunSummary(
                rowCount: 2,
                executionTimeMs: 15,
                truncated: false,
                sql: """
                    INSERT INTO users (id, email) VALUES (1, 'a@example.com')
                    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email
                    """,
                kind: .insert
            ))

        #expect(message.text == "Affected 2 rows in 15 ms")
    }

    @Test func legacyMessageWithoutRunSummaryDecodes() throws {
        // A pre-runSummary message as written by older builds.
        let legacy = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "role": "assistant",
              "text": "Lists user ids.",
              "timestamp": "2025-06-15T12:00:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: Data(legacy.utf8))

        #expect(decoded.role == .assistant)
        #expect(decoded.runSummary == nil)
        #expect(decoded.generation == nil)
    }

    @Test func legacyGenerationWithoutGroundingFieldsDecodes() throws {
        let legacy = """
            {
              "sql": "SELECT 1",
              "explanation": "Constant.",
              "assumptions": [],
              "referencedTables": [],
              "confidence": 1.0,
              "riskLevel": "low",
              "needsClarification": false,
              "clarificationQuestion": null
            }
            """
        let decoded = try JSONDecoder().decode(
            SQLGenerationResult.self,
            from: Data(legacy.utf8)
        )

        #expect(decoded.sql == "SELECT 1")
        #expect(decoded.groundingConcepts.isEmpty)
        #expect(decoded.clarificationOptions.isEmpty)
        #expect(decoded.pendingClarification == nil)
    }
}
