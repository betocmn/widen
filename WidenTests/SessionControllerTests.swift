import Foundation
import Testing

@testable import WidenKit

@Suite("SessionController")
@MainActor
struct SessionControllerTests {
    private struct ImmediateExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            QueryResult(
                columns: ["value"],
                rows: [["1"], ["2"]],
                rowCount: 2,
                truncated: false,
                executionTimeMs: 5
            )
        }
    }

    private struct SlowExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            try await Task.sleep(for: .seconds(30))
            return QueryResult(
                columns: ["value"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 1
            )
        }
    }

    private func makeState(connectionID: UUID, connected: Bool) -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir)
        )
        state.connections = [DatabaseConnectionConfig(id: connectionID)]
        if connected {
            state.connectionStates[connectionID] = .connected
        }
        return (state, dir)
    }

    private func makeController(
        connectionID: UUID,
        executor: any QueryExecuting = ImmediateExecutor()
    ) -> SessionController {
        SessionController(
            session: QuerySession(connectionID: connectionID),
            executor: executor
        )
    }

    @Test func completedRunAppendsResultRecordWithSnapshottedSQL() async throws {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.queryVM.setDirectSQL("SELECT id FROM users")

        controller.runQuery(appState: state)
        await waitUntil { !controller.queryVM.isRunning }

        let record = controller.chatVM.messages.last
        #expect(record?.role == .result)
        #expect(record?.runSummary?.rowCount == 2)
        #expect(record?.runSummary?.executionTimeMs == 5)
        #expect(record?.runSummary?.sql == "SELECT id FROM users")
        // The materialized result is kept per record, so every run's card
        // stays in the transcript for the life of the session.
        let recordID = try #require(record?.id)
        #expect(controller.results[recordID]?.rowCount == 2)
    }

    @Test func failedRunAppendsErrorMessage() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.queryVM.setDirectSQL("SELECT 1")

        controller.runQuery(appState: state)
        await waitUntil { !controller.queryVM.isRunning }

        #expect(controller.chatVM.messages.last?.role == .error)
        #expect(
            controller.chatVM.messages.last?.text
                == AppError.notConnected.errorDescription)
    }

    @Test func submitWithDirectSQLSkipsGenerator() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "select id from users"

        await controller.submit(appState: state)

        #expect(controller.chatVM.messages.count == 1)
        #expect(controller.chatVM.messages[0].role == .user)
        #expect(controller.queryVM.sqlText == "select id from users")
        #expect(controller.queryVM.generation == nil)
    }

    @Test func clearConversationCancelsActiveRunWithoutAppendingCompletion() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID, executor: SlowExecutor())
        controller.queryVM.setDirectSQL("SELECT id FROM users")

        controller.runQuery(appState: state)
        #expect(controller.queryVM.isRunning)

        controller.clearConversation()
        await Task.yield()

        #expect(controller.queryVM.isRunning == false)
        #expect(controller.chatVM.messages.isEmpty)
        #expect(controller.queryVM.sqlText.isEmpty)
        #expect(controller.queryVM.runError == nil)
        #expect(controller.results.isEmpty)
    }

    @Test func submitIsIgnoredWhileQueryIsRunning() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID, executor: SlowExecutor())
        controller.queryVM.setDirectSQL("SELECT id FROM users")
        controller.runQuery(appState: state)
        controller.chatVM.input = "SELECT email FROM users"

        await controller.submit(appState: state)

        #expect(controller.queryVM.isRunning)
        #expect(controller.queryVM.sqlText == "SELECT id FROM users")
        #expect(controller.chatVM.input == "SELECT email FROM users")
        #expect(controller.chatVM.messages.isEmpty)

        controller.queryVM.cancelRun()
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}
