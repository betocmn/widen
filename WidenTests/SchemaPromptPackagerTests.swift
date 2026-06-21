import Foundation
import Testing

@testable import WidenKit

@Suite("Schema prompt packager")
struct SchemaPromptPackagerTests {
    @Test func missingMatchBatchRanksPreseasonMatchBatchFirst() {
        let schema = makePreseasonSchema(extraTables: 20)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )

        let ranked = SchemaRelevanceRanker.rank(
            schema: schema,
            input: SchemaRankingInput(
                question: "what are tools getting the most wins in the last two weeks?",
                currentSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        #expect(ranked.first?.table.qualifiedName == "public.preseason_match_batch")
    }

    @Test func temporalRequestIncludesForeignKeyAdjacentBenchmarkRun() {
        let schema = makePreseasonSchema(extraTables: 15)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            repairContext: SQLRepairContext(
                failedSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 1_800
        )

        #expect(package.text.contains(#"TABLE "public"."preseason_match_batch""#))
        #expect(package.text.contains(#"TABLE "public"."preseason_benchmark_run""#))
        #expect(package.text.contains("scheduled_for"))
    }

    @Test func pinnedReplacementSurvivesTinyBudget() {
        let schema = makePreseasonSchema(extraTables: 50)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            repairContext: SQLRepairContext(
                failedSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "most wins last two weeks",
            context: context,
            databaseContext: "",
            maxCharacters: 250
        )

        #expect(package.text.contains(#"TABLE "public"."preseason_match_batch""#))
        #expect(package.pinnedTables.contains("public.preseason_match_batch"))
    }

    @Test func forcedPinnedTableSectionStaysWithinTinyBudget() {
        var columns = [
            column("large_status_events", "id", ordinal: 1),
            column(
                "large_status_events",
                "status",
                type: "text",
                ordinal: 2,
                valueConstraints: [
                    ColumnValueConstraint(
                        kind: .check,
                        values: (0..<20).map { "very_long_allowed_status_value_\($0)" },
                        expression:
                            "CHECK (status = ANY (ARRAY['very_long_allowed_status_value_0', 'very_long_allowed_status_value_1']))"
                    )
                ]
            ),
            column("large_status_events", "created_at", type: "timestamp with time zone", ordinal: 3),
        ]
        for index in 0..<20 {
            columns.append(
                column("large_status_events", "descriptive_payload_column_\(index)", type: "text", ordinal: 10 + index)
            )
        }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "large_status_events",
                    type: .baseTable,
                    columns: columns
                )
            ],
            foreignKeys: []
        )
        let context = SQLGenerationContext(
            mode: .followUp,
            currentSQL: "SELECT * FROM public.large_status_events",
            repairContext: nil
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show the latest status events",
            context: context,
            databaseContext: "",
            maxCharacters: 500
        )

        #expect(package.text.count <= 500)
        #expect(!package.diagnostics.overflowedBudget)
        #expect(package.text.contains(#"TABLE "public"."large_status_events""#))
        #expect(package.pinnedTables.contains("public.large_status_events"))
    }

    @Test func quotedCurrentSQLRelationPinsCanonicalTableName() {
        let schema = makeQuotedSalesSchema(extraTables: 20)
        let context = SQLGenerationContext(
            mode: .followUp,
            currentSQL: #"SELECT id FROM "Sales Data"."Q1 Orders""#,
            repairContext: nil
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show the same orders by status",
            context: context,
            databaseContext: "",
            maxCharacters: 350
        )

        #expect(package.text.contains(#"TABLE "Sales Data"."Q1 Orders""#))
        #expect(package.pinnedTables.contains("Sales Data.Q1 Orders"))
    }

    @Test func packagingDoesNotEmitDomainSpecificWinnerHints() {
        let schema = makeWinningToolSchema(extraTables: 12)
        let context = SQLGenerationContext(
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            conversationMessages: [
                SQLConversationMessage(
                    role: .user,
                    text: "what are tools that are getting the most wins in the last two weeks?"
                )
            ]
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "Probably preseason_tool primary key",
            context: context,
            databaseContext: "",
            maxCharacters: 3_500
        )

        #expect(!package.text.contains("Winner relation:"))
        #expect(!package.text.contains("count non-null"))
        #expect(!package.text.contains(#"Should I define "most wins""#))
    }

    @Test func packagingDoesNotInferWinnerForeignKeysFromQuestionTerms() {
        let schema = makeWinningToolSchema(extraTables: 12, includeNonToolWinnerRelation: true)
        let context = SQLGenerationContext(
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?"
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "Probably preseason_tool primary key",
            context: context,
            databaseContext: "",
            maxCharacters: 3_500
        )

        #expect(!package.text.contains("Winner relation:"))
        #expect(!package.text.contains("count non-null"))
    }

    @Test func primaryTablesAreIncludedIncrementallyWhenFullSectionIsTooLarge() {
        let schema = makeIncrementalPrimarySchema()

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "order customer invoice product",
            context: SQLGenerationContext(),
            databaseContext: "",
            maxCharacters: 450
        )

        #expect(package.text.count <= 450)
        #expect(package.text.contains("Primary tables:"))
        #expect(!package.includedTables.isEmpty)
        #expect(package.includedTables.count < schema.tables.count)
    }

    @Test func missingColumnRelationshipHintShowsJoinToColumnOwner() {
        let schema = makeWinningToolSchema(extraTables: 8)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message: "column tool_a_id is not available from the referenced tables",
            columnName: "tool_a_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL: "SELECT tool_a_id FROM public.preseason_match_evaluation",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_a_id"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 4_500
        )

        #expect(
            package.text.contains(
                #"Column "tool_a_id" lives on "public"."preseason_match_batch", not "public"."preseason_match_evaluation""#
            ))
        #expect(
            package.text.contains(
                #"join "public"."preseason_match_evaluation"."batch_id" -> "public"."preseason_match_batch"."id""#
            ))
    }

    @Test func missingColumnRelationshipHintCanUseTwoHopForeignKeyPath() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        column("orders", "id", ordinal: 1),
                        column("orders", "user_id", ordinal: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        column("users", "id", ordinal: 1),
                        column("users", "account_id", ordinal: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "accounts",
                    type: .baseTable,
                    columns: [
                        column("accounts", "id", ordinal: 1),
                        column("accounts", "plan_name", type: "text", ordinal: 2),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "orders_user_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    sourceColumn: "user_id",
                    targetSchema: "public",
                    targetTable: "users",
                    targetColumn: "id"
                ),
                ForeignKeyInfo(
                    constraintName: "users_account_fkey",
                    sourceSchema: "public",
                    sourceTable: "users",
                    sourceColumn: "account_id",
                    targetSchema: "public",
                    targetTable: "accounts",
                    targetColumn: "id"
                ),
            ]
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "show order account plan names",
            repairContext: SQLRepairContext(
                failedSQL: "SELECT plan_name FROM public.orders",
                diagnostic: DatabaseDiagnostic(
                    kind: .missingColumn,
                    sqlState: "42703",
                    message: "Schema validation failed: column plan_name is not available from the referenced tables.",
                    columnName: "plan_name"
                ),
                forbiddenIdentifiers: ["plan_name"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show order account plan names",
            context: context,
            databaseContext: "",
            maxCharacters: 4_000
        )

        #expect(
            package.text.contains(
                #"join "public"."orders"."user_id" -> "public"."users"."id" then "public"."users"."account_id" -> "public"."accounts"."id""#
            ))
        #expect(package.pinnedTables.contains("public.users"))
        #expect(package.pinnedTables.contains("public.accounts"))
    }

    @Test func widePinnedRepairTableIsCompressedButKeepsRequiredColumns() {
        let schema = makeWideWinningToolSchema(extraTables: 30)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message:
                "Schema validation failed: column tool_id is not available from the referenced tables. Schema validation failed: column createdAt must be quoted as \"createdAt\" on public.preseason_match_evaluation.",
            columnName: "tool_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL:
                    "SELECT DISTINCT winner_id, tool_id FROM public.preseason_match_evaluation WHERE createdAt >= NOW() - INTERVAL '14 days' GROUP BY winner_id, tool_id",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_id"],
                repairConstraints: [.forbiddenUnquotedIdentifier("createdAt")]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 3_400
        )

        #expect(package.text.count <= 3_400)
        #expect(package.text.contains(#"TABLE "public"."preseason_match_evaluation""#))
        #expect(package.text.contains(#""winner_id" uuid NOT NULL"#))
        #expect(package.text.contains(#""createdAt" timestamp with time zone NOT NULL"#))
        #expect(package.text.contains(#"FK "winner_id" -> "public"."preseason_tool"."id""#))
        #expect(package.text.contains(#"TABLE "public"."preseason_tool""#))
        #expect(package.text.contains(#""name" character varying NOT NULL"#))
        #expect(!package.text.contains("raw_response"))
        #expect(!package.text.contains("appendix_json"))
        #expect(!package.text.contains("system_prompt_snapshot"))
    }

    @Test func relationshipHintsAreCappedAndNeverForceOverflow() {
        let schema = makeWideWinningToolSchema(extraTables: 50)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message: "Schema validation failed: column tool_id is not available from the referenced tables.",
            columnName: "tool_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL: "SELECT tool_id FROM public.preseason_match_evaluation",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_id"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 1_700
        )

        #expect(package.text.count <= 1_700)
        #expect(package.text.contains(#"TABLE "public"."preseason_match_evaluation""#))
        #expect(package.text.contains(#""winner_id" uuid NOT NULL"#))
        #expect(package.diagnostics.compressionLevel != .full)
    }

    @Test func schemaDiscoverySearchFindsWinningToolTables() {
        let schema = makeWinningToolSchema(extraTables: 30)
        let tables = SchemaDiscoveryService.search(
            schema: schema,
            queries: ["winning tools last two weeks match evaluation winner_id createdAt"],
            limit: 5
        ).map(\.qualifiedName)

        #expect(tables.contains("public.preseason_match_evaluation"))
        #expect(tables.contains("public.preseason_tool"))
    }

    @Test func schemaRankingAndSearchUseConstrainedValues() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "review_queue",
                    type: .baseTable,
                    columns: [
                        column("review_queue", "id", ordinal: 1),
                        column(
                            "review_queue",
                            "status",
                            type: "text",
                            ordinal: 2,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["approved", "rejected"],
                                    expression: "CHECK (status IN ('approved', 'rejected'))"
                                )
                            ]
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "generic_events",
                    type: .baseTable,
                    columns: [
                        column("generic_events", "id", ordinal: 1),
                        column("generic_events", "status", type: "text", ordinal: 2),
                    ]
                ),
            ],
            foreignKeys: []
        )

        let ranked = SchemaRelevanceRanker.rank(
            schema: schema,
            input: SchemaRankingInput(question: "count approved")
        )
        let searchResults = SchemaDiscoveryService.search(
            schema: schema,
            queries: ["approved"],
            limit: 2
        ).map(\.qualifiedName)

        #expect(ranked.first?.table.qualifiedName == "public.review_queue")
        #expect(searchResults.contains("public.review_queue"))
    }

    @Test func highScoringPrimaryTablesAreNotBlindlyPinned() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        column("customers", "id", ordinal: 1),
                        column("customers", "name", type: "text", ordinal: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        column("orders", "id", ordinal: 1),
                        column("orders", "customer_id", ordinal: 2),
                        column("orders", "created_at", type: "timestamp with time zone", ordinal: 3),
                    ]
                ),
            ],
            foreignKeys: []
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show customers and orders by created_at",
            context: SQLGenerationContext(),
            databaseContext: "",
            maxCharacters: 2_000
        )

        #expect(package.includedTables.contains("public.customers"))
        #expect(package.includedTables.contains("public.orders"))
        #expect(package.pinnedTables.isEmpty)
    }

    @Test func exactDiscoveryTableHintsArePinnedButCatalogIsNotRenderedInFinalPrompt() {
        let schema = makePreseasonSchema(extraTables: 30)
        let context = SQLGenerationContext(
            schemaSearchQueries: ["public.preseason_match_batch"]
        )

        let bundle = SQLPromptBuilder.promptBundle(
            question: "show match batches",
            schema: schema,
            context: context,
            maxSchemaCharacters: 1_500
        )

        #expect(bundle.schemaPackage.pinnedTables.contains("public.preseason_match_batch"))
        #expect(bundle.prompt.contains(#"TABLE "public"."preseason_match_batch""#))
        #expect(!bundle.prompt.contains("Catalog tables:"))
    }

    @Test func tableCardsRenderOwnershipTableIDsAndQuotedOnlyMarkers() {
        let schema = makeQuotedSalesSchema(extraTables: 0)

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show orders by status",
            context: SQLGenerationContext(schemaSearchQueries: ["Sales Data.Q1 Orders"]),
            databaseContext: "",
            maxCharacters: 1_500
        )

        #expect(package.text.contains(#"TABLE "Sales Data"."Q1 Orders" [table_id: Sales Data.Q1 Orders] [QUOTED_ONLY]"#))
        #expect(package.text.contains("Ownership: listed columns belong to table_id Sales Data.Q1 Orders"))
        #expect(package.text.contains(#""id" integer NOT NULL"#))
    }

    @Test func compositeForeignKeysAreGroupedInTableCardsAndRelationships() {
        let schema = makeCompositeForeignKeySchema()

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show order product allocations",
            context: SQLGenerationContext(schemaSearchQueries: ["public.order_allocations"]),
            databaseContext: "",
            maxCharacters: 4_000
        )

        #expect(
            package.text.contains(
                #"FK ("order_id", "product_id") -> "public"."order_products"("order_id", "product_id")"#
            ))
        #expect(
            package.text.contains(
                #"FK "public"."order_allocations"("order_id", "product_id") -> "public"."order_products"("order_id", "product_id")"#
            ))
    }

    @Test func telemetryLogRecordsPromptPackagingDiagnostics() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = GenerationLog(directory: dir)
        let telemetry = PromptTelemetry(
            phase: "initial",
            estimatedTokens: 42,
            estimatedEnvelopeTokens: 72,
            selectedTables: ["public.orders"],
            pinnedTables: ["public.customers"],
            scoreReasons: ["public.orders": ["table name matches request"]],
            validationIssueIDs: ["42703"],
            canonicalizationFixes: ["quote:createdAt"],
            callCount: 2,
            stopReason: "success"
        )

        await log.append(prompt: "prompt", outcome: "ok", durationMs: 7, telemetry: telemetry)

        let text = try String(
            contentsOf: dir.appendingPathComponent("generation.log"),
            encoding: .utf8
        )
        #expect(text.contains("--- telemetry ---"))
        #expect(text.contains(#""phase":"initial""#))
        #expect(text.contains(#""estimatedEnvelopeTokens":72"#))
        #expect(text.contains(#""selectedTables":["public.orders"]"#))
        #expect(text.contains(#""validationIssueIDs":["42703"]"#))
        #expect(text.contains(#""canonicalizationFixes":["quote:createdAt"]"#))
        #expect(text.contains(#""callCount":2"#))
        #expect(text.contains(#""stopReason":"success""#))
    }

    @Test func syntheticSchemasRetrieveRelevantTablesWithoutWinsTuning() {
        let cases: [(schema: DatabaseSchema, question: String, expected: String)] = [
            (
                makeSyntheticSchema(
                    tables: [
                        ("customers", ["id", "email", "created_at"]),
                        ("orders", ["id", "customer_id", "total_cents", "created_at"]),
                        ("products", ["id", "sku", "name"]),
                    ],
                    foreignKeys: [
                        ("orders_customer_fkey", "orders", "customer_id", "customers", "id")
                    ]
                ),
                "which customers spent the most in recent orders",
                "public.orders"
            ),
            (
                makeSyntheticSchema(
                    tables: [
                        ("support_tickets", ["id", "customer_id", "priority", "opened_at"]),
                        ("ticket_comments", ["id", "ticket_id", "body", "created_at"]),
                        ("agents", ["id", "name"]),
                    ],
                    foreignKeys: [
                        ("ticket_comments_ticket_fkey", "ticket_comments", "ticket_id", "support_tickets", "id")
                    ]
                ),
                "count high priority support tickets opened this week",
                "public.support_tickets"
            ),
            (
                makeSyntheticSchema(
                    tables: [
                        ("subscriptions", ["id", "account_id", "status", "started_at"]),
                        ("subscription_invoices", ["id", "subscription_id", "amount_cents", "created_at"]),
                        ("accounts", ["id", "name"]),
                    ],
                    foreignKeys: [
                        ("invoices_subscription_fkey", "subscription_invoices", "subscription_id", "subscriptions", "id")
                    ]
                ),
                "total subscription invoice amount by active subscription",
                "public.subscription_invoices"
            ),
            (
                makeSyntheticSchema(
                    tables: [
                        ("devices", ["id", "serial_number", "site_id"]),
                        ("sensor_readings", ["id", "device_id", "temperature_celsius", "recorded_at"]),
                        ("sites", ["id", "name"]),
                    ],
                    foreignKeys: [
                        ("sensor_readings_device_fkey", "sensor_readings", "device_id", "devices", "id")
                    ]
                ),
                "average device temperature from sensor readings yesterday",
                "public.sensor_readings"
            ),
        ]

        for entry in cases {
            let package = SchemaPromptPackager.package(
                schema: entry.schema,
                question: entry.question,
                context: SQLGenerationContext(),
                databaseContext: "",
                maxCharacters: 3_500
            )
            #expect(package.includedTables.contains(entry.expected))
        }
    }

    private func makeIncrementalPrimarySchema() -> DatabaseSchema {
        let tableNames = ["customers", "invoices", "orders", "products"]
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tableNames.map { name in
                TableInfo(
                    schema: "public",
                    name: name,
                    type: .baseTable,
                    columns: [
                        column(name, "id", ordinal: 1),
                        column(name, "name", type: "text", ordinal: 2),
                        column(name, "status", type: "text", ordinal: 3),
                        column(name, "created_at", type: "timestamp with time zone", ordinal: 4),
                        column(name, "description", type: "text", ordinal: 5),
                    ]
                )
            },
            foreignKeys: []
        )
    }

    private func makeCompositeForeignKeySchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "order_products",
                    type: .baseTable,
                    columns: [
                        column("order_products", "order_id", ordinal: 1),
                        column("order_products", "product_id", ordinal: 2),
                        column("order_products", "quantity", type: "integer", ordinal: 3),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "order_allocations",
                    type: .baseTable,
                    columns: [
                        column("order_allocations", "id", ordinal: 1),
                        column("order_allocations", "order_id", ordinal: 2),
                        column("order_allocations", "product_id", ordinal: 3),
                        column("order_allocations", "warehouse_id", ordinal: 4),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "order_allocations_order_product_fkey",
                    sourceSchema: "public",
                    sourceTable: "order_allocations",
                    sourceColumn: "order_id",
                    targetSchema: "public",
                    targetTable: "order_products",
                    targetColumn: "order_id"
                ),
                ForeignKeyInfo(
                    constraintName: "order_allocations_order_product_fkey",
                    sourceSchema: "public",
                    sourceTable: "order_allocations",
                    sourceColumn: "product_id",
                    targetSchema: "public",
                    targetTable: "order_products",
                    targetColumn: "product_id"
                ),
            ]
        )
    }

    private func makeSyntheticSchema(
        tables: [(name: String, columns: [String])],
        foreignKeys: [(name: String, sourceTable: String, sourceColumn: String, targetTable: String, targetColumn: String)]
    ) -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables.map { table in
                TableInfo(
                    schema: "public",
                    name: table.name,
                    type: .baseTable,
                    columns: table.columns.enumerated().map { index, name in
                        let type =
                            name.hasSuffix("_at") || name.contains("date")
                            ? "timestamp with time zone"
                            : (name.contains("amount") || name.contains("temperature") ? "integer" : "uuid")
                        return column(table.name, name, type: type, ordinal: index + 1)
                    }
                )
            },
            foreignKeys: foreignKeys.map {
                ForeignKeyInfo(
                    constraintName: $0.name,
                    sourceSchema: "public",
                    sourceTable: $0.sourceTable,
                    sourceColumn: $0.sourceColumn,
                    targetSchema: "public",
                    targetTable: $0.targetTable,
                    targetColumn: $0.targetColumn
                )
            }
        )
    }

    private func makePreseasonSchema(extraTables: Int) -> DatabaseSchema {
        var tables = [
            TableInfo(
                schema: "public",
                name: "preseason_benchmark_run",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_benchmark_run",
                        name: "id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_benchmark_run",
                        name: "scheduled_for",
                        dataType: "timestamp with time zone",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "preseason_match_batch",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "benchmark_run_id",
                        dataType: "uuid",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "tool_a_id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 3
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "tool_b_id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 4
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "completed_evaluations",
                        dataType: "integer",
                        isNullable: false,
                        ordinalPosition: 5
                    ),
                ]
            ),
        ]

        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_table_\(index)",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "unrelated_table_\(index)",
                            name: "id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                ))
        }

        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "match_batch_run_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_batch",
                    sourceColumn: "benchmark_run_id",
                    targetSchema: "public",
                    targetTable: "preseason_benchmark_run",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeQuotedSalesSchema(extraTables: Int) -> DatabaseSchema {
        var tables = [
            TableInfo(
                schema: "Sales Data",
                name: "Q1 Orders",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "Sales Data",
                        tableName: "Q1 Orders",
                        name: "id",
                        dataType: "integer",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "Sales Data",
                        tableName: "Q1 Orders",
                        name: "status",
                        dataType: "text",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                ]
            )
        ]
        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_sales_table_\(index)",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "unrelated_sales_table_\(index)",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                ))
        }
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "Sales Data"), SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: []
        )
    }

    private func makeWinningToolSchema(
        extraTables: Int,
        includeNonToolWinnerRelation: Bool = false
    ) -> DatabaseSchema {
        var tables = [
            TableInfo(
                schema: "public",
                name: "preseason_match_evaluation",
                type: .baseTable,
                columns: [
                    column("preseason_match_evaluation", "id", ordinal: 1),
                    column("preseason_match_evaluation", "batch_id", ordinal: 2),
                    column("preseason_match_evaluation", "winner_id", ordinal: 3),
                    column(
                        "preseason_match_evaluation",
                        "winner_decision",
                        type: "user-defined",
                        ordinal: 4,
                        valueConstraints: [
                            ColumnValueConstraint(
                                kind: .enumValues,
                                values: ["tool_a", "tool_b", "tie"]
                            )
                        ]
                    ),
                    column(
                        "preseason_match_evaluation",
                        "createdAt",
                        type: "timestamp with time zone",
                        ordinal: 5
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
                ]
            ),
        ]

        var foreignKeys = [
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

        if includeNonToolWinnerRelation {
            tables[0].columns.append(
                column("preseason_match_evaluation", "winner_scorekeeper_id", ordinal: 6)
            )
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "preseason_scorekeeper",
                    type: .baseTable,
                    columns: [
                        column("preseason_scorekeeper", "id", ordinal: 1),
                        column(
                            "preseason_scorekeeper",
                            "name",
                            type: "character varying",
                            ordinal: 2
                        ),
                    ]
                ))
            foreignKeys.append(
                ForeignKeyInfo(
                    constraintName: "match_evaluation_scorekeeper_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "winner_scorekeeper_id",
                    targetSchema: "public",
                    targetTable: "preseason_scorekeeper",
                    targetColumn: "id"
                ))
        }

        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_tool_table_\(index)",
                    type: .baseTable,
                    columns: [
                        column("unrelated_tool_table_\(index)", "id", ordinal: 1)
                    ]
                ))
        }

        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: foreignKeys
        )
    }

    private func makeWideWinningToolSchema(extraTables: Int) -> DatabaseSchema {
        var schema = makeWinningToolSchema(extraTables: extraTables)
        guard let index = schema.tables.firstIndex(where: {
            $0.qualifiedName == "public.preseason_match_evaluation"
        }) else { return schema }
        let extraColumns = [
            ("raw_response", "text"),
            ("appendix_json", "jsonb"),
            ("appendix_raw", "text"),
            ("system_prompt_snapshot", "text"),
            ("rendered_user_prompt", "text"),
        ] + (0..<30).map { ("debug_payload_\($0)", "jsonb") }
        for (offset, extraColumn) in extraColumns.enumerated() {
            schema.tables[index].columns.append(
                column(
                    "preseason_match_evaluation",
                    extraColumn.0,
                    type: extraColumn.1,
                    ordinal: 100 + offset
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
}
