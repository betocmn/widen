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

    private func makeController(connectionID: UUID) -> SessionController {
        SessionController(
            session: QuerySession(connectionID: connectionID),
            executor: ImmediateExecutor()
        )
    }

    @Test func completedRunAppendsResultRecordWithSnapshottedSQL() async {
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
        #expect(controller.focus == .results)
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

    @Test func submitWithDirectSQLSkipsGeneratorAndReturnsToChat() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.focus = .results
        controller.chatVM.input = "select id from users"

        await controller.submit(appState: state)

        #expect(controller.focus == .chat)
        #expect(controller.chatVM.messages.count == 1)
        #expect(controller.chatVM.messages[0].role == .user)
        #expect(controller.queryVM.sqlText == "select id from users")
        #expect(controller.queryVM.generation == nil)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}
