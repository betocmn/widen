import Foundation
import Observation

@MainActor
@Observable
public final class ChatViewModel {
    public var messages: [ChatMessage] = []
    public var input = ""
    public private(set) var isGenerating = false

    public init() {}

    /// Submits the current input: appends the user message, generates SQL,
    /// appends the assistant explanation, and fills the SQL preview.
    public func submit(appState: AppState) async {
        await submit(
            schema: appState.schema,
            generator: appState.sqlGenerator,
            config: SQLGenerationConfig(
                defaultRowLimit: appState.config?.defaultRowLimit ?? 100),
            queryVM: appState.queryVM
        )
    }

    func submit(
        schema: DatabaseSchema?,
        generator: any SQLGenerator,
        config: SQLGenerationConfig,
        queryVM: QueryResultViewModel
    ) async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        guard let schema, !schema.tables.isEmpty else {
            messages.append(
                ChatMessage(
                    role: .error,
                    text: "Connect to a database and load its schema before asking questions."
                ))
            return
        }

        input = ""
        messages.append(ChatMessage(role: .user, text: question))
        isGenerating = true
        defer { isGenerating = false }

        do {
            let result = try await generator.generateSQL(
                question: question, schema: schema, config: config)

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
