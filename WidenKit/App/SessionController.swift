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
    public let queryVM: QueryResultViewModel
    /// Materialized results keyed by their run-record message, so every run
    /// of this live session keeps its full table in the transcript. Never
    /// persisted — after a relaunch the records render as summary rows.
    public private(set) var results: [UUID: QueryResult] = [:]

    public convenience init(session: QuerySession) {
        self.init(session: session, executor: QueryExecutionService())
    }

    init(session: QuerySession, executor: any QueryExecuting) {
        self.sessionID = session.id
        self.connectionID = session.connectionID
        self.queryVM = QueryResultViewModel(executor: executor)
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

    /// Submits the chat input: raw SQL goes straight to the preview, anything
    /// else is generated against this session's connection.
    public func submit(appState: AppState) async {
        let hadUserMessage = chatVM.messages.contains { $0.role == .user }
        if ChatViewModel.isDirectSQL(chatVM.input) {
            chatVM.submitDirectSQL(queryVM: queryVM)
        } else {
            await chatVM.submit(
                schema: appState.promptSchema(for: connectionID),
                generator: appState.sqlGenerator,
                config: SQLGenerationConfig(
                    defaultRowLimit: appState.connection(for: connectionID)?.defaultRowLimit
                        ?? 100),
                queryVM: queryVM
            )
        }
        appState.sessionDidChange(sessionID)

        // Auto-name the session after its very first question.
        if !hadUserMessage,
            let firstQuestion = chatVM.messages.first(where: { $0.role == .user })?.text
        {
            let sessionID = sessionID
            Task { await appState.autoTitleSession(sessionID, question: firstQuestion) }
        }
    }

    /// Runs the SQL preview contents against this session's connection. The
    /// outcome — row count or error, including the "stopped waiting"
    /// cancellation — is appended to the chat transcript so the history
    /// records every run; the latest result renders inline as a card.
    public func runQuery(appState: AppState) {
        guard !queryVM.isRunning else { return }
        let sql = queryVM.sqlText
        queryVM.startRun(
            connection: appState.connection(for: connectionID),
            postgres: appState.postgres(for: connectionID),
            isConnected: appState.connectionState(connectionID) == .connected
        ) { [weak self, weak appState] result, errorMessage in
            guard let self else { return }
            if let result {
                let record = self.chatVM.appendRunRecord(
                    ChatMessage.RunSummary(
                        rowCount: result.rowCount,
                        executionTimeMs: result.executionTimeMs,
                        truncated: result.truncated,
                        sql: sql
                    ))
                self.results[record.id] = result
            } else if let errorMessage {
                self.chatVM.appendRunError(errorMessage)
            }
            appState?.sessionDidChange(self.sessionID)
        }
    }

    /// Wipes the transcript, the SQL preview, and the per-run result cache.
    public func clearConversation() {
        chatVM.clearConversation()
        queryVM.clear()
        results.removeAll()
    }
}
