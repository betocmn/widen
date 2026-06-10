import Foundation
import Testing

@testable import WidenKit

@Suite("AppState sessions")
@MainActor
struct AppStateSessionTests {
    private struct StubTitleGenerator: SessionTitleGenerating {
        var result: String
        func generateTitle(for question: String) async throws -> String {
            result
        }
    }

    private struct FailingTitleGenerator: SessionTitleGenerating {
        func generateTitle(for question: String) async throws -> String {
            throw AppError.modelUnavailable("The local model is unavailable.")
        }
    }

    private func makeState() -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir)
        )
        return (state, dir)
    }

    @Test func createSessionSelectsAndPersistsIt() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()

        let session = state.createSession(connectionID: connectionID)

        #expect(session.title == QuerySession.placeholderTitle)
        #expect(state.selectedSessionID == session.id)
        #expect(state.selectedController?.sessionID == session.id)
        #expect(state.sessions(for: connectionID).map(\.id) == [session.id])
        #expect(try state.sessionStore.load().map(\.id) == [session.id])
    }

    @Test func controllerCacheKeepsRuntimeStateAcrossSwitches() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)

        state.selectSession(first.id)
        let controller = state.selectedController
        controller?.chatVM.input = "draft question"

        state.selectSession(second.id)
        state.selectSession(first.id)

        #expect(state.selectedController === controller)
        #expect(state.selectedController?.chatVM.input == "draft question")
    }

    @Test func switchingSessionsSnapshotsOutgoingEdits() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)

        state.selectSession(first.id)
        state.selectedController?.queryVM.sqlText = "SELECT 1"
        state.selectSession(second.id)

        #expect(state.session(for: first.id)?.sqlText == "SELECT 1")
    }

    @Test func archiveHidesSessionAndMovesSelection() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)
        state.selectSession(second.id)

        state.archiveSession(second.id)

        #expect(state.session(for: second.id)?.isArchived == true)
        #expect(state.sessions(for: connectionID).map(\.id) == [first.id])
        #expect(state.archivedSessions.map(\.id) == [second.id])
        #expect(state.selectedSessionID == first.id)
    }

    @Test func restoreUnarchivesSession() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let session = state.createSession(connectionID: connectionID)
        state.archiveSession(session.id)

        state.restoreSession(session.id)

        #expect(state.session(for: session.id)?.isArchived == false)
        #expect(state.sessions(for: connectionID).map(\.id) == [session.id])
    }

    @Test func deleteForeverRemovesSessionFromDisk() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())
        state.archiveSession(session.id)

        state.deleteSessionForever(session.id)

        #expect(state.session(for: session.id) == nil)
        #expect(try state.sessionStore.load().isEmpty)
    }

    @Test func manualRenameBlocksGeneratedTitles() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.renameSession(session.id, to: "My Title")
        state.applyGeneratedTitle("Generated Title", to: session.id)

        #expect(state.session(for: session.id)?.title == "My Title")
        #expect(state.session(for: session.id)?.titleWasManuallySet == true)
    }

    @Test func generatedTitleOnlyReplacesThePlaceholder() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.applyGeneratedTitle("Top Spenders", to: session.id)
        state.applyGeneratedTitle("Something Else", to: session.id)

        #expect(state.session(for: session.id)?.title == "Top Spenders")
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func emptyRenameIsIgnored() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.renameSession(session.id, to: "   ")

        #expect(state.session(for: session.id)?.title == QuerySession.placeholderTitle)
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func autoTitleAppliesSanitizedGeneratedTitle() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = StubTitleGenerator(result: "\"Top Spenders.\"")
        let session = state.createSession(connectionID: UUID())

        await state.autoTitleSession(session.id, question: "Which users have spent the most?")

        #expect(state.session(for: session.id)?.title == "Top Spenders")
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func autoTitleFallsBackToTruncatedQuestionOnFailure() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = FailingTitleGenerator()
        let session = state.createSession(connectionID: UUID())

        await state.autoTitleSession(session.id, question: "Which users have spent the most?")

        #expect(state.session(for: session.id)?.title == "Which users have spent the most?")
    }

    @Test func autoTitleNeverOverridesAManualRename() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = StubTitleGenerator(result: "Generated Title")
        let session = state.createSession(connectionID: UUID())
        state.renameSession(session.id, to: "My Title")

        await state.autoTitleSession(session.id, question: "anything")

        #expect(state.session(for: session.id)?.title == "My Title")
    }

    @Test func deleteConnectionCascadesToItsSessions() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let other = DatabaseConnectionConfig(database: "other", username: "u")
        state.connections = [config, other]
        let doomed = state.createSession(connectionID: config.id)
        let survivor = state.createSession(connectionID: other.id)
        state.selectSession(doomed.id)

        state.deleteConnection(config.id)

        #expect(state.connections.map(\.id) == [other.id])
        #expect(state.sessions.map(\.id) == [survivor.id])
        #expect(state.selectedSessionID == survivor.id)
        #expect(try state.sessionStore.load().map(\.id) == [survivor.id])
        #expect(try state.connectionStore.load().map(\.id) == [other.id])
    }
}
