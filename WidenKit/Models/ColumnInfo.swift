import Foundation

public struct ColumnInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(tableSchema).\(tableName).\(name)" }
    public var tableSchema: String
    public var tableName: String
    public var name: String
    public var dataType: String
    public var udtName: String?
    public var isNullable: Bool
    public var ordinalPosition: Int

    public init(
        tableSchema: String,
        tableName: String,
        name: String,
        dataType: String,
        udtName: String? = nil,
        isNullable: Bool,
        ordinalPosition: Int
    ) {
        self.tableSchema = tableSchema
        self.tableName = tableName
        self.name = name
        self.dataType = dataType
        self.udtName = udtName
        self.isNullable = isNullable
        self.ordinalPosition = ordinalPosition
    }
}
