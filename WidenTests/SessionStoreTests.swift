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
        #expect(restored.isArchived)
        #expect(restored.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(restored.updatedAt == Date(timeIntervalSince1970: 1_750_000_100))
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
    }
}
