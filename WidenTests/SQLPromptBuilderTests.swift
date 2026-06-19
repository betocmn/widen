import Foundation
import Testing

@testable import WidenKit

@Suite("SQLPromptBuilder")
struct SQLPromptBuilderTests {
    private func makeSampleSchema() -> DatabaseSchema {
        let users = TableInfo(
            schema: "public",
            name: "users",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "id",
                    dataType: "integer", isNullable: false, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "email",
                    dataType: "text", isNullable: false, ordinalPosition: 2),
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "name",
                    dataType: "text", isNullable: true, ordinalPosition: 3),
            ]
        )
        let orders = TableInfo(
            schema: "public",
            name: "orders",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "id",
                    dataType: "integer", isNullable: false, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "user_id",
                    dataType: "integer", isNullable: false, ordinalPosition: 2),
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "total_cents",
                    dataType: "integer", isNullable: false, ordinalPosition: 3),
            ]
        )
        let fk = ForeignKeyInfo(
            constraintName: "orders_user_id_fkey",
            sourceSchema: "public", sourceTable: "orders", sourceColumn: "user_id",
            targetSchema: "public", targetTable: "users", targetColumn: "id"
        )
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [users, orders],
            foreignKeys: [fk]
        )
    }

    @Test func schemaSummaryIncludesTablesColumnsTypesAndForeignKeys() {
        let summary = SQLPromptBuilder.schemaSummary(makeSampleSchema())
        #expect(summary.contains("Table \"public\".\"users\""))
        #expect(summary.contains("- \"id\" integer not null"))
        #expect(summary.contains("- \"email\" text not null"))
        // Nullable columns get no suffix, matching the roadmap format.
        #expect(summary.contains("- \"name\" text\n"))
        #expect(summary.contains("Table \"public\".\"orders\""))
        #expect(summary.contains("Foreign keys:"))
        #expect(summary.contains("- \"public\".\"orders\".\"user_id\" -> \"public\".\"users\".\"id\""))
    }

    @Test func schemaSummaryQuotesPostgresIdentifiers() {
        let table = TableInfo(
            schema: "Sales Data",
            name: "Q1.Orders",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "Sales Data", tableName: "Q1.Orders", name: "select",
                    dataType: "text", isNullable: true, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "Sales Data", tableName: "Q1.Orders", name: "quoted\"name",
                    dataType: "integer", isNullable: false, ordinalPosition: 2),
            ]
        )
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "Sales Data")],
            tables: [table],
            foreignKeys: []
        )

        let summary = SQLPromptBuilder.schemaSummary(schema)

        #expect(summary.contains("Table \"Sales Data\".\"Q1.Orders\""))
        #expect(summary.contains("- \"select\" text"))
        #expect(summary.contains("- \"quoted\"\"name\" integer not null"))
    }

    @Test func schemaSummaryIncludesColumnValueConstraints() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "evaluations",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "evaluations",
                            name: "winner_decision",
                            dataType: "user-defined",
                            isNullable: false,
                            ordinalPosition: 1,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .enumValues,
                                    values: ["tool_a", "tool_b", "tie"]
                                )
                            ]
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "evaluations",
                            name: "review_status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["approved", "rejected"],
                                    expression:
                                        "CHECK ((review_status = ANY (ARRAY['approved'::text, 'rejected'::text])))",
                                    constraintName: "evaluations_review_status_check"
                                )
                            ]
                        ),
                    ]
                )
            ]
        )

        let summary = SQLPromptBuilder.schemaSummary(schema)

        #expect(
            summary.contains(
                #"- "winner_decision" user-defined not null (values: 'tool_a', 'tool_b', 'tie')"#
            ))
        #expect(
            summary.contains(
                #"- "review_status" text not null (check values: 'approved', 'rejected')"#
            ))
    }

    @Test func promptContainsQuestionAndSchema() {
        let prompt = SQLPromptBuilder.prompt(
            question: "Show me the 10 most recent users.",
            schema: makeSampleSchema()
        )
        #expect(prompt.contains("Database schema:"))
        #expect(prompt.contains("<database_schema>"))
        #expect(prompt.contains("</database_schema>"))
        #expect(prompt.contains("<current_user_request>"))
        #expect(prompt.contains("User question: Show me the 10 most recent users."))
        #expect(prompt.contains("</current_user_request>"))
    }

    @Test func instructionsContainSafetyRulesAndRowLimit() {
        let instructions = SQLPromptBuilder.instructions(defaultRowLimit: 250)
        #expect(instructions.contains("SELECT, WITH ... SELECT, INSERT, UPDATE, or DELETE"))
        #expect(instructions.contains("Only generate a write"))
        #expect(instructions.contains("Use a default LIMIT of 250."))
        #expect(instructions.contains("Database context"))
        #expect(instructions.contains("Never generate MERGE, ALTER, DROP"))
        #expect(instructions.contains("Do not generate standalone SET or DO statements."))
        #expect(instructions.contains("SET may appear only as an UPDATE clause"))
        #expect(instructions.contains("ON CONFLICT DO UPDATE"))
        #expect(instructions.contains("Do not include semicolons."))
        #expect(instructions.contains("needsClarification"))
        #expect(instructions.contains("Use schema-qualified table names"))
        // PostgreSQL dialect guardrails — the local model drifts into MySQL.
        #expect(instructions.contains("CURDATE()"))
        #expect(instructions.contains("INTERVAL '7 days'"))
        #expect(instructions.contains("DATE_TRUNC('day'"))
        #expect(instructions.contains("first count rows per period"))
        #expect(instructions.contains("Do not group or partition by CURRENT_DATE itself"))
        #expect(instructions.contains("Business terms can have database-specific meanings"))
        #expect(instructions.contains("other proxy metric"))
        #expect(SQLPromptBuilder.compactInstructions(defaultRowLimit: 250).contains("Do not answer with a proxy metric"))
        #expect(instructions.contains("answers affirmatively to a previous assistant clarification"))
        // Follow-up handling for the conversation context section.
        #expect(instructions.contains("follow-up"))
        #expect(instructions.contains("<ordered_chat_history>"))
    }

    @Test func compactInstructionsKeepWinningToolPromptUnderLocalBudget() {
        let question = "what are tools that are getting the most wins in the last two weeks?"
        let instructions = SQLPromptBuilder.compactInstructions(defaultRowLimit: 100)
        let verboseInstructions = SQLPromptBuilder.instructions(defaultRowLimit: 100)
        let budget = PromptBudget.localFoundationModels
        let context = SQLGenerationContext(
            schemaSearchQueries: [
                "winning tools last two weeks winner_id createdAt",
                "public.preseason_match_evaluation",
                "public.preseason_tool",
            ]
        )
        let fixedPromptCharacters = instructions.count + question.count + 1_600
        let schemaCharacters = min(
            8_000,
            budget.schemaCharacterAllowance(fixedPromptCharacters: fixedPromptCharacters)
        )

        let bundle = SQLPromptBuilder.promptBundle(
            question: question,
            schema: makeScreenshotWinningToolSchema(extraTables: 60),
            context: context,
            maxSchemaCharacters: schemaCharacters
        )

        #expect(instructions.count < verboseInstructions.count)
        #expect(budget.fits(inputCharacters: instructions.count + bundle.prompt.count))
        #expect(bundle.prompt.contains(#"TABLE "public"."preseason_match_evaluation""#))
        #expect(bundle.prompt.contains(#""winner_id" uuid"#))
        #expect(bundle.prompt.contains(#""createdAt" timestamp with time zone"#))
        #expect(bundle.prompt.contains(#"FK "winner_id" -> "public"."preseason_tool"."id""#))
        #expect(bundle.prompt.contains(#"TABLE "public"."preseason_tool""#))
    }

    @Test func promptWithoutContextHasNoContextSection() {
        let prompt = SQLPromptBuilder.prompt(
            question: "Show me users.",
            schema: makeSampleSchema()
        )
        #expect(!prompt.contains("<conversation_context>"))
    }

    @Test func promptIncludesDatabaseContextBeforeConversationAndQuestion() {
        let context = SQLGenerationContext(recentQuestions: ["last question"])
        let prompt = SQLPromptBuilder.prompt(
            question: "Show active customers.",
            schema: makeSampleSchema(),
            context: context,
            databaseContext: "  Active customers have orders in the last 90 days.\n"
        )

        #expect(prompt.contains("Database context:\nActive customers have orders in the last 90 days."))
        let databaseContextRange = prompt.range(of: "Database context:")
        let conversationRange = prompt.range(of: "<conversation_context>")
        let questionRange = prompt.range(of: "User question:")
        #expect(databaseContextRange!.lowerBound < conversationRange!.lowerBound)
        #expect(conversationRange!.lowerBound < questionRange!.lowerBound)
    }

    @Test func emptyDatabaseContextIsOmittedAndLongContextIsTruncated() {
        #expect(SQLPromptBuilder.databaseContextSection("   \n") == nil)

        let section = SQLPromptBuilder.databaseContextSection(
            String(repeating: "x", count: SQLPromptBuilder.maxDatabaseContextCharacters + 10)
        )

        #expect(section?.contains("Database context:") == true)
        #expect(section?.contains("…") == true)
        #expect((section?.count ?? 0) < SQLPromptBuilder.maxDatabaseContextCharacters + 30)
    }

    @Test func promptIncludesConversationContext() {
        let context = SQLGenerationContext(
            recentQuestions: ["max spend per customer?", "just the last week?"],
            originalQuestion: "max spend per customer?",
            conversationMessages: [
                SQLConversationMessage(role: .user, text: "max spend per customer?"),
                SQLConversationMessage(
                    role: .assistant,
                    text: "Generated a max-spend query.\nGenerated SQL:\nSELECT MAX(total_cents) FROM public.orders"
                ),
                SQLConversationMessage(role: .user, text: "just the last week?"),
            ],
            currentSQL: "SELECT MAX(total_cents) FROM public.orders",
            lastRunError: "syntax error at or near \"30\""
        )
        let prompt = SQLPromptBuilder.prompt(
            question: "the query is failing",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<conversation_context>"))
        #expect(prompt.contains("back-and-forth chat"))
        #expect(prompt.contains("<original_user_question>"))
        #expect(prompt.contains("max spend per customer?"))
        #expect(prompt.contains(#"<message index="1" role="user">"#))
        #expect(prompt.contains(#"<message index="2" role="assistant">"#))
        #expect(prompt.contains(#"<message index="3" role="user">"#))
        #expect(prompt.contains("<current_sql_on_screen>"))
        #expect(prompt.contains("SELECT MAX(total_cents)"))
        #expect(prompt.contains("<last_run_error>"))
        #expect(prompt.contains("syntax error at or near \"30\""))
        // The question always comes last, after the context.
        let questionRange = prompt.range(of: "User question:")
        let contextRange = prompt.range(of: "<conversation_context>")
        #expect(contextRange!.lowerBound < questionRange!.lowerBound)
    }

    @Test func promptMarksAffirmativeClarificationAsConfirmed() {
        let clarification =
            #"I can see "public"."preseason_match_evaluation"."winner_id" joins to "public"."preseason_tool"."id". Should I define "most wins" as counting rows where "public"."preseason_match_evaluation"."winner_id" is not null, grouped by "public"."preseason_tool"."id"?"#
        let context = SQLGenerationContext(
            recentQuestions: ["what are tools that are getting the most wins in the last two weeks?"],
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            conversationMessages: [
                SQLConversationMessage(
                    role: .user,
                    text: "what are tools that are getting the most wins in the last two weeks?"
                ),
                SQLConversationMessage(role: .assistant, text: clarification),
                SQLConversationMessage(role: .user, text: "yes"),
            ]
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "yes",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<confirmed_clarification>"))
        #expect(prompt.contains("answered an assistant clarification question affirmatively"))
        #expect(prompt.contains("the active task is still the original user question"))
        #expect(prompt.contains("Do not ask the same clarification question again."))
        #expect(prompt.contains(#"<approved_question>"#))
        #expect(prompt.contains(#"<user_answer>"#))
        #expect(prompt.contains("winner_id"))
    }

    @Test func promptDoesNotConfirmGenericAssistantQuestion() {
        let context = SQLGenerationContext(
            recentQuestions: ["show users"],
            originalQuestion: "show users",
            conversationMessages: [
                SQLConversationMessage(role: .user, text: "show users"),
                SQLConversationMessage(role: .assistant, text: "Can I help with anything else?"),
                SQLConversationMessage(role: .user, text: "yes"),
            ]
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "yes",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(!prompt.contains("<confirmed_clarification>"))
    }

    @Test func promptIncludesAggregateWindowRepairHint() {
        let context = SQLGenerationContext(
            currentSQL:
                "SELECT AVG(COUNT(*) OVER (PARTITION BY created_at)) FROM public.orders",
            lastRunError:
                "Query failed: aggregate function calls cannot contain window function calls"
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "How many orders are we getting in average per day?",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<repair_requirement>"))
        #expect(prompt.contains("Do not use OVER inside AVG"))
        #expect(prompt.contains("WITH counts AS"))
    }

    @Test func promptIncludesRepeatedSQLRepairHint() {
        let context = SQLGenerationContext(
            currentSQL: "SELECT id FROM public.missing_table",
            lastRunError:
                "The model repeated the exact same SQL after it failed. Database error: relation does not exist"
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "show users",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<repair_requirement>"))
        #expect(prompt.contains("Do not return the current SQL again"))
        #expect(prompt.contains("needsClarification"))
    }

    @Test func promptIncludesMissingColumnRepairHintWithCandidates() {
        let context = SQLGenerationContext(
            currentSQL:
                "SELECT DISTINCT tool_id FROM public.preseason_match_batch ORDER BY completed_evaluations DESC",
            lastRunError:
                #"Query failed: column "tool_id" does not exist Hint: Perhaps you meant to reference the column "preseason_match_batch.tool_a_id" or the column "preseason_match_batch.tool_b_id"."#
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "what tools have the most wins?",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("The previous SQL used column \"tool_id\""))
        #expect(prompt.contains("preseason_match_batch.tool_a_id"))
        #expect(prompt.contains("preseason_match_batch.tool_b_id"))
        #expect(prompt.contains("needsClarification"))
    }

    @Test func missingColumnClarificationQuestionNamesCandidateColumns() {
        let question = SQLPromptBuilder.missingColumnClarificationQuestion(
            for:
                #"Query failed: column "tool_id" does not exist Hint: Perhaps you meant to reference the column "preseason_match_batch.tool_a_id" or the column "preseason_match_batch.tool_b_id"."#
        )

        #expect(question?.contains("\"tool_id\"") == true)
        #expect(question?.contains("\"preseason_match_batch.tool_a_id\"") == true)
        #expect(question?.contains("\"preseason_match_batch.tool_b_id\"") == true)
        #expect(question?.contains("replace") == false)
    }

    @Test func missingColumnClarificationQuestionHandlesSchemaValidationErrors() {
        let question = SQLPromptBuilder.missingColumnClarificationQuestion(
            for:
                "The SQL failed validation: Schema validation failed: column tool_a_id is not available from the referenced tables. Schema validation failed: column tool_b_id is not available from the referenced tables."
        )

        #expect(question?.contains("\"tool_a_id\"") == true)
        #expect(question?.contains("\"tool_b_id\"") == true)
        #expect(question?.contains("Which table or relationship") == true)
        #expect(question?.contains("replace") == false)
    }

    @Test func missingColumnClarificationQuestionIgnoresQuoteAndTemporalDiagnostics() {
        let question = SQLPromptBuilder.missingColumnClarificationQuestion(
            for:
                #"The SQL failed validation: Schema validation failed: column tool_a_id is not available from the referenced tables. Schema validation failed: column createdAt must be quoted as "createdAt" on public.events. Schema validation failed: column createdAt is timestamp with time zone and cannot be compared directly to an INTERVAL."#
        )

        #expect(question?.contains("\"tool_a_id\"") == true)
        #expect(question?.contains("createdAt") == false)
        #expect(question?.contains("replace") == false)
    }

    @Test func missingColumnClarificationQuestionDoesNotInventMetricRelationship() {
        let question = SQLPromptBuilder.missingColumnClarificationQuestion(
            for:
                "The SQL failed validation: Schema validation failed: column tool_id is not available from the referenced tables.",
            question: "what are tools that are getting the most wins in the last two weeks?",
            schema: makeWinningToolSchema()
        )

        #expect(question?.contains("\"tool_id\"") == true)
        #expect(question?.contains("Which table or relationship") == true)
        #expect(question?.contains("replace") == false)
        #expect(question?.contains("most wins") != true)
        #expect(question?.contains("winner_id") != true)
    }

    @Test func repairPromptIncludesFailedSQLOnceAndOmitsChatHistory() {
        let failedSQL = "SELECT id FROM public.match_batch"
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "show match batches",
            conversationMessages: [
                SQLConversationMessage(role: .assistant, text: "Generated SQL:\n\(failedSQL)")
            ],
            currentSQL: failedSQL,
            lastRunError: #"Query failed: relation "public.match_batch" does not exist"#,
            repairContext: SQLRepairContext(
                failedSQL: failedSQL,
                diagnostic: DatabaseDiagnostic(
                    kind: .missingRelation,
                    sqlState: "42P01",
                    message: #"relation "public.match_batch" does not exist"#,
                    tableName: "match_batch"
                ),
                forbiddenIdentifiers: ["public.match_batch"],
                priorFingerprints: ["select id from public.match_batch"]
            )
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "fix it",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<repair_task>"))
        #expect(!prompt.contains("<ordered_chat_history>"))
        #expect(occurrences(of: failedSQL, in: prompt) == 1)
        #expect(prompt.contains("<forbidden_identifier>"))
        #expect(prompt.contains("public.match_batch"))
        #expect(prompt.contains("<sqlstate>42P01</sqlstate>"))
    }

    @Test func reconstructionPromptExcludesFailedSQL() {
        let failedSQL = "SELECT id FROM public.match_batch"
        let context = SQLGenerationContext(
            mode: .reconstructAfterFailedRepair,
            originalQuestion: "show match batches",
            currentSQL: failedSQL,
            repairContext: SQLRepairContext(
                failedSQL: failedSQL,
                forbiddenIdentifiers: ["public.match_batch"],
                priorFingerprints: ["select id from public.match_batch"]
            )
        )

        let prompt = SQLPromptBuilder.prompt(
            question: "show match batches",
            schema: makeSampleSchema(),
            context: context
        )

        #expect(prompt.contains("<reconstruction_task>"))
        #expect(!prompt.contains("<failed_sql>"))
        #expect(!prompt.contains(failedSQL))
        #expect(prompt.contains("<must_not_use>"))
        #expect(prompt.contains("public.match_batch"))
    }

    @Test func contextSectionIncludesOriginalQuestionAndKeepsLastThreeQuestionsInHistory() {
        let longSQL = String(repeating: "S", count: 2_000)
        let context = SQLGenerationContext(
            recentQuestions: ["q1", "q2", "q3", "q4", "q5"],
            currentSQL: longSQL,
            lastRunError: String(repeating: "e", count: 600)
        )

        let section = SQLPromptBuilder.contextSection(context)!

        #expect(section.contains("<original_user_question>"))
        #expect(section.contains("q1"))
        #expect(!section.contains("q2"))
        #expect(section.contains("q3"))
        #expect(section.contains("q5"))
        #expect(section.contains(#"<message index="1" role="user">"#))
        #expect(section.contains("<current_sql_on_screen>"))
        #expect(section.contains("<last_run_error>"))
        #expect(section.count < 2_400)
        #expect(section.contains("…"))
    }

    @Test func truncatesWholeTablesWhenOverBudget() {
        var schema = makeSampleSchema()
        // Add many wide tables so the budget is exceeded.
        for index in 0..<50 {
            let columns = (0..<30).map { col in
                ColumnInfo(
                    tableSchema: "public", tableName: "big_table_\(index)",
                    name: "column_with_a_long_name_\(col)",
                    dataType: "character varying", isNullable: true,
                    ordinalPosition: col + 1)
            }
            schema.tables.append(
                TableInfo(
                    schema: "public", name: "big_table_\(index)",
                    type: .baseTable, columns: columns))
        }

        let summary = SQLPromptBuilder.schemaSummary(schema, maxCharacters: 2_000)
        #expect(summary.count < 2_500)
        #expect(summary.contains("(Schema truncated:"))
        #expect(SQLPromptBuilder.isSchemaTruncated(schema, maxCharacters: 2_000))
        #expect(!SQLPromptBuilder.isSchemaTruncated(makeSampleSchema()))
    }

    @Test func excludedTablesDropTheirForeignKeys() {
        var schema = makeSampleSchema()
        // Make `users` enormous so it never fits in a small budget; its FK
        // (orders -> users) must then disappear from the summary too.
        let hugeColumns = (0..<200).map { col in
            ColumnInfo(
                tableSchema: "public", tableName: "users",
                name: "very_long_padding_column_name_number_\(col)",
                dataType: "character varying", isNullable: true,
                ordinalPosition: col + 10)
        }
        schema.tables[0].columns.append(contentsOf: hugeColumns)

        let summary = SQLPromptBuilder.schemaSummary(schema, maxCharacters: 400)
        #expect(!summary.contains("\"orders\".\"user_id\" ->"))
    }

    @Test func systemSchemasAreNotInTheSummary() {
        // Introspection already excludes pg_catalog/information_schema; the
        // summary must simply reflect the schema it is given.
        let summary = SQLPromptBuilder.schemaSummary(makeSampleSchema())
        #expect(!summary.contains("pg_catalog"))
        #expect(!summary.contains("information_schema"))
    }

    private func makeWinningToolSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_evaluation",
                    type: .baseTable,
                    columns: [
                        column("preseason_match_evaluation", "id", ordinal: 1),
                        column("preseason_match_evaluation", "winner_id", ordinal: 2),
                        column(
                            "preseason_match_evaluation",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 3
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_tool",
                    type: .baseTable,
                    columns: [
                        column("preseason_tool", "id", ordinal: 1),
                        column("preseason_tool", "name", type: "character varying", ordinal: 2),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "match_evaluation_winner_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "winner_id",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeScreenshotWinningToolSchema(extraTables: Int) -> DatabaseSchema {
        var schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_benchmark_model_weight_config",
                    type: .baseTable,
                    columns: [
                        column(
                            "preseason_benchmark_model_weight_config",
                            "id",
                            ordinal: 1
                        ),
                        column(
                            "preseason_benchmark_model_weight_config",
                            "slug",
                            type: "character varying",
                            ordinal: 2
                        ),
                        column(
                            "preseason_benchmark_model_weight_config",
                            "name",
                            type: "character varying",
                            ordinal: 3
                        ),
                        column(
                            "preseason_benchmark_model_weight_config",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 9
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        column("preseason_match_batch", "id", ordinal: 1),
                        column("preseason_match_batch", "tool_a_id", ordinal: 2),
                        column("preseason_match_batch", "tool_b_id", ordinal: 3),
                        column(
                            "preseason_match_batch",
                            "completed_evaluations",
                            type: "integer",
                            ordinal: 12
                        ),
                        column(
                            "preseason_match_batch",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 21
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_match_evaluation",
                    type: .baseTable,
                    columns: [
                        column("preseason_match_evaluation", "id", ordinal: 1),
                        column("preseason_match_evaluation", "batch_id", ordinal: 2),
                        column("preseason_match_evaluation", "winner_id", ordinal: 8),
                        column(
                            "preseason_match_evaluation",
                            "winner_decision",
                            type: "user-defined",
                            ordinal: 7,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .enumValues,
                                    values: ["tool_a", "tool_b", "tie"]
                                )
                            ]
                        ),
                        column(
                            "preseason_match_evaluation",
                            "raw_response",
                            type: "text",
                            ordinal: 18
                        ),
                        column(
                            "preseason_match_evaluation",
                            "appendix_json",
                            type: "jsonb",
                            ordinal: 19
                        ),
                        column(
                            "preseason_match_evaluation",
                            "system_prompt_snapshot",
                            type: "text",
                            ordinal: 36
                        ),
                        column(
                            "preseason_match_evaluation",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 37
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_tool",
                    type: .baseTable,
                    columns: [
                        column("preseason_tool", "id", ordinal: 1),
                        column("preseason_tool", "name", type: "character varying", ordinal: 2),
                        column("preseason_tool", "slug", type: "character varying", ordinal: 3),
                        column(
                            "preseason_tool",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 9
                        ),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "match_evaluation_batch_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "batch_id",
                    targetSchema: "public",
                    targetTable: "preseason_match_batch",
                    targetColumn: "id"
                ),
                ForeignKeyInfo(
                    constraintName: "match_evaluation_winner_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "winner_id",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    targetColumn: "id"
                ),
                ForeignKeyInfo(
                    constraintName: "match_batch_tool_a_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_batch",
                    sourceColumn: "tool_a_id",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    targetColumn: "id"
                ),
                ForeignKeyInfo(
                    constraintName: "match_batch_tool_b_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_batch",
                    sourceColumn: "tool_b_id",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    targetColumn: "id"
                ),
            ]
        )

        for index in 0..<extraTables {
            schema.tables.append(
                TableInfo(
                    schema: "public",
                    name: "preseason_unrelated_table_\(index)",
                    type: .baseTable,
                    columns: [
                        column("preseason_unrelated_table_\(index)", "id", ordinal: 1),
                        column(
                            "preseason_unrelated_table_\(index)",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 2
                        ),
                    ]
                ))
        }

        return schema
    }

    private func column(
        _ tableName: String,
        _ name: String,
        type: String = "uuid",
        ordinal: Int,
        valueConstraints: [ColumnValueConstraint]? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: tableName,
            name: name,
            dataType: type,
            isNullable: false,
            ordinalPosition: ordinal,
            valueConstraints: valueConstraints
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
