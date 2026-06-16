import Foundation
import Observation

@MainActor
@Observable
public final class ChatViewModel {
    public var messages: [ChatMessage] = []
    public var input = ""
    public private(set) var isGenerating = false
    public private(set) var generationStatus: String?

    public init() {}

    /// True when the trimmed input reads as raw SQL: one of the statement
    /// kinds the validator can run directly. Word-boundary match, so
    /// "SELECTED users last week" is natural language. SQL that opens with a
    /// comment is treated as natural language — the model path still produces
    /// runnable SQL for it.
    public static func isDirectSQL(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = #"(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:""|[^"])+")"#
        let tableTarget = #"(?:\#(identifier)\.)?\#(identifier)"#
        let patterns = [
            #"^(select|with)\b"#,
            #"^insert\s+into\s+\#(tableTarget)\s*(\([^)]*\)\s*)?(default\s+values|values\s*\(|select\b|with\b)"#,
            #"^delete\s+from\s+(only\s+)?\#(tableTarget)(\s+(as\s+)?\#(identifier))?\s*(;)?$"#,
            #"^delete\s+from\s+(only\s+)?\#(tableTarget)(\s+(as\s+)?\#(identifier))?\s+(where|using|returning)\b"#,
            #"^update\s+(only\s+)?\#(tableTarget)(\s+(as\s+)?\#(identifier))?\s+set\s+[^=]+="#,
        ]
        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Direct-SQL path: records the user's SQL in the transcript and loads it
    /// straight into the preview — no model call, no assistant reply.
    func submitDirectSQL(queryVM: QueryResultViewModel) {
        let sql = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty, !isGenerating, !queryVM.isRunning else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: sql))
        queryVM.setDirectSQL(sql)
    }

    /// Appends the persistent history record for a finished run and returns
    /// it, so callers can key ephemeral state (the materialized result) to it.
    @discardableResult
    func appendRunRecord(_ summary: ChatMessage.RunSummary) -> ChatMessage {
        let record = ChatMessage.runRecord(summary)
        messages.append(record)
        return record
    }

    func appendRunError(_ message: String) {
        messages.append(ChatMessage(role: .error, text: message))
    }

    /// Records a failed write run. `failedSQL` lets the transcript offer a
    /// "Try Again" button that asks the model to repair the query without
    /// executing it — writes never auto-retry.
    func appendWriteRunError(_ message: String, failedSQL: String) {
        messages.append(ChatMessage(role: .error, text: message, failedWriteSQL: failedSQL))
    }

    func beginGeneration(status: String? = nil) {
        isGenerating = true
        generationStatus = status
    }

    func updateGenerationStatus(_ status: String?) {
        generationStatus = status
    }

    func finishGeneration() {
        isGenerating = false
        generationStatus = nil
    }

    /// Submits the current input: appends the user message, generates SQL,
    /// appends the assistant explanation, and fills the SQL preview.
    func submit(
        schema: DatabaseSchema?,
        generator: any SQLGenerator,
        config: SQLGenerationConfig,
        queryVM: QueryResultViewModel
    ) async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating, !queryVM.isRunning else { return }
        guard let schema, !schema.tables.isEmpty else {
            messages.append(
                ChatMessage(
                    role: .error,
                    text: "Connect to a database and load its schema before asking questions."
                ))
            return
        }

        // Built before appending the new question: the on-device model is
        // stateless per request, so follow-ups ("just last week", "the query
        // is failing") only work if the prompt carries what they refer to.
        let context = SQLGenerationContext(
            recentQuestions: messages.filter { $0.role == .user }.suffix(3).map(\.text),
            currentSQL: queryVM.sqlText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : queryVM.sqlText,
            lastRunError: queryVM.runError
                ?? (messages.last?.role == .error ? messages.last?.text : nil)
        )

        input = ""
        messages.append(ChatMessage(role: .user, text: question))
        beginGeneration()
        defer { finishGeneration() }

        do {
            let result = try await generator.generateSQL(
                question: question, schema: schema, context: context, config: config)

            if result.needsClarification,
                let clarification = result.clarificationQuestion,
                !clarification.trimmingCharacters(in: .whitespaces).isEmpty
            {
                messages.append(
                    ChatMessage(role: .assistant, text: clarification, generation: result))
            } else {
                messages.append(
                    ChatMessage(role: .assistant, text: result.explanation, generation: result))
            }

            // Generated SQL goes to the editable preview, not only the chat.
            if !result.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queryVM.setGeneration(result)
            }
        } catch {
            messages.append(ChatMessage(role: .error, text: error.localizedDescription))
        }
    }

    public func clearConversation() {
        messages.removeAll()
    }
}
