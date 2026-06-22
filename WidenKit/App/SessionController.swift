import Foundation
import Observation

/// Per-session runtime container: the live view models for one query
/// session, plus the copy-in/copy-out glue to the persisted `QuerySession`
/// value. Cached by `AppState` so switching sessions never loses in-flight
/// generations or query runs.
@MainActor
@Observable
public final class SessionController: Identifiable {
    private static let generatedSQLRepairRetryLimit = GeneratedSQLRepairCoordinator.maxModelCalls
    private static let generatedSQLLocalModelCallBudget = 3

    public let sessionID: UUID
    public let connectionID: UUID
    public let chatVM = ChatViewModel()
    public let queryVM: QueryResultViewModel
    /// Materialized results keyed by their run-record message, so every run
    /// of this live session keeps its full table in the transcript. Never
    /// persisted — after a relaunch the records render as summary rows.
    public private(set) var results: [UUID: QueryResult] = [:]
    private var selectedClarificationOption: (pendingID: UUID, option: ClarificationOption)?

    /// True while the session is mid-generation or mid-run. Surfaced in the
    /// sidebar so work in progress stays visible even when another session is
    /// on screen (controllers persist once created, so the flag survives a
    /// session switch).
    public var isWorking: Bool {
        chatVM.isGenerating || queryVM.isRunning
    }

    public convenience init(session: QuerySession, schema: DatabaseSchema? = nil) {
        self.init(session: session, schema: schema, executor: QueryExecutionService())
    }

    init(session: QuerySession, schema: DatabaseSchema? = nil, executor: any QueryExecuting) {
        self.sessionID = session.id
        self.connectionID = session.connectionID
        self.queryVM = QueryResultViewModel(executor: executor)
        hydrate(from: session, schema: schema)
    }

