import Foundation
import Observation

@MainActor
@Observable
public final class SchemaViewModel {
    public var searchText = ""
    public var selectedTableID: String?

    public init() {}

    public struct SchemaGroup: Identifiable {
        public var id: String { schema }
        public var schema: String
        public var tables: [TableInfo]
    }

    /// Tables matching the search text, grouped by schema name.
    public func groupedTables(in schema: DatabaseSchema?) -> [SchemaGroup] {
        guard let schema else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty
            ? schema.tables
            : schema.tables.filter { $0.qualifiedName.lowercased().contains(needle) }
        let bySchema = Dictionary(grouping: filtered, by: \.schema)
        return bySchema.keys.sorted().map { name in
            SchemaGroup(
                schema: name,
                tables: bySchema[name, default: []].sorted { $0.name < $1.name }
            )
        }
    }

    public func selectedTable(in schema: DatabaseSchema?) -> TableInfo? {
        guard let schema, let selectedTableID else { return nil }
        return schema.tables.first { $0.id == selectedTableID }
    }
}
