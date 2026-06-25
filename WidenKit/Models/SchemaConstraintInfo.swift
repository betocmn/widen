import Foundation

public enum SchemaKeyConstraintKind: String, Codable, Equatable, Hashable, Sendable {
    case primaryKey = "primary_key"
    case unique
}

public struct SchemaKeyConstraintInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(schema).\(table).\(constraintName)" }
    public var constraintName: String
    public var schema: String
    public var table: String
    public var kind: SchemaKeyConstraintKind
    public var columns: [String]

    public init(
        constraintName: String,
        schema: String,
        table: String,
        kind: SchemaKeyConstraintKind,
        columns: [String]
    ) {
        self.constraintName = constraintName
        self.schema = schema
        self.table = table
        self.kind = kind
        self.columns = columns
    }
}

public struct SchemaForeignKeyColumnPair: Codable, Equatable, Hashable, Sendable {
    public var sourceColumn: String
    public var targetColumn: String
    public var ordinalPosition: Int

    public init(sourceColumn: String, targetColumn: String, ordinalPosition: Int) {
        self.sourceColumn = sourceColumn
        self.targetColumn = targetColumn
        self.ordinalPosition = ordinalPosition
    }
}

public struct SchemaForeignKeyConstraintInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(constraintName):\(sourceSchema).\(sourceTable)->\(targetSchema).\(targetTable)" }
    public var constraintName: String
    public var sourceSchema: String
    public var sourceTable: String
    public var targetSchema: String
    public var targetTable: String
    public var columnPairs: [SchemaForeignKeyColumnPair]

    public init(
        constraintName: String,
        sourceSchema: String,
        sourceTable: String,
        targetSchema: String,
        targetTable: String,
        columnPairs: [SchemaForeignKeyColumnPair]
    ) {
        self.constraintName = constraintName
        self.sourceSchema = sourceSchema
        self.sourceTable = sourceTable
        self.targetSchema = targetSchema
        self.targetTable = targetTable
        self.columnPairs = columnPairs.sorted {
            if $0.ordinalPosition == $1.ordinalPosition {
                if $0.sourceColumn == $1.sourceColumn {
                    return $0.targetColumn < $1.targetColumn
                }
                return $0.sourceColumn < $1.sourceColumn
            }
            return $0.ordinalPosition < $1.ordinalPosition
        }
    }
}
