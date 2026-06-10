import Foundation
import Testing

@testable import WidenKit

@Suite("ChatViewModel")
@MainActor
struct ChatViewModelTests {
    private struct StubGenerator: SQLGenerator {
        var result: SQLGenerationResult
        func generateSQL(
            question: String, schema: DatabaseSchema, config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            result
        }
    }

    private struct FailingGenerator: SQLGenerator {
        func generateSQL(
            question: String, schema: DatabaseSchema, config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            throw AppError.modelUnavailable("Local Apple model is unavailable.")
        }
    }

    private func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1)
                    ])
            ],
            foreignKeys: []
        )
    }

    private func makeGeneration(
        sql: String = "SELECT id FROM users LIMIT 10",
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: sql,
            explanation: "Lists user ids.",
            assumptions: [],
            referencedTables: ["public.users"],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion
        )
    }

    @Test func submitAppendsUserAndAssistantMessagesAndFillsPreview() async {
        let chatVM = ChatViewModel()
        let queryVM = QueryResultViewModel()
        chatVM.input = "show users"

        await chatVM.submit(
            schema: makeSchema(),
            generator: StubGenerator(result: makeGeneration()),
            config: SQLGenerationConfig(),
            queryVM: queryVM
        )

        #expect(chatVM.messages.count == 2)
        #expect(chatVM.messages[0].role == .user)
        #expect(chatVM.messages[0].text == "show users")
        #expect(chatVM.messages[1].role == .assistant)
        #expect(chatVM.messages[1].text == "Lists user ids.")
        #expect(chatVM.input.isEmpty)

        #expect(queryVM.sqlText == "SELECT id FROM users LIMIT 10")
        #expect(queryVM.validation?.isValid == true)
        #expect(queryVM.generation != nil)
    }

    @Test func clarificationQuestionIsShownInsteadOfExplanation() async {
        let chatVM = ChatViewModel()
        let queryVM = QueryResultViewModel()
        chatVM.input = "show me the thing"

        await chatVM.submit(
            schema: makeSchema(),
            generator: StubGenerator(
                result: makeGeneration(
                    sql: "",
                    needsClarification: true,
                    clarificationQuestion: "Which table do you mean by “the thing”?")),
            config: SQLGenerationConfig(),
            queryVM: queryVM
        )

        #expect(chatVM.messages.last?.text == "Which table do you mean by “the thing”?")
        // No SQL was generated, so the preview stays untouched.
        #expect(queryVM.sqlText.isEmpty)
    }

    @Test func generatorErrorsBecomeErrorMessages() async {
        let chatVM = ChatViewModel()
        chatVM.input = "anything"

        await chatVM.submit(
            schema: makeSchema(),
            generator: FailingGenerator(),
            config: SQLGenerationConfig(),
            queryVM: QueryResultViewModel()
        )

        #expect(chatVM.messages.last?.role == .error)
        #expect(chatVM.messages.last?.text.contains("unavailable") == true)
    }

    @Test func submitWithoutSchemaShowsGuidance() async {
        let chatVM = ChatViewModel()
        chatVM.input = "hello"

        await chatVM.submit(
            schema: nil,
            generator: StubGenerator(result: makeGeneration()),
            config: SQLGenerationConfig(),
            queryVM: QueryResultViewModel()
        )

        #expect(chatVM.messages.count == 1)
        #expect(chatVM.messages[0].role == .error)
        #expect(chatVM.messages[0].text.contains("Connect to a database"))
    }

    @Test func emptyInputIsIgnored() async {
        let chatVM = ChatViewModel()
        chatVM.input = "   "
        await chatVM.submit(
            schema: makeSchema(),
            generator: StubGenerator(result: makeGeneration()),
            config: SQLGenerationConfig(),
            queryVM: QueryResultViewModel()
        )
        #expect(chatVM.messages.isEmpty)
    }
}
