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
    public var comment: String?
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
        comment: String? = nil,
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
        self.comment = comment
        self.dataType = dataType
        self.udtSchema = udtSchema
        self.udtName = udtName
        self.isNullable = isNullable
        self.ordinalPosition = ordinalPosition
        self.valueConstraints = valueConstraints
    }

    private enum CodingKeys: String, CodingKey {
        case tableSchema
        case tableName
        case name
        case comment
        case dataType
        case udtSchema
        case udtName
        case isNullable
        case ordinalPosition
        case valueConstraints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tableSchema = try container.decode(String.self, forKey: .tableSchema)
        tableName = try container.decode(String.self, forKey: .tableName)
        name = try container.decode(String.self, forKey: .name)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        dataType = try container.decode(String.self, forKey: .dataType)
        udtSchema = try container.decodeIfPresent(String.self, forKey: .udtSchema)
        udtName = try container.decodeIfPresent(String.self, forKey: .udtName)
        isNullable = try container.decode(Bool.self, forKey: .isNullable)
        ordinalPosition = try container.decode(Int.self, forKey: .ordinalPosition)
        valueConstraints = try container.decodeIfPresent(
            [ColumnValueConstraint].self,
            forKey: .valueConstraints
        )
    }
}
