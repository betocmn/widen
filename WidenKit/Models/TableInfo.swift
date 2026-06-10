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
    public var columns: [ColumnInfo]

    public var qualifiedName: String { "\(schema).\(name)" }

    public init(schema: String, name: String, type: TableType, columns: [ColumnInfo]) {
        self.schema = schema
        self.name = name
        self.type = type
        self.columns = columns
    }
}
