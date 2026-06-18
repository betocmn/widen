import Foundation

public enum ColumnValueConstraintKind: String, Codable, Equatable, Hashable, Sendable {
    case enumValues = "enum_values"
    case check
}

public struct ColumnValueConstraint: Codable, Equatable, Hashable, Sendable {
    public var kind: ColumnValueConstraintKind
    public var values: [String]
    public var expression: String?
    public var constraintName: String?

    public init(
        kind: ColumnValueConstraintKind,
        values: [String] = [],
        expression: String? = nil,
        constraintName: String? = nil
    ) {
        self.kind = kind
        self.values = values
        self.expression = expression
        self.constraintName = constraintName
    }
}

public struct ColumnInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(tableSchema).\(tableName).\(name)" }
    public var tableSchema: String
    public var tableName: String
    public var name: String
    public var dataType: String
    public var udtSchema: String?
    public var udtName: String?
    public var isNullable: Bool
    public var ordinalPosition: Int
    public var valueConstraints: [ColumnValueConstraint]?

    public init(
        tableSchema: String,
        tableName: String,
        name: String,
        dataType: String,
        udtSchema: String? = nil,
        udtName: String? = nil,
        isNullable: Bool,
        ordinalPosition: Int,
        valueConstraints: [ColumnValueConstraint]? = nil
    ) {
        self.tableSchema = tableSchema
        self.tableName = tableName
        self.name = name
        self.dataType = dataType
        self.udtSchema = udtSchema
        self.udtName = udtName
        self.isNullable = isNullable
        self.ordinalPosition = ordinalPosition
        self.valueConstraints = valueConstraints
    }
}
