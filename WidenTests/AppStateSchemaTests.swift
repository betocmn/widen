import Foundation
import Testing

@testable import WidenKit

@Suite("AppState schema selection")
@MainActor
struct AppStateSchemaTests {
    private func makeState() -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir)
        )
        return (state, dir)
    }

    private func makeSchema(schemas: [String]) -> DatabaseSchema {
        DatabaseSchema(
            schemas: schemas.map(SchemaInfo.init(name:)),
            tables: schemas.flatMap { schema in
                [
                    TableInfo(
                        schema: schema, name: "users", type: .baseTable,
                        columns: [
                            ColumnInfo(
                                tableSchema: schema, tableName: "users", name: "id",
                                dataType: "integer", isNullable: false, ordinalPosition: 1)
                        ]),
                    TableInfo(
                        schema: schema, name: "orders", type: .baseTable,
                        columns: [
                            ColumnInfo(
                                tableSchema: schema, tableName: "orders", name: "user_id",
                                dataType: "integer", isNullable: false, ordinalPosition: 1)
                        ]),
                ]
            },
            foreignKeys: schemas.map { schema in
                ForeignKeyInfo(
                    constraintName: "orders_user_id_fkey",
                    sourceSchema: schema, sourceTable: "orders", sourceColumn: "user_id",
                    targetSchema: schema, targetTable: "users", targetColumn: "id")
            }
        )
    }

    private func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: "WidenSelectedSchemaNames")
    }

    @Test func currentSchemaFallsBackToPublicThenFirst() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()

        #expect(state.currentSchemaName(for: id) == nil)

        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])
        #expect(state.currentSchemaName(for: id) == "public")

        state.schemas[id] = makeSchema(schemas: ["analytics", "sales"])
        #expect(state.currentSchemaName(for: id) == "analytics")
    }

    @Test func selectedSchemaWinsWhileItExists() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])

        state.selectSchema("analytics", for: id)
        #expect(state.currentSchemaName(for: id) == "analytics")

        // A refresh that drops the chosen schema silently falls back.
        state.schemas[id] = makeSchema(schemas: ["public", "sales"])
        #expect(state.currentSchemaName(for: id) == "public")
    }

    @Test func promptSchemaIsScopedToOpenSchema() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])
        state.selectSchema("analytics", for: id)

        let prompt = state.promptSchema(for: id)

        #expect(prompt?.schemas.map(\.name) == ["analytics"])
        #expect(prompt?.tables.allSatisfy { $0.schema == "analytics" } == true)
        #expect(prompt?.tables.count == 2)
        #expect(prompt?.foreignKeys.count == 1)
        #expect(prompt?.foreignKeys.allSatisfy { $0.sourceSchema == "analytics" } == true)
    }

    @Test func filteredDropsCrossSchemaForeignKeys() {
        var schema = makeSchema(schemas: ["public", "analytics"])
        schema.foreignKeys.append(
            ForeignKeyInfo(
                constraintName: "events_user_id_fkey",
                sourceSchema: "analytics", sourceTable: "events", sourceColumn: "user_id",
                targetSchema: "public", targetTable: "users", targetColumn: "id"))

        let filtered = schema.filtered(toSchema: "analytics")

        #expect(filtered.foreignKeys.count == 1)
        #expect(filtered.foreignKeys.first?.constraintName == "orders_user_id_fkey")
    }

    @Test func deleteConnectionPrunesSchemaSelection() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(id: UUID())
        state.connections = [config]
        state.selectSchema("analytics", for: config.id)

        state.deleteConnection(config.id)

        #expect(state.selectedSchemaNames[config.id] == nil)
    }
}
