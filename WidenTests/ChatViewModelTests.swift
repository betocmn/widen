import Foundation
import Testing

@testable import WidenKit

@Suite("ChatViewModel")
@MainActor
struct ChatViewModelTests {
    private struct StubGenerator: SQLGenerator {
        var result: SQLGenerationResult
        func generateSQL(
            question: String, schema: DatabaseSchema,
            context: SQLGenerationContext, config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            result
        }
    }

    private struct FailingGenerator: SQLGenerator {
        func generateSQL(
            question: String, schema: DatabaseSchema,
            context: SQLGenerationContext, config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            throw AppError.modelUnavailable("Local Apple model is unavailable.")
        }
    }

    /// Captures the context the view model hands to the generator.
    private final class RecordingGenerator: SQLGenerator, @unchecked Sendable {
        var result: SQLGenerationResult
        var recordedContext: SQLGenerationContext?

        init(result: SQLGenerationResult) {
            self.result = result
        }

        func generateSQL(
            question: String, schema: DatabaseSchema,
            context: SQLGenerationContext, config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            recordedContext = context
            return result
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

    @Test func submitPassesConversationContextToGenerator() async {
        let chatVM = ChatViewModel()
        let queryVM = QueryResultViewModel()
        let generator = RecordingGenerator(result: makeGeneration())

        // An earlier exchange whose SQL is on screen and whose run failed.
        chatVM.messages = [
            ChatMessage(role: .user, text: "what's the max spend per customer?"),
            ChatMessage(role: .assistant, text: "Explains.", generation: makeGeneration()),
            ChatMessage(role: .error, text: "Query failed: syntax error at or near \"30\""),
        ]
        queryVM.setDirectSQL("SELECT MAX(total_cents) FROM public.orders")
        chatVM.input = "the query is failing"

        await chatVM.submit(
            schema: makeSchema(),
            generator: generator,
            config: SQLGenerationConfig(),
            queryVM: queryVM
        )

        let context = generator.recordedContext
        #expect(context?.recentQuestions == ["what's the max spend per customer?"])
        #expect(context?.currentSQL == "SELECT MAX(total_cents) FROM public.orders")
        #expect(context?.lastRunError == "Query failed: syntax error at or near \"30\"")
    }

    @Test func submitWithFreshSessionPassesEmptyContext() async {
        let chatVM = ChatViewModel()
        let generator = RecordingGenerator(result: makeGeneration())
        chatVM.input = "show users"

        await chatVM.submit(
            schema: makeSchema(),
            generator: generator,
            config: SQLGenerationConfig(),
            queryVM: QueryResultViewModel()
        )

        #expect(generator.recordedContext?.isEmpty == true)
    }

    @Test(arguments: [
        ("select * from users", true),
        ("  SELECT id\nFROM users", true),
        ("WITH x AS (SELECT 1) SELECT * FROM x", true),
        ("with totals as (select 1) select * from totals", true),
        ("INSERT INTO users (email) VALUES ('a@example.com')", true),
        ("INSERT INTO users DEFAULT VALUES", true),
        ("INSERT INTO users VALUES (1, 'a@example.com')", true),
        (#"INSERT INTO "Sales Data"."Q1 Orders" (id) VALUES (1)"#, true),
        ("update users set name = 'A' where id = 1", true),
        (#"update "Sales Data"."Q1 Orders" set status = 'paid' where id = 1"#, true),
        ("DELETE FROM users WHERE id = 1", true),
        ("DELETE FROM users", true),
        ("DELETE FROM users -- cleanup", true),
        ("DELETE FROM users /* cleanup */;", true),
        ("DELETE FROM users; /* cleanup */", false),
        (#"DELETE FROM "Sales Data"."Q1 Orders" WHERE id = 1"#, true),
        ("Insert a new user named Alice", false),
        ("Insert into the users table a new Alice", false),
        ("Update Alice's email to alice@example.com", false),
        ("Delete duplicate users", false),
        ("Delete from the users table", false),
        ("SELECTED users last week", false),
        ("show me users", false),
        ("Withdrawals by month", false),
        ("-- comment\nSELECT 1", false),
        ("", false),
    ])
    func directSQLDetection(input: String, expected: Bool) {
        #expect(ChatViewModel.isDirectSQL(input) == expected)
    }

    @Test func updateFromConfirmationMentionsFromClauseRisk() {
        let sql = "UPDATE users SET email = staging.email FROM staging WHERE staging.ready"
        let confirmation = SQLCardView.writeConfirmation(
            validation: SQLSafetyValidator.validate(sql),
            sql: sql
        )

        #expect(confirmation.title == "Run this UPDATE FROM query?")
        #expect(confirmation.action == "Update Rows")
        #expect(confirmation.message.contains("FROM clause"))
        #expect(!confirmation.message.contains("no WHERE"))
    }

    @Test func updateWithoutWhereConfirmationStillWarnsEveryRow() {
        let sql = "UPDATE users SET email = 'x'"
        let confirmation = SQLCardView.writeConfirmation(
            validation: SQLSafetyValidator.validate(sql),
            sql: sql
        )

        #expect(confirmation.title == "Run this UPDATE without a WHERE clause?")
        #expect(confirmation.action == "Update Every Row")
        #expect(confirmation.message.contains("no WHERE clause"))
    }

    @Test func submitDirectSQLRecordsUserMessageAndFillsPreview() {
        let chatVM = ChatViewModel()
        let queryVM = QueryResultViewModel()
        chatVM.input = "  select id from users  "

        chatVM.submitDirectSQL(queryVM: queryVM)

        #expect(chatVM.messages.count == 1)
        #expect(chatVM.messages[0].role == .user)
        #expect(chatVM.messages[0].text == "select id from users")
        #expect(chatVM.input.isEmpty)
        #expect(queryVM.sqlText == "select id from users")
        #expect(queryVM.validation?.isValid == true)
        #expect(queryVM.generation == nil)
    }

    @Test func appendRunRecordAndErrorLandInTranscript() {
        let chatVM = ChatViewModel()

        chatVM.appendRunRecord(
            ChatMessage.RunSummary(
                rowCount: 3, executionTimeMs: 12, truncated: false, sql: "SELECT 1"))
        chatVM.appendRunError("boom")

        #expect(chatVM.messages.count == 2)
        #expect(chatVM.messages[0].role == .result)
        #expect(chatVM.messages[0].runSummary?.rowCount == 3)
        #expect(chatVM.messages[1].role == .error)
        #expect(chatVM.messages[1].text == "boom")
    }
}
