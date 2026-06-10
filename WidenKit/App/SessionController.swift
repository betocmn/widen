import Foundation
import Observation

/// Per-session runtime container: the live view models for one query
/// session, plus the copy-in/copy-out glue to the persisted `QuerySession`
/// value. Cached by `AppState` so switching sessions never loses in-flight
/// generations or query runs.
@MainActor
@Observable
public final class SessionController: Identifiable {
    public let sessionID: UUID
    public let connectionID: UUID
    public let chatVM = ChatViewModel()
    public let queryVM = QueryResultViewModel()

    public init(session: QuerySession) {
        self.sessionID = session.id
        self.connectionID = session.connectionID
        hydrate(from: session)
    }

    /// Loads persisted state into the live view models.
    public func hydrate(from session: QuerySession) {
        chatVM.messages = session.messages
        queryVM.restore(sqlText: session.sqlText, generation: session.lastGeneration)
    }

    /// Copies live state back into the session value. Returns true when
    /// anything changed (and bumps `updatedAt`).
    public func snapshot(into session: inout QuerySession) -> Bool {
        var changed = false
        if session.messages != chatVM.messages {
            session.messages = chatVM.messages
            changed = true
        }
        if session.sqlText != queryVM.sqlText {
            session.sqlText = queryVM.sqlText
            changed = true
        }
        if session.lastGeneration != queryVM.generation {
            session.lastGeneration = queryVM.generation
            changed = true
        }
        if changed {
            session.updatedAt = Date()
        }
        return changed
    }

    /// Generates SQL for the chat input against this session's connection.
    public func submit(appState: AppState) async {
        let hadUserMessage = chatVM.messages.contains { $0.role == .user }
        await chatVM.submit(
            schema: appState.schemas[connectionID],
            generator: appState.sqlGenerator,
            config: SQLGenerationConfig(
                defaultRowLimit: appState.connection(for: connectionID)?.defaultRowLimit ?? 100),
            queryVM: queryVM
        )
        appState.sessionDidChange(sessionID)

        // Auto-name the session after its very first question.
        if !hadUserMessage,
            let firstQuestion = chatVM.messages.first(where: { $0.role == .user })?.text
        {
            let sessionID = sessionID
            Task { await appState.autoTitleSession(sessionID, question: firstQuestion) }
        }
    }

    /// Runs the SQL editor contents against this session's connection.
    public func runQuery(appState: AppState) {
        queryVM.startRun(
            connection: appState.connection(for: connectionID),
            postgres: appState.postgres(for: connectionID),
            isConnected: appState.connectionState(connectionID) == .connected
        )
    }
}
