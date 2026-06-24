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
    public var foreignKeyConstraints: [SchemaForeignKeyConstraintInfo]
    public var loadedAt: Date

    public init(
        schemas: [SchemaInfo] = [],
        tables: [TableInfo] = [],
        foreignKeys: [ForeignKeyInfo] = [],
        foreignKeyConstraints: [SchemaForeignKeyConstraintInfo] = [],
        loadedAt: Date = Date()
    ) {
        self.schemas = schemas
        self.tables = tables
        self.foreignKeys = foreignKeys
        self.foreignKeyConstraints = foreignKeyConstraints
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
            foreignKeyConstraints: foreignKeyConstraints.filter {
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

    private enum CodingKeys: String, CodingKey {
        case schemas
        case tables
        case foreignKeys
        case foreignKeyConstraints
        case loadedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemas = try container.decodeIfPresent([SchemaInfo].self, forKey: .schemas) ?? []
        tables = try container.decodeIfPresent([TableInfo].self, forKey: .tables) ?? []
        foreignKeys = try container.decodeIfPresent([ForeignKeyInfo].self, forKey: .foreignKeys) ?? []
        foreignKeyConstraints = try container.decodeIfPresent(
            [SchemaForeignKeyConstraintInfo].self,
            forKey: .foreignKeyConstraints
        ) ?? DatabaseSchema.groupForeignKeys(foreignKeys)
        loadedAt = try container.decodeIfPresent(Date.self, forKey: .loadedAt) ?? Date.distantPast
    }

    public static func groupForeignKeys(
        _ foreignKeys: [ForeignKeyInfo]
    ) -> [SchemaForeignKeyConstraintInfo] {
        struct GroupKey: Hashable {
            var constraintName: String
            var sourceSchema: String
            var sourceTable: String
            var targetSchema: String
            var targetTable: String
        }

        let grouped = Dictionary(grouping: foreignKeys) {
            GroupKey(
                constraintName: $0.constraintName,
                sourceSchema: $0.sourceSchema,
                sourceTable: $0.sourceTable,
                targetSchema: $0.targetSchema,
                targetTable: $0.targetTable
            )
        }

        return grouped.map { key, rows in
            SchemaForeignKeyConstraintInfo(
                constraintName: key.constraintName,
                sourceSchema: key.sourceSchema,
                sourceTable: key.sourceTable,
                targetSchema: key.targetSchema,
                targetTable: key.targetTable,
                columnPairs: rows.map {
                    SchemaForeignKeyColumnPair(
                        sourceColumn: $0.sourceColumn,
                        targetColumn: $0.targetColumn,
                        ordinalPosition: $0.ordinalPosition
                    )
                }
            )
        }
        .sorted {
            if $0.sourceSchema == $1.sourceSchema {
                if $0.sourceTable == $1.sourceTable {
                    if $0.constraintName == $1.constraintName {
                        if $0.targetSchema == $1.targetSchema {
                            return $0.targetTable < $1.targetTable
                        }
                        return $0.targetSchema < $1.targetSchema
                    }
                    return $0.constraintName < $1.constraintName
                }
                return $0.sourceTable < $1.sourceTable
            }
            return $0.sourceSchema < $1.sourceSchema
        }
    }
}