    /// Loads persisted state into the live view models.
    public func hydrate(from session: QuerySession, schema: DatabaseSchema? = nil) {
        chatVM.messages = session.messages
        queryVM.restore(sqlText: session.sqlText, generation: session.lastGeneration, schema: schema)
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
        let schema = appState.schemaForGeneration(generation, connectionID: connectionID)
        queryVM.startRun(
            connection: appState.connection(for: connectionID),
            postgres: appState.postgres(for: connectionID),
            isConnected: appState.connectionState(connectionID) == .connected,
            confirmed: confirmed,
            schema: schema
        ) { [weak self, weak appState] result, errorMessage in
            guard let self else { return }
            // `startRun` validated `sql` as part of the run; reuse that result
            // instead of re-tokenizing, and route the error by statement kind.
            let isWrite = self.queryVM.validation?.kind.isWrite == true
            let queryFailure =
                self.queryVM.runFailure ?? errorMessage.map { QueryFailure(message: $0) }
            if let result {
                self.appendRunResult(result, sql: sql)
            } else if let errorMessage {
                if isWrite {
                    // Writes never auto-retry: show the error immediately. When
                    // the query was AI-generated, offer a one-shot "Try Again".
                    if generation != nil,
                        Self.isRetryableGeneratedSQLFailure(queryFailure)
                    {
                        self.chatVM.appendWriteRunError(errorMessage, failedSQL: sql)
                    } else {
                        self.chatVM.appendRunError(errorMessage)
                    }
                } else if generation != nil,
                    Self.isRetryableGeneratedSQLFailure(queryFailure)
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
                            firstError: errorMessage,
                            firstFailure: queryFailure
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
        let startingGeneration =
            generatedAssistant(matchingSQL: failedSQL)
            ?? queryVM.generation?.withSQL(failedSQL)
        let repairSchema =
            appState.schemaForGeneration(startingGeneration, connectionID: connectionID)
            ?? appState.promptSchema(for: connectionID)
        guard let schema = repairSchema, !schema.tables.isEmpty else {
            chatVM.appendRunError(
                "I could not retry because the database schema is no longer available."
            )
            appState.sessionDidChange(sessionID)
            return
        }

        let questionContext = questionContextForRepair(startingSQL: failedSQL)
        let forbiddenIdentifiers = Self.forbiddenIdentifiers(
            sql: failedSQL,
            error: error,
            schema: schema
        )
        let context = SQLGenerationContext(
            mode: .repair,
            recentQuestions: questionContext.recentQuestions,
            originalQuestion: questionContext.originalQuestion,
            conversationMessages: questionContext.conversationMessages,
            currentSQL: failedSQL,
            lastRunError: error,
            repairContext: SQLRepairContext(
                failedSQL: failedSQL,
                diagnostic: Self.diagnostic(from: error),
                forbiddenIdentifiers: forbiddenIdentifiers,
                repairConstraints: Self.repairConstraints(
                    forbiddenIdentifiers: forbiddenIdentifiers,
                    error: error
                ),
                priorFingerprints: [Self.normalizedSQL(failedSQL)]
            ),
            modelCallCount: Self.cumulativeGeneratedSQLModelCallCount(
                after: startingGeneration,
                attempt: 1
            ),
            confirmedSemanticBindings: appState.semanticBindingPromptLines(
                for: connectionID,
                schema: schema
            )
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
            let generated = try await appState.sqlGenerator.generateSQL(
                question: questionContext.question,
                schema: schema,
                context: context,
                config: config
            )
            generation = GeneratedSQLPostprocessor.enriched(
                generated,
                question: questionContext.question,
                schema: schema,
                databaseContext: config.databaseContext,
                confirmedSemanticBindings: context.confirmedSemanticBindings,
                allowGroundingClarification: false
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
                ChatMessage(
                    role: .assistant,
                    text: clarification,
                    generation: generation,
                    pendingClarification: generation.pendingClarification
                )
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
        queryVM.setGeneration(visibleGeneration, schema: schema)
    }

    /// Wipes the transcript, the SQL preview, and the per-run result cache.
    public func clearConversation() {
        guard queryVM.clear() else { return }
        chatVM.clearConversation()
        results.removeAll()
    }

    public func selectClarificationOption(
        appState: AppState,
        pending: PendingClarification,
        option: ClarificationOption
    ) async {
        guard !queryVM.isRunning, !chatVM.isGenerating else { return }
        guard unresolvedPendingClarification()?.id == pending.id else { return }
        selectedClarificationOption = (pending.id, option)
        chatVM.input = option.replyText
        await submit(appState: appState)
    }

    public func rememberResolvedClarification(appState: AppState) {
        guard let generation = queryVM.generation,
            queryVM.validation?.isValid == true,
            let pending = generation.resolvedClarification,
            let selectedOption = generation.resolvedClarificationOption,
            let schema = appState.schemaForGeneration(generation, connectionID: connectionID)
                ?? appState.promptSchema(for: connectionID)
        else {
            return
        }
        appState.confirmSemanticBinding(
            connectionID: connectionID,
            pending: pending,
            replyText: generation.resolvedClarificationReply ?? selectedOption.replyText,
            selectedOption: selectedOption,
            schema: schema
        )
        appState.sessionDidChange(sessionID)
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

        let unresolvedClarification = unresolvedPendingClarification()
        let selectedOption = selectedOptionForPendingClarification(
            unresolvedClarification,
            replyText: question
        )
        let clarificationResolution = unresolvedClarification.map {
            ClarificationResolver.resolve(
                reply: question,
                pending: $0,
                selectedOption: selectedOption
            )
        }
        if clarificationResolution?.action == .cancel {
            chatVM.input = ""
            chatVM.messages.append(ChatMessage(role: .user, text: question))
            chatVM.messages.append(
                ChatMessage(role: .assistant, text: "Okay, I abandoned that clarification.")
            )
            return
        }
        let resolvesPendingClarification =
            clarificationResolution?.action == .answer
            || clarificationResolution?.action == .stillAmbiguous
        let pendingClarification = resolvesPendingClarification ? unresolvedClarification : nil
        let abandonsPendingClarification =
            unresolvedClarification != nil && pendingClarification == nil
        let generationQuestion = pendingClarification?.originalQuestion ?? question
        var confirmedBindings = appState.semanticBindingPromptLines(
            for: connectionID,
            schema: schema
        )
        if let pendingClarification,
            clarificationResolution?.action == .answer
        {
            let resolvedDefinition = clarificationResolution?.normalizedDefinition
            let definition = ((resolvedDefinition?.isEmpty == false ? resolvedDefinition : nil)
                ?? selectedOption?.definition
                ?? question)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !definition.isEmpty {
                confirmedBindings.append("\(pendingClarification.concept.term): \(definition)")
            }
        }
        let transcriptUpperBound = Self.transcriptUpperBound(
            excludingAbandonedClarification: unresolvedClarification,
            in: chatVM.messages,
            abandonsPendingClarification: abandonsPendingClarification
        )
        var conversationMessages = chatVM.messages.sqlConversationMessages(upTo: transcriptUpperBound)
        let recentQuestions = chatVM.messages
            .prefix(upTo: min(transcriptUpperBound, chatVM.messages.count))
            .filter { $0.role == .user }
            .suffix(3)
            .map(\.text)
        if pendingClarification != nil {
            conversationMessages.append(SQLConversationMessage(role: .user, text: question))
        }
        let context = SQLGenerationContext(
            recentQuestions: recentQuestions,
            originalQuestion: pendingClarification?.originalQuestion
                ?? (abandonsPendingClarification
                    ? question : chatVM.messages.originalUserQuestion()),
            conversationMessages: conversationMessages,
            currentSQL: queryVM.sqlText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : queryVM.sqlText,
            lastRunError: queryVM.runError
                ?? (chatVM.messages.last?.role == .error ? chatVM.messages.last?.text : nil),
            confirmedSemanticBindings: confirmedBindings
        )
        let connection = appState.connection(for: connectionID)
        let config = SQLGenerationConfig(
            defaultRowLimit: connection?.defaultRowLimit ?? 100,
            databaseContext: connection?.databaseContext ?? ""
        )

        if pendingClarification == nil,
            let compiled = AnalyticQueryCompiler.compile(
                question: question,
                schema: schema,
                defaultRowLimit: config.defaultRowLimit,
                databaseContext: config.databaseContext
            )
        {
            let result = GeneratedSQLPostprocessor.enriched(
                compiled,
                question: question,
                schema: schema,
                databaseContext: config.databaseContext,
                confirmedSemanticBindings: context.confirmedSemanticBindings
            )
            chatVM.input = ""
            chatVM.messages.append(ChatMessage(role: .user, text: question))
            if result.needsClarification,
                let clarification = result.clarificationQuestion,
                !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                chatVM.messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: clarification,
                        generation: result,
                        pendingClarification: result.pendingClarification
                    )
                )
            } else {
                appendAssistantGeneration(result)
                queryVM.setGeneration(result, schema: schema)
            }
            return
        }

        chatVM.input = ""
        chatVM.messages.append(ChatMessage(role: .user, text: question))
        chatVM.beginGeneration()
        appState.sessionDidChange(sessionID)
        defer {
            selectedClarificationOption = nil
            chatVM.finishGeneration()
            appState.sessionDidChange(sessionID)
        }

        do {
            let generated = try await appState.sqlGenerator.generateSQL(
                question: generationQuestion,
                schema: schema,
                context: context,
                config: config
            )
            var result = GeneratedSQLPostprocessor.enriched(
                generated,
                question: generationQuestion,
                schema: schema,
                databaseContext: config.databaseContext,
                confirmedSemanticBindings: context.confirmedSemanticBindings
            )
            .applyingClarificationProgress(from: pendingClarification)
            if !result.needsClarification {
                result = result.withResolvedClarification(
                    pendingClarification,
                    replyText: question,
                    selectedOption: selectedOption
                )
            }
            if result.needsClarification,
                let clarification = result.clarificationQuestion,
                !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                chatVM.messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: clarification,
                        generation: result,
                        pendingClarification: result.pendingClarification
                    )
                )
                return
            }

