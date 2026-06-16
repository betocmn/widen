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
            await submitGeneratedSQL(appState: appState)
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
    /// `confirmed` is true only when the user approved a destructive write
    /// (DELETE, or UPDATE without WHERE) in the Run confirmation dialog.
    public func runQuery(appState: AppState, confirmed: Bool = false) {
        guard !queryVM.isRunning, !chatVM.isGenerating else { return }
        let sql = queryVM.sqlText
        let generation = queryVM.generation
        queryVM.startRun(
            connection: appState.connection(for: connectionID),
            postgres: appState.postgres(for: connectionID),
            isConnected: appState.connectionState(connectionID) == .connected,
            confirmed: confirmed
        ) { [weak self, weak appState] result, errorMessage in
            guard let self else { return }
            // `startRun` validated `sql` as part of the run; reuse that result
            // instead of re-tokenizing, and route the error by statement kind.
            let isWrite = self.queryVM.validation?.kind.isWrite == true
            if let result {
                self.appendRunResult(result, sql: sql)
            } else if let errorMessage {
                if isWrite {
                    // Writes never auto-retry: show the error immediately. When
                    // the query was AI-generated, offer a one-shot "Try Again".
                    if generation != nil,
                        Self.isRetryableGeneratedSQLError(errorMessage)
                    {
                        self.chatVM.appendWriteRunError(errorMessage, failedSQL: sql)
                    } else {
                        self.chatVM.appendRunError(errorMessage)
                    }
                } else if generation != nil,
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

    /// One-shot "Try Again" for a failed write: asks the model to repair the
    /// SQL and drops it into the editor WITHOUT executing. Writes never
    /// auto-execute, so the user must press Run again (and confirm if
    /// destructive). Each tap is a single regenerate — no retry loop.
    public func retryFailedWrite(appState: AppState, failedSQL: String, error: String) async {
        guard !queryVM.isRunning, !chatVM.isGenerating else { return }
        guard let schema = appState.promptSchema(for: connectionID), !schema.tables.isEmpty else {
            chatVM.appendRunError(
                "I could not retry because the database schema is no longer available."
            )
            appState.sessionDidChange(sessionID)
            return
        }

        let questionContext = questionContextForRepair(startingSQL: failedSQL)
        let context = SQLGenerationContext(
            recentQuestions: questionContext.recentQuestions,
            currentSQL: failedSQL,
            lastRunError: error
        )
        let connection = appState.connection(for: connectionID)
        let config = SQLGenerationConfig(
            defaultRowLimit: connection?.defaultRowLimit ?? 100,
            databaseContext: connection?.databaseContext ?? ""
        )

        chatVM.beginGeneration(
            status: "Asking \(appState.activeBackendDisplayName) to fix the query…"
        )
        appState.sessionDidChange(sessionID)
        defer {
            chatVM.finishGeneration()
            appState.sessionDidChange(sessionID)
        }

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
            return
        }

        if generation.needsClarification,
            let clarification = generation.clarificationQuestion,
            !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            chatVM.messages.append(
                ChatMessage(role: .assistant, text: clarification, generation: generation)
            )
            return
        }

        let generatedSQL = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generatedSQL.isEmpty else {
            appendAssistantGeneration(generation)
            return
        }

        // Fill the editor only. Execution still requires an explicit Run.
        let visibleGeneration = generation.withSQL(generatedSQL)
        appendAssistantGeneration(visibleGeneration)
        queryVM.setGeneration(visibleGeneration)
    }

    /// Wipes the transcript, the SQL preview, and the per-run result cache.
    public func clearConversation() {
        guard queryVM.clear() else { return }
        chatVM.clearConversation()
        results.removeAll()
    }

    private func submitGeneratedSQL(appState: AppState) async {
        let question = chatVM.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chatVM.isGenerating, !queryVM.isRunning else { return }
        guard let schema = appState.promptSchema(for: connectionID), !schema.tables.isEmpty else {
            chatVM.appendRunError(
                "Connect to a database and load its schema before asking questions."
            )
            return
        }

        let context = SQLGenerationContext(
            recentQuestions: chatVM.messages.filter { $0.role == .user }.suffix(3).map(\.text),
            currentSQL: queryVM.sqlText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : queryVM.sqlText,
            lastRunError: queryVM.runError
                ?? (chatVM.messages.last?.role == .error ? chatVM.messages.last?.text : nil)
        )
        let connection = appState.connection(for: connectionID)
        let config = SQLGenerationConfig(
            defaultRowLimit: connection?.defaultRowLimit ?? 100,
            databaseContext: connection?.databaseContext ?? ""
        )

        chatVM.input = ""
        chatVM.messages.append(ChatMessage(role: .user, text: question))
        chatVM.beginGeneration()
        appState.sessionDidChange(sessionID)
        defer {
            chatVM.finishGeneration()
            appState.sessionDidChange(sessionID)
        }

        do {
            let result = try await appState.sqlGenerator.generateSQL(
                question: question,
                schema: schema,
                context: context,
                config: config
            )
            if result.needsClarification,
                let clarification = result.clarificationQuestion,
                !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                chatVM.messages.append(
                    ChatMessage(role: .assistant, text: clarification, generation: result)
                )
                return
            }

            let generatedSQL = result.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !generatedSQL.isEmpty else {
                appendAssistantGeneration(result)
                return
            }

            let visibleGeneration = result.withSQL(generatedSQL)
            let validation = SQLSafetyValidator.validate(generatedSQL)
            guard validation.isValid else {
                let firstError = AppError.validationFailed(validation.errors).localizedDescription
                await repairGeneratedSQL(
                    appState: appState,
                    startingSQL: generatedSQL,
                    firstError: firstError,
                    startingGeneration: visibleGeneration,
                    questionContext: (
                        question: question,
                        recentQuestions: Array(context.recentQuestions.suffix(3))
                    ),
                    mode: .validationOnly
                )
                return
            }

            appendAssistantGeneration(visibleGeneration)
            queryVM.setGeneration(visibleGeneration)
        } catch {
            chatVM.appendRunError(error.localizedDescription)
        }
    }

    private func repairGeneratedSQL(
        appState: AppState,
        startingSQL: String,
        firstError: String,
        startingGeneration: SQLGenerationResult? = nil,
        questionContext suppliedQuestionContext: (question: String, recentQuestions: [String])? = nil,
        mode: GeneratedSQLRepairMode = .execution
    ) async {
        let questionContext = suppliedQuestionContext ?? questionContextForRepair(startingSQL: startingSQL)
        let startingGeneration = startingGeneration
            ?? generatedAssistant(matchingSQL: startingSQL)
            ?? queryVM.generation?.withSQL(startingSQL)
        let ownsGenerationState = !chatVM.isGenerating
        if ownsGenerationState {
            chatVM.beginGeneration(
                status: retryStatus(appState: appState, attempt: 1, error: firstError, mode: mode)
            )
        } else {
            chatVM.updateGenerationStatus(
                retryStatus(appState: appState, attempt: 1, error: firstError, mode: mode)
            )
        }
        appState.sessionDidChange(sessionID)
        defer {
            if ownsGenerationState {
                chatVM.finishGeneration()
            }
        }
        var finalGeneration = startingGeneration

        func restoreStartingGeneration() {
            guard let startingGeneration else { return }
            replaceOrAppendAssistantGeneration(startingGeneration, replacingSQL: startingSQL)
            queryVM.setGeneration(startingGeneration)
        }

        guard let schema = appState.promptSchema(for: connectionID), !schema.tables.isEmpty else {
            restoreStartingGeneration()
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
        var attempts = [
            GeneratedSQLRepairAttempt(label: "Initial run", error: firstError)
        ]

        for attempt in 1...Self.generatedSQLRepairRetryLimit {
            chatVM.updateGenerationStatus(
                retryStatus(appState: appState, attempt: attempt, error: lastError, mode: mode)
            )
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
                restoreStartingGeneration()
                chatVM.appendRunError(error.localizedDescription)
                appState.sessionDidChange(sessionID)
                return
            }

            let generatedSQL = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if !generatedSQL.isEmpty {
                finalGeneration = generation.withSQL(generatedSQL)
            }
            guard !generatedSQL.isEmpty, !generation.needsClarification else {
                lastError = "The model did not return corrected SQL."
                attempts.append(
                    GeneratedSQLRepairAttempt(
                        label: "Retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)",
                        error: lastError
                    )
                )
                continue
            }
            if Self.normalizedSQL(generatedSQL) == Self.normalizedSQL(failingSQL) {
                lastError = Self.repeatedSQLRepairMessage(previousError: lastError)
                attempts.append(
                    GeneratedSQLRepairAttempt(
                        label: "Retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)",
                        error: lastError
                    )
                )
                continue
            }

            if mode == .validationOnly {
                let validation = SQLSafetyValidator.validate(generatedSQL)
                if validation.isValid {
                    let visibleGeneration = generation.withSQL(generatedSQL)
                    replaceOrAppendAssistantGeneration(visibleGeneration, replacingSQL: startingSQL)
                    queryVM.setGeneration(visibleGeneration)
                    appState.sessionDidChange(sessionID)
                    return
                }
                let errorMessage = AppError.validationFailed(validation.errors).localizedDescription
                attempts.append(
                    GeneratedSQLRepairAttempt(
                        label: "Retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)",
                        error: errorMessage
                    )
                )
                failingSQL = generatedSQL
                lastError = errorMessage
                continue
            }

            let execution = await queryVM.executeGeneratedSQLAttempt(
                sql: generatedSQL,
                connection: connection,
                postgres: postgres,
                isConnected: appState.connectionState(connectionID) == .connected
            )
            if execution.wasDiscarded {
                appState.sessionDidChange(sessionID)
                return
            }
            if execution.wasUnsafeWrite {
                restoreStartingGeneration()
                chatVM.appendRunError(
                    execution.errorMessage
                        ?? "The model tried to repair this read with a data-modifying query."
                )
                appState.sessionDidChange(sessionID)
                return
            }
            if let result = execution.result {
                let visibleGeneration = generation.withSQL(generatedSQL)
                replaceOrAppendAssistantGeneration(visibleGeneration, replacingSQL: startingSQL)
                queryVM.setGeneration(visibleGeneration)
                appendRunResult(result, sql: generatedSQL)
                appState.sessionDidChange(sessionID)
                return
            }

            guard let errorMessage = execution.errorMessage else {
                lastError = "The query did not return a result."
                attempts.append(
                    GeneratedSQLRepairAttempt(
                        label: "Retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)",
                        error: lastError
                    )
                )
                continue
            }
            guard Self.isRetryableGeneratedSQLError(errorMessage) else {
                restoreStartingGeneration()
                chatVM.appendRunError(errorMessage)
                appState.sessionDidChange(sessionID)
                return
            }

            attempts.append(
                GeneratedSQLRepairAttempt(
                    label: "Retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)",
                    error: errorMessage
                )
            )
            failingSQL = generatedSQL
            lastError = errorMessage
        }

        if let finalGeneration {
            replaceOrAppendAssistantGeneration(finalGeneration, replacingSQL: startingSQL)
            queryVM.setGeneration(finalGeneration)
        }
        chatVM.appendRunError(repairFailureMessage(attempts: attempts, mode: mode))
        appState.sessionDidChange(sessionID)
    }

    private func appendAssistantGeneration(_ generation: SQLGenerationResult) {
        chatVM.messages.append(
            ChatMessage(role: .assistant, text: assistantText(for: generation), generation: generation)
        )
    }

    private func replaceOrAppendAssistantGeneration(
        _ generation: SQLGenerationResult,
        replacingSQL sql: String
    ) {
        guard let index = generatedAssistantIndex(matchingSQL: sql) else {
            appendAssistantGeneration(generation)
            return
        }
        chatVM.messages[index].text = assistantText(for: generation)
        chatVM.messages[index].generation = generation
    }

    private func assistantText(for generation: SQLGenerationResult) -> String {
        if generation.needsClarification,
            let clarification = generation.clarificationQuestion,
            !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return clarification
        }
        return generation.explanation
    }

    private func appendRunResult(_ result: QueryResult, sql: String) {
        let record = chatVM.appendRunRecord(
            ChatMessage.RunSummary(
                rowCount: result.rowCount,
                executionTimeMs: result.executionTimeMs,
                truncated: result.truncated,
                sql: sql,
                kind: result.kind
            ))
        // Writes without RETURNING rows have no table — the summary row records
        // them. Reads (even empty) and writes with RETURNING get a results card.
        if result.kind == .read || !result.rows.isEmpty {
            results[record.id] = result
        }
    }

    private func retryStatus(
        appState: AppState,
        attempt: Int,
        error: String,
        mode: GeneratedSQLRepairMode
    ) -> String {
        let prefix =
            mode == .validationOnly
            ? "The generated SQL failed validation."
            : "The query hit an error."
        return """
        \(prefix) Asking \(appState.activeBackendDisplayName) to fix it (retry \(attempt)/\(Self.generatedSQLRepairRetryLimit)).
        Last error: \(Self.truncated(error, to: 260))
        """
    }

    private func repairFailureMessage(
        attempts: [GeneratedSQLRepairAttempt],
        mode: GeneratedSQLRepairMode
    ) -> String {
        let lastError = attempts.last?.error ?? "Unknown database error."
        let history = attempts
            .map { attempt in
                "- \(attempt.label): \(Self.truncated(attempt.error, to: 220))"
            }
            .joined(separator: "\n")
        let failureReason =
            mode == .validationOnly
            ? "it still failed validation"
            : "the database still rejected it"
        return """
            I tried to repair the generated SQL \(Self.generatedSQLRepairRetryLimit) times, but \(failureReason).

            Last error: \(lastError)

            Errors seen:
            \(history)

            The final SQL is shown above. Add more context in chat so the model can adjust it, or switch to a smarter cloud model and try again.
            """
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

    private func generatedAssistantIndex(matchingSQL sql: String) -> Int? {
        let normalized = Self.normalizedSQL(sql)
        return chatVM.messages.lastIndex(where: { message in
            message.role == .assistant
                && Self.normalizedSQL(message.generation?.sql ?? "") == normalized
        })
    }

    private func generatedAssistant(matchingSQL sql: String) -> SQLGenerationResult? {
        let normalized = Self.normalizedSQL(sql)
        return chatVM.messages.last(where: { message in
            message.role == .assistant
                && Self.normalizedSQL(message.generation?.sql ?? "") == normalized
        })?.generation
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    private static func repeatedSQLRepairMessage(previousError: String) -> String {
        """
        The model repeated the exact same SQL after it failed. Produce a structurally different query.
        Previous error: \(previousError)
        """
    }

    private static func isRetryableGeneratedSQLError(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != AppError.notConnected.localizedDescription else { return false }
        guard !trimmed.contains("Stopped waiting for the query") else { return false }
        return true
    }
}

private struct GeneratedSQLRepairAttempt {
    var label: String
    var error: String
}

private enum GeneratedSQLRepairMode {
    case validationOnly
    case execution
}

private extension SQLGenerationResult {
    func withSQL(_ sql: String) -> SQLGenerationResult {
        var copy = self
        copy.sql = sql
        return copy
    }
}
