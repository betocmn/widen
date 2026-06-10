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
