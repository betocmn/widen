import Foundation

public struct SchemaInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// A snapshot of the connected database's structure, used by both the sidebar
/// browser and the SQL-generation prompt.
public struct DatabaseSchema: Codable, Equatable, Sendable {
    public var schemas: [SchemaInfo]
    public var tables: [TableInfo]
    public var foreignKeys: [ForeignKeyInfo]
    public var loadedAt: Date

    public init(
        schemas: [SchemaInfo] = [],
        tables: [TableInfo] = [],
        foreignKeys: [ForeignKeyInfo] = [],
        loadedAt: Date = Date()
    ) {
        self.schemas = schemas
        self.tables = tables
        self.foreignKeys = foreignKeys
        self.loadedAt = loadedAt
    }

    /// A copy narrowed to one schema: its tables, and only the foreign keys
    /// whose both ends live in it. Used to scope the generation prompt and
    /// the schema browser to the schema the user has open.
    public func filtered(toSchema name: String) -> DatabaseSchema {
        DatabaseSchema(
            schemas: schemas.filter { $0.name == name },
            tables: tables.filter { $0.schema == name },
            foreignKeys: foreignKeys.filter {
                $0.sourceSchema == name && $0.targetSchema == name
            },
            loadedAt: loadedAt
        )
    }

    public var singleSchemaName: String? {
        let names = Set(schemas.map(\.name) + tables.map(\.schema))
        return names.count == 1 ? names.first : nil
    }

    public func containsSchema(named name: String) -> Bool {
        schemas.contains { $0.name == name } || tables.contains { $0.schema == name }
    }
}
