import Foundation
import Observation

/// Per-session runtime container: the live view models for one query
/// session, plus the copy-in/copy-out glue to the persisted `QuerySession`
/// value. Cached by `AppState` so switching sessions never loses in-flight
/// generations or query runs.
@MainActor
@Observable
public final class SessionController: Identifiable {
    private static let generatedSQLRepairRetryLimit = 5
    private static let generatedSQLRepairFailureMessage =
        "The database kept rejecting the generated SQL, so I stopped retrying. Try rephrasing the question or checking that the selected schema contains the tables you expect."

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
        guard !queryVM.isRunning else { return }
        let hadUserMessage = chatVM.messages.contains { $0.role == .user }
        if ChatViewModel.isDirectSQL(chatVM.input) {
            chatVM.submitDirectSQL(queryVM: queryVM)
        } else {
            let connection = appState.connection(for: connectionID)
            await chatVM.submit(
                schema: appState.promptSchema(for: connectionID),
                generator: appState.sqlGenerator,
                config: SQLGenerationConfig(
                    defaultRowLimit: connection?.defaultRowLimit ?? 100,
                    databaseContext: connection?.databaseContext ?? ""
                ),
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
        guard !queryVM.isRunning, !chatVM.isGenerating else { return }
        let sql = queryVM.sqlText
        let generation = queryVM.generation
        queryVM.startRun(
            connection: appState.connection(for: connectionID),
            postgres: appState.postgres(for: connectionID),
            isConnected: appState.connectionState(connectionID) == .connected
        ) { [weak self, weak appState] result, errorMessage in
            guard let self else { return }
            if let result {
                self.appendRunResult(result, sql: sql)
            } else if let errorMessage {
                if generation != nil,
                    Self.isRetryableGeneratedSQLError(errorMessage)
                {
                    Task { [weak self, weak appState] in
                        guard let self else { return }
                        guard let appState else {
                            self.chatVM.appendRunError(errorMessage)
                            return
                        }
                        await self.repairGeneratedSQL(
                            appState: appState,
                            startingSQL: sql,
                            firstError: errorMessage
                        )
                    }
                } else {
                    self.chatVM.appendRunError(errorMessage)
                }
            }
            appState?.sessionDidChange(self.sessionID)
        }
    }

    /// Wipes the transcript, the SQL preview, and the per-run result cache.
    public func clearConversation() {
        queryVM.clear()
        chatVM.clearConversation()
        results.removeAll()
    }

    private func repairGeneratedSQL(
        appState: AppState,
        startingSQL: String,
        firstError: String
    ) async {
        let questionContext = questionContextForRepair(startingSQL: startingSQL)
        removeGeneratedAssistant(matchingSQL: startingSQL)
        queryVM.clearGeneratedSQLForRetry()
        chatVM.beginGeneration(status: retryStatus(appState: appState, attempt: 1))
        appState.sessionDidChange(sessionID)
        defer { chatVM.finishGeneration() }

        guard let schema = appState.promptSchema(for: connectionID), !schema.tables.isEmpty else {
            chatVM.appendRunError(
                "I could not retry because the database schema is no longer available."
            )
            appState.sessionDidChange(sessionID)
            return
        }

        let connection = appState.connection(for: connectionID)
        let config = SQLGenerationConfig(
            defaultRowLimit: connection?.defaultRowLimit ?? 100,
            databaseContext: connection?.databaseContext ?? ""
        )
        let postgres = appState.postgres(for: connectionID)
        var failingSQL = startingSQL
        var lastError = firstError

        for attempt in 1...Self.generatedSQLRepairRetryLimit {
            chatVM.updateGenerationStatus(retryStatus(appState: appState, attempt: attempt))
            let context = SQLGenerationContext(
                recentQuestions: questionContext.recentQuestions,
                currentSQL: failingSQL,
                lastRunError: lastError
            )

            let generation: SQLGenerationResult
            do {
                generation = try await appState.sqlGenerator.generateSQL(
                    question: questionContext.question,
                    schema: schema,
                    context: context,
                    config: config
                )
            } catch {
                chatVM.appendRunError(error.localizedDescription)
                appState.sessionDidChange(sessionID)
                return
            }

            let generatedSQL = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !generatedSQL.isEmpty, !generation.needsClarification else {
                lastError = "The model did not return corrected SQL."
                continue
            }

            let execution = await queryVM.executeGeneratedSQLAttempt(
                sql: generatedSQL,
                connection: connection,
                postgres: postgres,
                isConnected: appState.connectionState(connectionID) == .connected
            )
            if let result = execution.result {
                var visibleGeneration = generation
                visibleGeneration.sql = generatedSQL
                appendAssistantGeneration(visibleGeneration)
                queryVM.setGeneration(visibleGeneration)
                appendRunResult(result, sql: generatedSQL)
                appState.sessionDidChange(sessionID)
                return
            }

            guard let errorMessage = execution.errorMessage else {
                lastError = "The query did not return a result."
                continue
            }
            guard Self.isRetryableGeneratedSQLError(errorMessage) else {
                chatVM.appendRunError(errorMessage)
                appState.sessionDidChange(sessionID)
                return
            }

            failingSQL = generatedSQL
            lastError = errorMessage
        }

        chatVM.appendRunError(Self.generatedSQLRepairFailureMessage)
        appState.sessionDidChange(sessionID)
    }

    private func appendAssistantGeneration(_ generation: SQLGenerationResult) {
        let text: String
        if generation.needsClarification,
            let clarification = generation.clarificationQuestion,
            !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            text = clarification
        } else {
            text = generation.explanation
        }
        chatVM.messages.append(ChatMessage(role: .assistant, text: text, generation: generation))
    }

    private func appendRunResult(_ result: QueryResult, sql: String) {
        let record = chatVM.appendRunRecord(
            ChatMessage.RunSummary(
                rowCount: result.rowCount,
                executionTimeMs: result.executionTimeMs,
                truncated: result.truncated,
                sql: sql
            ))
        results[record.id] = result
    }

    private func retryStatus(appState: AppState, attempt: Int) -> String {
        "The query hit an error. Asking \(appState.activeBackendDisplayName) to fix it (\(attempt)/\(Self.generatedSQLRepairRetryLimit))…"
    }

    private func questionContextForRepair(
        startingSQL: String
    ) -> (question: String, recentQuestions: [String]) {
        let anchorIndex = chatVM.messages.lastIndex { message in
            message.role == .assistant
                && Self.normalizedSQL(message.generation?.sql ?? "") == Self.normalizedSQL(startingSQL)
        }
        let upperBound = anchorIndex ?? chatVM.messages.endIndex
        let userQuestions = chatVM.messages[..<upperBound]
            .filter { $0.role == .user }
            .map(\.text)
        let question = userQuestions.last ?? "Fix the generated SQL so it runs successfully."
        return (question, Array(userQuestions.dropLast().suffix(3)))
    }

    private func removeGeneratedAssistant(matchingSQL sql: String) {
        let normalized = Self.normalizedSQL(sql)
        guard let index = chatVM.messages.lastIndex(where: { message in
            message.role == .assistant
                && Self.normalizedSQL(message.generation?.sql ?? "") == normalized
        }) else { return }
        chatVM.messages.remove(at: index)
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRetryableGeneratedSQLError(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != AppError.notConnected.localizedDescription else { return false }
        guard !trimmed.contains("Stopped waiting for the query") else { return false }
        return true
    }
}
