import Foundation
import Testing

@testable import WidenKit

@Suite("SchemaStore")
struct SchemaStoreTests {
    private func makeTempStore() -> (SchemaStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        return (SchemaStore(directory: dir), dir)
    }

    private func makeSchema(loadedAt: Date = Date(timeIntervalSince1970: 1_750_000_000))
        -> DatabaseSchema
    {
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
            foreignKeys: [],
            loadedAt: loadedAt
        )
    }

    @Test func loadFromEmptyDirectoryReturnsNoSchemas() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try store.load().isEmpty)
    }

    @Test func saveAndLoadRoundTripPreservesSchemasByConnectionID() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstID = UUID()
        let secondID = UUID()
        let first = makeSchema()
        let second = makeSchema(loadedAt: Date(timeIntervalSince1970: 1_750_000_100))

        try store.save([firstID: first, secondID: second])
        let loaded = try store.load()

        #expect(loaded.count == 2)
        #expect(loaded[firstID] == first)
        #expect(loaded[secondID] == second)
    }

    @Test func saveOverwritesPreviousContents() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstID = UUID()
        let secondID = UUID()

        try store.save([firstID: makeSchema()])
        try store.save([secondID: makeSchema()])
        let loaded = try store.load()

        #expect(loaded[firstID] == nil)
        #expect(loaded[secondID] != nil)
        #expect(loaded.count == 1)
    }

    @Test func corruptedFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test func loadIgnoresInvalidUUIDKeys() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let schema = makeSchema()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = try encoder.encode([id.uuidString: schema, "not-a-uuid": schema])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try raw.write(to: store.fileURL, options: .atomic)

        let loaded = try store.load()

        #expect(loaded == [id: schema])
    }

    @Test func legacyColumnWithoutValueConstraintsDecodes() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let json = """
            {
              "\(id.uuidString)": {
                "schemas": [{"name": "public"}],
                "tables": [{
                  "schema": "public",
                  "name": "users",
                  "type": "BASE TABLE",
                  "columns": [{
                    "tableSchema": "public",
                    "tableName": "users",
                    "name": "id",
                    "dataType": "integer",
                    "isNullable": false,
                    "ordinalPosition": 1
                  }]
                }],
                "foreignKeys": [],
                "loadedAt": "2025-06-15T15:06:40Z"
              }
            }
            """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL, options: .atomic)

        let loaded = try store.load()

        #expect(loaded[id]?.tables.first?.columns.first?.valueConstraints == nil)
    }

    @Test func legacySchemaWithoutCommentsOrConstraintsDecodesDefaults() throws {
        let json = """
            {
              "schemas": [{"name": "public"}],
              "tables": [{
                "schema": "public",
                "name": "users",
                "type": "BASE TABLE",
                "columns": [{
                  "tableSchema": "public",
                  "tableName": "users",
                  "name": "id",
                  "dataType": "integer",
                  "isNullable": false,
                  "ordinalPosition": 1
                }]
              }],
              "foreignKeys": [{
                "constraintName": "orders_user_id_fkey",
                "sourceSchema": "public",
                "sourceTable": "orders",
                "sourceColumn": "user_id",
                "targetSchema": "public",
                "targetTable": "users",
                "targetColumn": "id"
              }],
              "loadedAt": "2025-06-15T15:06:40Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let schema = try decoder.decode(DatabaseSchema.self, from: Data(json.utf8))

        #expect(schema.tables.first?.comment == nil)
        #expect(schema.tables.first?.keyConstraints == [])
        #expect(schema.tables.first?.columns.first?.comment == nil)
        #expect(schema.foreignKeys.first?.ordinalPosition == 1)
        #expect(schema.foreignKeyConstraints.count == 1)
        #expect(schema.foreignKeyConstraints.first?.columnPairs.first?.sourceColumn == "user_id")
    }

    @Test func legacyCompositeForeignKeyRowsPreserveStoredOrder() throws {
        let json = """
            {
              "schemas": [{"name": "public"}],
              "tables": [],
              "foreignKeys": [{
                "constraintName": "child_parent_fkey",
                "sourceSchema": "public",
                "sourceTable": "child",
                "sourceColumn": "z_child_id",
                "targetSchema": "public",
                "targetTable": "parent",
                "targetColumn": "z_parent_id"
              }, {
                "constraintName": "child_parent_fkey",
                "sourceSchema": "public",
                "sourceTable": "child",
                "sourceColumn": "a_child_id",
                "targetSchema": "public",
                "targetTable": "parent",
                "targetColumn": "a_parent_id"
              }],
              "loadedAt": "2025-06-15T15:06:40Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let schema = try decoder.decode(DatabaseSchema.self, from: Data(json.utf8))
        let pairs = try #require(schema.foreignKeyConstraints.first?.columnPairs)

        #expect(pairs.map(\.sourceColumn) == ["z_child_id", "a_child_id"])
        #expect(pairs.map(\.ordinalPosition) == [1, 2])
    }

    @Test func schemaMetadataRoundTripPreservesCommentsAndGroupedConstraints() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    comment: "Customer purchases",
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "id",
                            comment: "Primary identifier",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ],
                    keyConstraints: [
                        SchemaKeyConstraintInfo(
                            constraintName: "orders_pkey",
                            schema: "public",
                            table: "orders",
                            kind: .primaryKey,
                            columns: ["id"]
                        )
                    ]
                )
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "orders_customer_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    sourceColumn: "customer_id",
                    targetSchema: "public",
                    targetTable: "customers",
                    targetColumn: "id",
                    ordinalPosition: 1
                )
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "orders_customer_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    targetSchema: "public",
                    targetTable: "customers",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "customer_id",
                            targetColumn: "id",
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            loadedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(DatabaseSchema.self, from: encoder.encode(schema))

        #expect(decoded == schema)
    }
}
