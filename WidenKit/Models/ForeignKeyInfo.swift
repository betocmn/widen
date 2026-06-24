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
    public var ordinalPosition: Int

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
        targetColumn: String,
        ordinalPosition: Int = 1
    ) {
        self.constraintName = constraintName
        self.sourceSchema = sourceSchema
        self.sourceTable = sourceTable
        self.sourceColumn = sourceColumn
        self.targetSchema = targetSchema
        self.targetTable = targetTable
        self.targetColumn = targetColumn
        self.ordinalPosition = ordinalPosition
    }

    private enum CodingKeys: String, CodingKey {
        case constraintName
        case sourceSchema
        case sourceTable
        case sourceColumn
        case targetSchema
        case targetTable
        case targetColumn
        case ordinalPosition
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        constraintName = try container.decode(String.self, forKey: .constraintName)
        sourceSchema = try container.decode(String.self, forKey: .sourceSchema)
        sourceTable = try container.decode(String.self, forKey: .sourceTable)
        sourceColumn = try container.decode(String.self, forKey: .sourceColumn)
        targetSchema = try container.decode(String.self, forKey: .targetSchema)
        targetTable = try container.decode(String.self, forKey: .targetTable)
        targetColumn = try container.decode(String.self, forKey: .targetColumn)
        ordinalPosition = try container.decodeIfPresent(Int.self, forKey: .ordinalPosition) ?? 1
    }
}
