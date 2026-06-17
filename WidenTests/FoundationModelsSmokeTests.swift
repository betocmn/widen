import Foundation
import Testing

@testable import WidenKit

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Real on-device generation smoke test. Requires Apple Intelligence to be
/// enabled; run with `make test-fm`.
private let fmTestEnabled = ProcessInfo.processInfo.environment["WIDEN_FM_TEST"] != nil

@Suite("Foundation Models smoke", .enabled(if: fmTestEnabled))
struct FoundationModelsSmokeTests {
    private func makeTinySchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "email",
                            dataType: "text", isNullable: false, ordinalPosition: 2),
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "created_at",
                            dataType: "timestamp with time zone", isNullable: false,
                            ordinalPosition: 3),
                    ]),
            ],
            foreignKeys: []
        )
    }

    private func makeOrdersSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "orders", type: .baseTable,
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
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "status",
                            dataType: "text", isNullable: false, ordinalPosition: 4),
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "created_at",
                            dataType: "timestamp with time zone", isNullable: false,
                            ordinalPosition: 5),
                    ]),
            ],
            foreignKeys: []
        )
    }

    @Test(.timeLimit(.minutes(3)))
    func modelIsAvailableAndGeneratesValidSQL() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            print("Foundation Models availability: \(model.availability)")
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            let generator = FoundationModelsSQLGenerator()
            let result = try await generator.generateSQL(
                question: "Show me the 5 most recent users.",
                schema: makeTinySchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100)
            )
            print("Generated SQL: \(result.sql)")
            print("Explanation: \(result.explanation)")
            print("Confidence: \(result.confidence), risk: \(result.riskLevel.rawValue)")

            #expect(!result.sql.isEmpty)
            #expect(result.sql.lowercased().contains("users"))
            let validation = SQLSafetyValidator.validate(result.sql)
            #expect(validation.isValid, "generated SQL failed validation: \(validation.errors)")
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test(.timeLimit(.minutes(3)))
    func modelGeneratesValidAverageOrdersPerDaySQL() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            let generator = FoundationModelsSQLGenerator()
            let result = try await generator.generateSQL(
                question: "How many orders are we getting in average per day?",
                schema: makeOrdersSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100)
            )
            print("Generated average orders SQL: \(result.sql)")

            let validation = SQLSafetyValidator.validate(result.sql)
            #expect(validation.isValid, "generated SQL failed validation: \(validation.errors)")
            let lowercasedSQL = result.sql.lowercased()
            #expect(lowercasedSQL.contains("orders"))
            #expect(lowercasedSQL.contains("created_at"))
            #expect(!lowercasedSQL.contains("avg(count("))
            #expect(!lowercasedSQL.contains("over ("))
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test(.timeLimit(.minutes(2)))
    func modelGeneratesUsableSessionTitle() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            let generator = FoundationModelsTitleGenerator()
            let raw = try await generator.generateTitle(
                for: "Which users have spent the most money this year?")
            print("Generated session title: \(raw)")

            let title = SessionTitleFallback.sanitize(raw)
            #expect(title?.isEmpty == false)
            #expect((title?.count ?? 0) <= 60)
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test(.timeLimit(.minutes(2)))
    func modelExtractsConnectionDetailsFromPastedURL() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            let parser = FoundationModelsConnectionParser()
            let details = try await parser.parse(
                """
                Hey, here are the staging credentials:
                DATABASE_URL=postgres://widen_app:s3cret@db.staging.internal:6543/analytics?sslmode=require
                """)
            print("Extracted details: \(details)")

            #expect(details.host == "db.staging.internal")
            #expect(details.port == 6543)
            #expect(details.database == "analytics")
            #expect(details.username == "widen_app")
            #expect(details.password == "s3cret")
            #expect(details.sslMode == .require)
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test(.timeLimit(.minutes(2)))
    func modelExtractsConnectionDetailsFromEnvLines() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            let parser = FoundationModelsConnectionParser()
            let details = try await parser.parse(
                """
                POSTGRES_HOST=10.1.2.3
                POSTGRES_PORT=5432
                POSTGRES_DB=warehouse
                POSTGRES_USER=etl
                POSTGRES_PASSWORD=hunter2
                """)
            print("Extracted details: \(details)")

            #expect(details.host == "10.1.2.3")
            #expect(details.port == 5432)
            #expect(details.database == "warehouse")
            #expect(details.username == "etl")
            #expect(details.password == "hunter2")
            // SSL is never mentioned, so the parser must not guess a mode.
            #expect(details.sslMode == nil)
            #expect(details.name == nil)
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test(.timeLimit(.minutes(2)))
    func extractsSupabasePoolerUsernameVerbatim() async throws {
        #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                Issue.record("Model unavailable: \(model.availability)")
                return
            }

            // The pooler username is `postgres.<project-ref>`; the model alone
            // truncates it at the dot, so the deterministic URL override must
            // restore the full value.
            let parser = FoundationModelsConnectionParser()
            let details = try await parser.parse(
                "postgresql://postgres.flzyzmgitfdwaunkugxs:wEb6OkcHF5XBzN8i@aws-1-ap-southeast-2.pooler.supabase.com:6543/postgres"
            )
            print("Extracted details: \(details)")

            #expect(details.username == "postgres.flzyzmgitfdwaunkugxs")
            #expect(details.password == "wEb6OkcHF5XBzN8i")
            #expect(details.host == "aws-1-ap-southeast-2.pooler.supabase.com")
            #expect(details.port == 6543)
            #expect(details.database == "postgres")
        #else
            Issue.record("FoundationModels is not available at compile time")
        #endif
    }

    @Test func mockGeneratorReturnsSafeConstantQuery() async throws {
        let result = try await MockSQLGenerator().generateSQL(
            question: "anything",
            schema: makeTinySchema(),
            config: SQLGenerationConfig()
        )
        #expect(result.sql == "SELECT 1 AS test_value")
        #expect(SQLSafetyValidator.validate(result.sql).isValid)
    }
}
