import Foundation

public struct NormalizedIdentifier: Hashable, Codable, Sendable {
    public var rawValue: String

    public init(_ value: String) {
        self.rawValue = SchemaIndex.normalizedIdentifier(value)
    }
}

public struct SchemaIndex: Sendable {
    public var tablesByQualifiedName: [NormalizedIdentifier: TableInfo]
    public var tablesByUnqualifiedName: [NormalizedIdentifier: [TableInfo]]
    public var columnsByName: [NormalizedIdentifier: [ColumnInfo]]
    public var tokensByTableID: [String: Set<String>]
    public var foreignKeyAdjacency: [String: [ForeignKeyInfo]]
    public var temporalColumnsByTableID: [String: [ColumnInfo]]

    public init(schema: DatabaseSchema) {
        var qualified: [NormalizedIdentifier: TableInfo] = [:]
        var unqualified: [NormalizedIdentifier: [TableInfo]] = [:]
        var columns: [NormalizedIdentifier: [ColumnInfo]] = [:]
        var tokensByTableID: [String: Set<String>] = [:]
        var temporalColumns: [String: [ColumnInfo]] = [:]

        for table in schema.tables {
            qualified[NormalizedIdentifier(table.qualifiedName)] = table
            unqualified[NormalizedIdentifier(table.name), default: []].append(table)

            var tableTokens = Set(Self.tokens(in: table.schema) + Self.tokens(in: table.name))
            for column in table.columns {
                columns[NormalizedIdentifier(column.name), default: []].append(column)
                let columnTokens = Self.tokens(in: column.name)
                tableTokens.formUnion(columnTokens)
                if Self.isTemporal(column) {
                    temporalColumns[table.id, default: []].append(column)
                }
            }
            tokensByTableID[table.id] = tableTokens
        }

        var adjacency: [String: [ForeignKeyInfo]] = [:]
        for foreignKey in schema.foreignKeys {
            adjacency["\(foreignKey.sourceSchema).\(foreignKey.sourceTable)", default: []]
                .append(foreignKey)
            adjacency["\(foreignKey.targetSchema).\(foreignKey.targetTable)", default: []]
                .append(foreignKey)
        }

        self.tablesByQualifiedName = qualified
        self.tablesByUnqualifiedName = unqualified
        self.columnsByName = columns
        self.tokensByTableID = tokensByTableID
        self.foreignKeyAdjacency = adjacency
        self.temporalColumnsByTableID = temporalColumns
    }

    public static func normalizedIdentifier(_ value: String) -> String {
        tokens(in: value).joined(separator: "_")
    }

    public static func tokens(in text: String) -> [String] {
        let unquoted = text.replacingOccurrences(of: "\"", with: "")
        var expanded = ""
        var previous: Character?
        for character in unquoted {
            if let previous,
                previous.isLowercase,
                character.isUppercase
            {
                expanded.append(" ")
            }
            expanded.append(character)
            previous = character
        }

        let rawTokens = expanded
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        var result: [String] = []
        for token in rawTokens {
            result.append(token)
            if token.hasSuffix("ies"), token.count > 3 {
                result.append(String(token.dropLast(3)) + "y")
            } else if token.hasSuffix("s"), token.count > 3 {
                result.append(String(token.dropLast()))
            }
        }
        return Array(Set(result)).sorted()
    }

    private static func isTemporal(_ column: ColumnInfo) -> Bool {
        let name = column.name.lowercased()
        let type = column.dataType.lowercased()
        return type.contains("date")
            || type.contains("time")
            || name.hasSuffix("_at")
            || name.contains("date")
            || name.contains("time")
            || name.contains("scheduled")
    }
}
