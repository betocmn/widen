import Foundation

public struct ForeignKeyInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(constraintName):\(sourceSchema).\(sourceTable).\(sourceColumn)" }
    public var constraintName: String
    public var sourceSchema: String
    public var sourceTable: String
    public var sourceColumn: String
    public var targetSchema: String
    public var targetTable: String
    public var targetColumn: String

    /// `public.orders.user_id -> public.users.id`
    public var summary: String {
        "\(sourceSchema).\(sourceTable).\(sourceColumn) -> \(targetSchema).\(targetTable).\(targetColumn)"
    }

    public init(
        constraintName: String,
        sourceSchema: String,
        sourceTable: String,
        sourceColumn: String,
        targetSchema: String,
        targetTable: String,
        targetColumn: String
    ) {
        self.constraintName = constraintName
        self.sourceSchema = sourceSchema
        self.sourceTable = sourceTable
        self.sourceColumn = sourceColumn
        self.targetSchema = targetSchema
        self.targetTable = targetTable
        self.targetColumn = targetColumn
    }
}
