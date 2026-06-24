import Foundation

public enum TableType: String, Codable, Equatable, Hashable, Sendable {
    case baseTable = "BASE TABLE"
    case view = "VIEW"
}

public struct TableInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(schema).\(name)" }
    public var schema: String
    public var name: String
    public var type: TableType
    public var comment: String?
    public var columns: [ColumnInfo]
    public var keyConstraints: [SchemaKeyConstraintInfo]

    public var qualifiedName: String { "\(schema).\(name)" }

    public init(
        schema: String,
        name: String,
        type: TableType,
        comment: String? = nil,
        columns: [ColumnInfo],
        keyConstraints: [SchemaKeyConstraintInfo] = []
    ) {
        self.schema = schema
        self.name = name
        self.type = type
        self.comment = comment
        self.columns = columns
        self.keyConstraints = keyConstraints
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case name
        case type
        case comment
        case columns
        case keyConstraints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TableType.self, forKey: .type)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        columns = try container.decodeIfPresent([ColumnInfo].self, forKey: .columns) ?? []
        keyConstraints = try container.decodeIfPresent(
            [SchemaKeyConstraintInfo].self,
            forKey: .keyConstraints
        ) ?? []
    }
}
