import Testing

@testable import WidenKit

@Suite("WidenKit smoke")
@MainActor
struct WidenKitSmokeTests {
    @Test func appStateInitialStatus() async throws {
        let state = AppState()
        #expect(state.connectionStatus == .notConnected)
    }

    @Test func refreshSchemaClearsStaleSchemaWhenIntrospectionFails() async {
        let state = AppState()
        state.connectionStatus = .connected
        state.schema = makeSchema()
        state.schemaVM.selectedTableID = "public.users"

        await state.refreshSchema()

        #expect(state.schema == nil)
        #expect(state.schemaVM.selectedTableID == nil)
        #expect(state.errorBanner != nil)
        #expect(state.isLoadingSchema == false)
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
}

@Suite("SchemaIntrospectionService")
struct SchemaIntrospectionServiceTests {
    @Test func foreignKeySQLUsesReferencedConstraintJoin() {
        let sql = SchemaIntrospectionService.foreignKeysSQL
        #expect(sql.contains("information_schema.referential_constraints"))
        #expect(sql.contains("rc.unique_constraint_schema"))
        #expect(sql.contains("ccu.ordinal_position = kcu.position_in_unique_constraint"))
        #expect(!sql.contains("ccu.table_schema = tc.table_schema"))
    }
}