            let generatedSQL = result.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !generatedSQL.isEmpty else {
                appendAssistantGeneration(result)
                return
            }

            let visibleGeneration = result.withSQL(generatedSQL)
            let validation = GeneratedSQLValidator.validate(sql: generatedSQL, schema: schema)
            guard validation.isValid else {
                if let repairedSQL = GeneratedSQLValidator.repairQuotedIdentifiers(
                    sql: generatedSQL,
                    schema: schema
                ) {
                    let repairedGeneration = result.withSQL(repairedSQL)
                    appendAssistantGeneration(repairedGeneration)
                    queryVM.setGeneration(repairedGeneration, schema: schema)
                    return
                }
                let firstError = AppError.validationFailed(validation.errors).localizedDescription
                await repairGeneratedSQL(
                    appState: appState,
                    startingSQL: generatedSQL,
                    firstError: firstError,
                    startingGeneration: visibleGeneration,
                    questionContext: RepairQuestionContext(
                        question: generationQuestion,
                        recentQuestions: Array(context.recentQuestions.suffix(3)),
                        originalQuestion: context.originalQuestion ?? generationQuestion,
                        conversationMessages: context.conversationMessages
                            + [SQLConversationMessage(role: .user, text: question)]
                    ),
                    mode: .validationOnly
                )
                return
            }

