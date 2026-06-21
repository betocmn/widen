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
}