            appendAssistantGeneration(visibleGeneration)
            queryVM.setGeneration(visibleGeneration, schema: schema)
        } catch {
            chatVM.appendRunError(error.localizedDescription)
        }
    }

    private func unresolvedPendingClarification() -> PendingClarification? {
        guard let last = chatVM.messages.last,
            last.role == .assistant,
            let pending = last.pendingClarification
        else {
            return nil
        }
        return pending
    }

    private func selectedOptionForPendingClarification(
        _ pending: PendingClarification?,
        replyText: String
    ) -> ClarificationOption? {
        guard let pending else { return nil }
        if let selected = selectedClarificationOption,
            selected.pendingID == pending.id
        {
            return selected.option
        }
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = pending.options.first(where: {
            $0.replyText.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.label.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        if Self.isAffirmativeClarificationReply(trimmed),
            pending.options.count == 1
        {
            return pending.options[0]
        }
        return nil
    }

    private func shouldUseClarificationReplyAsContext(
        _ replyText: String,
        selectedOption: ClarificationOption?,
        pending: PendingClarification?
    ) -> Bool {
        guard pending != nil else { return false }
        guard !Self.isNegativeClarificationReply(replyText) else { return false }
        return selectedOption != nil
            || Self.isExplicitSemanticDefinitionReply(replyText, conceptTerm: pending?.concept.term)
            || Self.isLikelyClarificationAnswer(replyText)
    }

    private func shouldResolvePendingClarification(
        _ replyText: String,
        selectedOption: ClarificationOption?,
        pending: PendingClarification?
    ) -> Bool {
        selectedOption != nil
            || Self.isExplicitSemanticDefinitionReply(
                replyText,
                conceptTerm: pending?.concept.term
            )
            || Self.isNegativeClarificationReply(replyText)
            || (pending != nil && Self.isLikelyClarificationAnswer(replyText))
    }

    private static func isLikelyClarificationAnswer(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count >= 3 else { return false }
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        guard !negativeClarificationReplies.contains(stripped) else { return false }
        guard !isQuestionLikeClarificationReply(normalized) else { return false }
        let tokens = semanticReplyTokenList(in: normalized)
        guard !tokens.isEmpty else { return false }
        if let first = tokens.first, first == "select" || first == "with" {
            return false
        }
        return true
    }

    private static func isAffirmativeClarificationReply(_ text: String) -> Bool {
        let stripped = text
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?, \n\t"))
            .lowercased()
        return [
            "y", "yes", "yeah", "yep", "correct", "right", "that's right",
            "that is right", "sounds good", "ok", "okay", "sure", "use that",
            "do that", "exactly",
        ].contains(stripped)
    }

    private static func isExplicitSemanticDefinitionReply(
        _ text: String,
        conceptTerm: String?
    ) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count >= 6 else { return false }
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        guard !negativeClarificationReplies.contains(stripped) else { return false }
        guard !isQuestionLikeClarificationReply(normalized) else { return false }
        if normalized.hasPrefix("use ") || normalized.contains("=") {
            return true
        }
        let definitionMarkers = [
            " means ", " mean ", " is ", " are ", " equals ", " equal ",
            " defined as ", " refers to ", " should be ",
        ]
        guard definitionMarkers.contains(where: normalized.contains) else { return false }
        let conceptTokens = semanticReplyTokens(in: conceptTerm ?? "")
        guard !conceptTokens.isEmpty else { return true }
        let replyTokens = semanticReplyTokens(in: normalized)
        return !replyTokens.isDisjoint(with: conceptTokens)
    }

    private static func isQuestionLikeClarificationReply(_ normalized: String) -> Bool {
        let tokens = semanticReplyTokenList(in: normalized)
        guard let first = tokens.first else { return false }
        let questionStarters: Set<String> = [
            "find", "give", "how", "list", "return", "select", "show",
            "what", "when", "where", "which", "who", "why",
        ]
        return normalized.contains("?") || questionStarters.contains(first)
    }

    private static func semanticReplyTokens(in text: String) -> Set<String> {
        Set(semanticReplyTokenList(in: text))
    }

    private static func semanticReplyTokenList(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static let negativeClarificationReplies: Set<String> = [
        "n", "no", "nope", "nah", "not sure", "i don't know", "i dont know",
        "unknown", "something else",
    ]

    private static func isNegativeClarificationReply(_ text: String) -> Bool {
        let stripped = text
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?, \n\t"))
            .lowercased()
        return negativeClarificationReplies.contains(stripped)
    }

    private static func transcriptUpperBound(
        excludingAbandonedClarification pending: PendingClarification?,
        in messages: [ChatMessage],
        abandonsPendingClarification: Bool
    ) -> Int {
        guard abandonsPendingClarification, let pending else {
            return messages.count
        }
        guard let clarificationIndex = messages.lastIndex(where: {
            $0.pendingClarification?.id == pending.id
        }) else {
            return max(0, messages.count - 1)
        }
        let previousIndex = clarificationIndex - 1
        if previousIndex >= 0, messages[previousIndex].role == .user {
            return previousIndex
        }
        return clarificationIndex
    }

    private func repairGeneratedSQL(
        appState: AppState,
        startingSQL: String,
        firstError: String,
        firstFailure: QueryFailure? = nil,
        startingGeneration: SQLGenerationResult? = nil,
        questionContext suppliedQuestionContext: RepairQuestionContext? = nil,
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

        func restoreStartingGeneration(schema: DatabaseSchema? = nil) {
            guard mode != .validationOnly else { return }
            guard let startingGeneration else { return }
            replaceOrAppendAssistantGeneration(startingGeneration, replacingSQL: startingSQL)
            queryVM.setGeneration(startingGeneration, schema: schema)
        }

        let repairSchema =
            appState.schemaForGeneration(startingGeneration, connectionID: connectionID)
            ?? appState.promptSchema(for: connectionID)
        guard let schema = repairSchema, !schema.tables.isEmpty else {
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
        let firstDiagnostic = firstFailure?.diagnostic ?? Self.diagnostic(from: firstError)
        let allowRepairWrites =
            mode == .validationOnly && SQLSafetyValidator.validate(startingSQL).kind.isWrite
        let forbiddenIdentifiers = Self.forbiddenIdentifiers(
            sql: startingSQL,
            error: firstError,
            diagnostic: firstDiagnostic,
            schema: schema
        )
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: startingSQL,
            firstError: firstError,
            diagnostic: firstDiagnostic,
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: Self.repairConstraints(
                forbiddenIdentifiers: forbiddenIdentifiers,
                error: firstError,
            ),
            maxModelCalls: Self.remainingGeneratedSQLRepairCalls(after: startingGeneration)
        )

        while let repairMode = coordinator.beginNextAttempt() {
            let attemptNumber = repairMode == .repair ? 1 : 2
            chatVM.updateGenerationStatus(
                retryStatus(
                    appState: appState,
                    attempt: attemptNumber,
                    error: coordinator.constraints.lastError,
                    mode: mode
                )
            )
            let repairContext = coordinator.repairContext(for: repairMode)
            let context = SQLGenerationContext(
                mode: repairMode,
                recentQuestions: repairMode == .repair ? questionContext.recentQuestions : [],
                originalQuestion: questionContext.originalQuestion,
                conversationMessages: repairMode == .repair
                    ? questionContext.conversationMessages : [],
                currentSQL: repairMode == .repair ? repairContext.failedSQL : nil,
                lastRunError: repairMode == .repair ? coordinator.constraints.lastError : nil,
                repairContext: repairContext,
                modelCallCount: Self.cumulativeGeneratedSQLModelCallCount(
                    after: startingGeneration,
                    attempt: attemptNumber
                ),
                confirmedSemanticBindings: appState.semanticBindingPromptLines(
                    for: connectionID,
                    schema: schema
                )
            )

            let generation: SQLGenerationResult
            do {
                let generated = try await appState.sqlGenerator.generateSQL(
                    question: questionContext.question,
                    schema: schema,
                    context: context,
                    config: config
                )
                var enriched = GeneratedSQLPostprocessor.enriched(
                    generated,
                    question: questionContext.question,
                    schema: schema,
                    databaseContext: config.databaseContext,
                    confirmedSemanticBindings: context.confirmedSemanticBindings,
                    allowGroundingClarification: true
                )
                if !enriched.needsClarification,
                    let pending = Self.repairIntentClarification(
                        question: questionContext.originalQuestion ?? questionContext.question,
                        diagnostic: firstDiagnostic,
                        candidateSQL: enriched.sql
                    )
                {
                    enriched = enriched.withPendingClarification(pending)
                }
                generation = enriched
            } catch {
                restoreStartingGeneration(schema: schema)
                chatVM.appendRunError(error.localizedDescription)
                appState.sessionDidChange(sessionID)
                return
            }

            let evaluation = coordinator.evaluateCandidate(
                generation,
                mode: repairMode,
                schema: schema,
                allowWrites: allowRepairWrites
            )

            switch evaluation.outcome {
            case .clarification:
                guard let clarification = evaluation.message,
                    !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    restoreStartingGeneration(schema: schema)
                    chatVM.appendRunError(
                        repairFailureMessage(attempts: coordinator.attempts, mode: mode)
                    )
                    appState.sessionDidChange(sessionID)
                    return
                }
                chatVM.messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: clarification,
                        generation: generation,
                        pendingClarification: generation.pendingClarification
                    )
                )
                appState.sessionDidChange(sessionID)
                return

            case .rejected(let reason):
                if reason.isZeroProgressRepair {
                    let diagnosticText = firstDiagnostic?.displayMessage ?? firstError
                    if !Self.missingColumnsCanBeResolvedByJoining(
                        sql: startingSQL,
                        error: diagnosticText,
                        schema: schema
                    ),
                        let clarification = SQLPromptBuilder.missingColumnClarificationQuestion(
                            for: diagnosticText,
                            question: questionContext.originalQuestion ?? questionContext.question,
                            schema: schema)
                    {
                        chatVM.messages.append(ChatMessage(role: .assistant, text: clarification))
                        appState.sessionDidChange(sessionID)
                        return
                    }
                    if let clarification = SQLPromptBuilder.missingRelationClarificationQuestion(
                        for: diagnosticText
                    ) {
                        chatVM.messages.append(ChatMessage(role: .assistant, text: clarification))
                        appState.sessionDidChange(sessionID)
                        return
                    }
                }
                if evaluation.allowsReconstruction, coordinator.canRequestAnotherModelCall {
                    continue
                }
                restoreStartingGeneration(schema: schema)
                chatVM.appendRunError(
                    repairFailureMessage(attempts: coordinator.attempts, mode: mode)
                )
                appState.sessionDidChange(sessionID)
                return

            case .accepted:
                break
            }

            guard let generatedSQL = evaluation.sql else {
                restoreStartingGeneration(schema: schema)
                chatVM.appendRunError(
                    repairFailureMessage(attempts: coordinator.attempts, mode: mode)
                )
                appState.sessionDidChange(sessionID)
                return
            }

            if mode == .validationOnly {
                let visibleGeneration = generation.withSQL(generatedSQL)
                replaceOrAppendAssistantGeneration(visibleGeneration, replacingSQL: startingSQL)
                queryVM.setGeneration(visibleGeneration, schema: schema)
                appState.sessionDidChange(sessionID)
                return
            }

            let execution = await queryVM.executeGeneratedSQLAttempt(
                sql: generatedSQL,
                connection: connection,
                postgres: postgres,
                isConnected: appState.connectionState(connectionID) == .connected,
                schema: schema
            )
            if execution.wasDiscarded {
                appState.sessionDidChange(sessionID)
                return
            }
            if execution.wasUnsafeWrite {
                restoreStartingGeneration(schema: schema)
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
                queryVM.setGeneration(visibleGeneration, schema: schema)
                appendRunResult(result, sql: generatedSQL)
                appState.sessionDidChange(sessionID)
                return
            }

            guard let errorMessage = execution.errorMessage else {
                coordinator.recordExecutionFailure(
                    mode: repairMode,
                    sql: generatedSQL,
                    error: "The query did not return a result.",
                    diagnostic: nil,
                    forbiddenIdentifiers: []
                )
                continue
            }
            let executionFailure =
                execution.failure ?? QueryFailure(
                    message: errorMessage,
                    diagnostic: Self.diagnostic(from: errorMessage)
                )
            guard Self.isRetryableGeneratedSQLFailure(executionFailure) else {
                restoreStartingGeneration(schema: schema)
                chatVM.appendRunError(errorMessage)
                appState.sessionDidChange(sessionID)
                return
            }
            let forbiddenIdentifiers = Self.forbiddenIdentifiers(
                sql: generatedSQL,
                error: errorMessage,
                diagnostic: executionFailure.diagnostic,
                schema: schema
            )
            coordinator.recordExecutionFailure(
                mode: repairMode,
                sql: generatedSQL,
                error: errorMessage,
                diagnostic: executionFailure.diagnostic ?? Self.diagnostic(from: errorMessage),
                forbiddenIdentifiers: forbiddenIdentifiers,
                repairConstraints: Self.repairConstraints(
                    forbiddenIdentifiers: forbiddenIdentifiers,
                    error: errorMessage
                )
            )
            if coordinator.canRequestAnotherModelCall {
                continue
            }
        }

        restoreStartingGeneration(schema: schema)
        chatVM.appendRunError(repairFailureMessage(attempts: coordinator.attempts, mode: mode))
        appState.sessionDidChange(sessionID)
    }

    private static func remainingGeneratedSQLRepairCalls(
        after generation: SQLGenerationResult?
    ) -> Int {
        let spentModelCalls = max(1, generation?.generationCallCount ?? 1)
        return max(0, generatedSQLLocalModelCallBudget - spentModelCalls)
    }

    private static func cumulativeGeneratedSQLModelCallCount(
        after generation: SQLGenerationResult?,
        attempt: Int
    ) -> Int {
        let spentModelCalls = max(1, generation?.generationCallCount ?? 1)
        return spentModelCalls + max(0, attempt)
    }

    private func appendAssistantGeneration(_ generation: SQLGenerationResult) {
        chatVM.messages.append(
            ChatMessage(
                role: .assistant,
                text: assistantText(for: generation),
                generation: generation,
                pendingClarification: generation.pendingClarification
            )
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
        \(prefix) Asking \(appState.activeBackendDisplayName) to fix it (attempt \(attempt)/\(Self.generatedSQLRepairRetryLimit)).
        Last error: \(Self.truncated(error, to: 260))
        """
    }

    private func repairFailureMessage(
        attempts: [SQLRepairAttempt],
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
        let recoveryGuidance =
            mode == .validationOnly
            ? "The rejected SQL was not shown in the editor. Add more context in chat so the model can adjust it, or switch to a smarter cloud model and try again."
            : "The SQL shown above was restored to the last valid or original generation. Add more context in chat so the model can adjust it, or switch to a smarter cloud model and try again."
        if attempts.count <= 1 {
            return """
                The generated SQL already used this request's model-call budget, so I did not ask the model to repair it.

                Last error: \(lastError)

                Errors seen:
                \(history)

                \(recoveryGuidance)
                """
        }
        return """
            I tried a focused repair and, when needed, one reconstruction, but \(failureReason).

            Last error: \(lastError)

            Errors seen:
            \(history)

            \(recoveryGuidance)
            """
    }

    private static func repairIntentClarification(
        question: String,
        diagnostic: DatabaseDiagnostic?,
        candidateSQL: String
    ) -> PendingClarification? {
        guard let diagnostic else { return nil }
        let identifier: String?
        let kind: SQLGroundingConcept.Kind
        switch diagnostic.kind {
        case .missingColumn, .ambiguousColumn:
            identifier = diagnostic.columnName
            kind = .entity
        case .missingRelation:
            identifier = diagnostic.tableName ?? missingRelationIdentifier(in: diagnostic.displayMessage)
            kind = .relationship
        default:
            return nil
        }
        guard let identifier,
            let term = droppedRepairIntentTerm(
                identifier: identifier,
                question: question,
                candidateSQL: candidateSQL
            )
        else {
            return nil
        }
        let concept = SQLGroundingConcept(
            term: term,
            kind: kind,
            state: .unsupported,
            required: true,
            evidence: [identifier]
        )
        let questionText =
            kind == .relationship
            ? "Which schema relationship should Widen use for \"\(term)\"?"
            : "Which schema table or column should \"\(term)\" refer to?"
        return PendingClarification(
            concept: concept,
            originalQuestion: question,
            question: questionText,
            evidence: [identifier]
        )
    }

    private static func droppedRepairIntentTerm(
        identifier: String,
        question: String,
        candidateSQL: String
    ) -> String? {
        let identifierTokens = semanticReplyTokenList(in: identifier)
            .filter { !repairIntentTokenStopWords.contains($0) }
        guard !identifierTokens.isEmpty else { return nil }
        let questionTokens = semanticReplyTokenList(in: question)
            .filter { !repairIntentTokenStopWords.contains($0) }
        let candidateTokens = Set(semanticReplyTokenList(in: candidateSQL))
        for token in identifierTokens {
            guard questionTokens.contains(where: { questionToken in
                questionToken == token
                    || (token.count >= 4 && questionToken.hasPrefix(token))
                    || (questionToken.count >= 4 && token.hasPrefix(questionToken))
            }) else {
                continue
            }
            guard !candidateTokens.contains(token) else { continue }
            return token
        }
        return nil
    }

    private static let repairIntentTokenStopWords: Set<String> = [
        "a", "an", "and", "at", "bad", "by", "id", "public", "schema", "the",
        "to", "user", "users", "with",
    ]

    private func questionContextForRepair(
        startingSQL: String
    ) -> RepairQuestionContext {
        let anchorIndex = chatVM.messages.lastIndex { message in
            message.role == .assistant
                && Self.normalizedSQL(message.generation?.sql ?? "") == Self.normalizedSQL(startingSQL)
        }
        let upperBound = anchorIndex ?? chatVM.messages.endIndex
        let transcriptUpperBound = anchorIndex.map { $0 + 1 } ?? chatVM.messages.endIndex
        let userQuestions = chatVM.messages[..<upperBound]
            .filter { $0.role == .user }
            .map(\.text)
        let question = userQuestions.last ?? "Fix the generated SQL so it runs successfully."
        return RepairQuestionContext(
            question: question,
            recentQuestions: Array(userQuestions.dropLast().suffix(3)),
            originalQuestion: chatVM.messages.originalUserQuestion(upTo: transcriptUpperBound),
            conversationMessages: chatVM.messages.sqlConversationMessages(
                upTo: transcriptUpperBound)
        )
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

    private static func diagnostic(from error: String) -> DatabaseDiagnostic? {
        let lowercased = error.lowercased()
        if let tableName = firstCapturedValue(
            in: error,
            pattern: #"Schema validation failed: table ([^\s]+) is not in the selected schema"#
        ) {
            return DatabaseDiagnostic(
                kind: .missingRelation,
                sqlState: "42P01",
                message: error,
                tableName: tableName
            )
        }
        if let columnName = firstCapturedValue(
            in: error,
            pattern:
                #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced(?: base)? tables|not on [^.\s]+(?:\.[^.\s]+)?|not an output column of [^.;]+)"#
        ) {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: columnName
            )
        }
        if let columnName = firstCapturedValue(
            in: error,
            pattern:
                #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) must be quoted as "[^"]+""#
        ) {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: columnName
            )
        }
        if lowercased.contains("relation"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(
                kind: .missingRelation,
                sqlState: "42P01",
                message: error,
                tableName: missingRelationIdentifier(in: error)
                    ?? quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("column"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("ambiguous") && lowercased.contains("column") {
            return DatabaseDiagnostic(
                kind: .ambiguousColumn,
                sqlState: "42702",
                message: error,
                columnName: quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("syntax error") {
            return DatabaseDiagnostic(kind: .syntaxError, sqlState: "42601", message: error)
        }
        if lowercased.contains("aggregate") || lowercased.contains("group by") {
            return DatabaseDiagnostic(kind: .groupingError, sqlState: "42803", message: error)
        }
        if lowercased.contains("type") && lowercased.contains("mismatch") {
            return DatabaseDiagnostic(kind: .datatypeMismatch, sqlState: "42804", message: error)
        }
        if lowercased.contains("function"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(kind: .undefinedFunction, sqlState: "42883", message: error)
        }
        if lowercased.contains("permission denied") || lowercased.contains("insufficient privilege") {
            return DatabaseDiagnostic(
                kind: .insufficientPrivilege,
                sqlState: "42501",
                message: error
            )
        }
        if lowercased.contains("timed out") || lowercased.contains("statement timeout") {
            return DatabaseDiagnostic(kind: .timedOut, sqlState: "57014", message: error)
        }
        return nil
    }

    private static func forbiddenIdentifiers(
        sql: String,
        error: String,
        diagnostic suppliedDiagnostic: DatabaseDiagnostic? = nil,
        schema: DatabaseSchema? = nil
    ) -> [String] {
        let unquotedOnly = Set(
            unquotedIdentifierRepairConstraints(in: error)
                .map { canonicalIdentifier($0.identifier) }
        )
        var identifiers = schemaValidationIdentifiers(in: error)
        let parsedDiagnostic = diagnostic(from: error)
        if let diagnostic = suppliedDiagnostic ?? parsedDiagnostic {
            if let identifier = repairIdentifier(
                for: diagnostic,
                parsedFromError: parsedDiagnostic,
                fallbackError: error
            ) {
                if !unquotedOnly.contains(canonicalIdentifier(identifier)) {
                    identifiers.append(identifier)
                }
            }
        }
        var seen = Set<String>()
        return identifiers
            .filter { shouldForbidIdentifier($0, sql: sql, schema: schema) }
            .filter { seen.insert($0).inserted }
    }

    private static func repairIdentifier(
        for diagnostic: DatabaseDiagnostic,
        parsedFromError: DatabaseDiagnostic?,
        fallbackError: String
    ) -> String? {
        if let identifier = diagnostic.identifierForRepair {
            return identifier
        }
        guard diagnostic.kind == .missingRelation else { return nil }
        return parsedFromError?.identifierForRepair
            ?? missingRelationIdentifier(in: diagnostic.displayMessage)
            ?? missingRelationIdentifier(in: fallbackError)
    }

    private static func repairConstraints(
        forbiddenIdentifiers: [String],
        error: String
    ) -> [RepairConstraint] {
        var constraints = forbiddenIdentifiers.map(RepairConstraint.forbiddenIdentifier)
        constraints.append(contentsOf: unquotedIdentifierRepairConstraints(in: error))
        var seen = Set<String>()
        return constraints.filter {
            seen.insert("\($0.kind.rawValue):\(canonicalIdentifier($0.identifier))").inserted
        }
    }

    private static func unquotedIdentifierRepairConstraints(in text: String) -> [RepairConstraint] {
        capturedValues(
            in: text,
            pattern:
                #"Schema validation failed: column [A-Za-z_][A-Za-z0-9_$]* must be quoted as "([^"]+)""#
        )
        .map(RepairConstraint.forbiddenUnquotedIdentifier)
    }

    private static func schemaValidationIdentifiers(in text: String) -> [String] {
        var identifiers: [String] = []
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern: #"(?i)column "([^"]+)" does not exist"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern:
                    #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced(?: base)? tables|not on [^.\s]+(?:\.[^.\s]+)?|not an output column of [^.;]+|ambiguous across referenced tables)"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern: #"Schema validation failed: table ([^\s]+) is not in the selected schema"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern:
                    #"Schema validation failed: qualifier ([A-Za-z_][A-Za-z0-9_$]*) does not resolve to a selected-schema table"#
            ))
        return identifiers
    }

    private static func shouldForbidIdentifier(
        _ identifier: String,
        sql: String,
        schema: DatabaseSchema?
    ) -> Bool {
        guard let schema else { return true }
        let canonical = canonicalIdentifier(identifier)
        if SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: sql)
            .contains(where: { canonicalIdentifier($0) == canonical })
        {
            return true
        }
        guard !identifier.contains(".") else { return true }
        return !missingColumnCanBeResolvedByJoining(identifier, sql: sql, schema: schema)
    }

    private static func missingColumnsCanBeResolvedByJoining(
        sql: String,
        error: String,
        schema: DatabaseSchema
    ) -> Bool {
        let missingColumns = schemaValidationIdentifiers(in: error)
            .filter { !$0.contains(".") }
        guard !missingColumns.isEmpty else { return false }
        return missingColumns.allSatisfy {
            missingColumnCanBeResolvedByJoining($0, sql: sql, schema: schema)
        }
    }

    private static func missingColumnCanBeResolvedByJoining(
        _ columnName: String,
        sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let referencedTables = resolvedTables(
            from: SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: sql),
            schema: schema
        )
        guard !referencedTables.isEmpty else { return false }
        let reachableTableIDs = reachableTableIDs(from: Set(referencedTables.map(\.id)), schema: schema)
        let foldedColumn = columnName.lowercased()
        return schema.tables.contains { table in
            reachableTableIDs.contains(table.id)
                && table.columns.contains { $0.name.lowercased() == foldedColumn }
        }
    }

    private static func resolvedTables(
        from identifiers: [String],
        schema: DatabaseSchema
    ) -> [TableInfo] {
        identifiers.compactMap { identifier in
            let canonical = canonicalIdentifier(identifier)
            if let table = schema.tables.first(where: {
                canonicalIdentifier($0.qualifiedName) == canonical
            }) {
                return table
            }
            let matches = schema.tables.filter {
                canonicalIdentifier($0.name) == canonical
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private static func reachableTableIDs(
        from tableIDs: Set<String>,
        schema: DatabaseSchema,
        maxHops: Int = 2
    ) -> Set<String> {
        var reachable = tableIDs
        var frontier = tableIDs
        guard maxHops > 0 else { return reachable }
        for _ in 0..<maxHops {
            var next = Set<String>()
            for foreignKey in schema.foreignKeys {
                let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
                let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
                if frontier.contains(sourceID), reachable.insert(targetID).inserted {
                    next.insert(targetID)
                }
                if frontier.contains(targetID), reachable.insert(sourceID).inserted {
                    next.insert(sourceID)
                }
            }
            guard !next.isEmpty else { break }
            frontier = next
        }
        return reachable
    }

    private static func quotedIdentifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func missingRelationIdentifier(in text: String) -> String? {
        firstCapturedValue(
            in: text,
            pattern: #"(?i)\brelation\s+"([^"]+)"\s+does\s+not\s+exist"#
        )
    }

    private static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static func firstCapturedValue(in text: String, pattern: String) -> String? {
        capturedValues(in: text, pattern: pattern).first
    }

    private static func capturedValues(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    private static func isRetryableGeneratedSQLError(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        let nonRepairableFragments = [
            "not connected",
            "could not connect",
            "connection failed",
            "connection refused",
            "connection reset",
            "authentication failed",
            "database not found",
            "permission denied",
            "insufficient privilege",
            "42501",
            "timed out",
            "statement timeout",
            "stopped waiting",
            "canceling statement",
            "cancelled",
            "canceled",
        ]
        guard !nonRepairableFragments.contains(where: { lowercased.contains($0) }) else {
            return false
        }
        return true
    }

    private static func isRetryableGeneratedSQLFailure(_ failure: QueryFailure?) -> Bool {
        guard let failure else { return false }
        if let diagnostic = failure.diagnostic ?? Self.diagnostic(from: failure.message) {
            switch diagnostic.kind {
            case .insufficientPrivilege, .timedOut, .cancelled:
                return false
            default:
                break
            }
            if diagnostic.sqlState == "42501" || diagnostic.sqlState == "57014" {
                return false
            }
            return true
        }
        return isRetryableGeneratedSQLError(failure.message)
    }
}

private struct RepairQuestionContext {
    var question: String
    var recentQuestions: [String]
    var originalQuestion: String?
    var conversationMessages: [SQLConversationMessage]
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

    func withPendingClarification(_ pending: PendingClarification) -> SQLGenerationResult {
        var copy = self
        copy.sql = ""
        copy.explanation = pending.question
        copy.needsClarification = true
        copy.clarificationQuestion = pending.question
        copy.clarificationOptions = pending.options
        copy.pendingClarificationID = pending.id
        copy.pendingClarification = pending
        copy.groundingConcepts = [pending.concept]
        copy.confidence = min(copy.confidence, 0.2)
        copy.riskLevel = .medium
        return copy
    }

    func withResolvedClarification(
        _ pending: PendingClarification?,
        replyText: String,
        selectedOption: ClarificationOption?
    ) -> SQLGenerationResult {
        guard let pending else { return self }
        var copy = self
        copy.resolvedClarification = pending
        copy.resolvedClarificationReply = replyText
        copy.resolvedClarificationOption = selectedOption
        return copy
    }

    func applyingClarificationProgress(from previous: PendingClarification?) -> SQLGenerationResult {
        guard let previous, needsClarification else { return self }
        let next = pendingClarification ?? previous
        guard Self.isAllowedFollowUpClarification(next, after: previous) else {
            return withPendingClarification(Self.incrementedClarification(previous))
        }
        guard Self.isSameClarificationSlot(next, previous) else {
            return self
        }
        return withPendingClarification(Self.incrementedClarification(next, after: previous))
    }

    private static func isAllowedFollowUpClarification(
        _ next: PendingClarification,
        after previous: PendingClarification
    ) -> Bool {
        if isSameClarificationSlot(next, previous) {
            return true
        }
        guard let plan = previous.plan else {
            return false
        }
        return plan.slots.contains { slot in
            slot.required
                && (slot.state == .unsupported || slot.state == .ambiguous)
                && (next.slotID == slot.id
                    || next.concept.term.caseInsensitiveCompare(slot.phrase) == .orderedSame)
        }
    }

    private static func isSameClarificationSlot(
        _ lhs: PendingClarification,
        _ rhs: PendingClarification
    ) -> Bool {
        if let lhsSlot = lhs.slotID, let rhsSlot = rhs.slotID {
            return lhsSlot == rhsSlot
        }
        return lhs.concept.term.caseInsensitiveCompare(rhs.concept.term) == .orderedSame
    }

    private static func incrementedClarification(
        _ pending: PendingClarification,
        after previous: PendingClarification? = nil
    ) -> PendingClarification {
        var copy = pending
        copy.turnCount = (previous?.turnCount ?? pending.turnCount) + 1
        if copy.turnCount >= 2 {
            copy.question = cappedClarificationQuestion(for: copy)
        }
        return copy
    }

    private static func cappedClarificationQuestion(for pending: PendingClarification) -> String {
        let choices = pending.options.prefix(3).map { "- \($0.label)" }.joined(separator: "\n")
        let suffix = choices.isEmpty ? "" : "\n\(choices)"
        if pending.slotID == .occurrenceRelation || pending.concept.kind == .relationship {
            return """
                I still cannot identify the relationship to use. Choose one of these schema objects, or add a database definition:
                \(choices)
                """
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
            I still cannot identify \(pending.concept.term). Choose one of these schema objects, or add a database definition:\(suffix)
            """
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
