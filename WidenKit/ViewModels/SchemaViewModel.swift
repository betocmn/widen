import Foundation
import Observation

@MainActor
@Observable
public final class SchemaViewModel {
    public var searchText = ""
    public var selectedTableID: String?

    public init() {}

    /// Tables of one schema matching the search text, sorted by name. The
    /// search matches the table name only — the schema is already fixed by
    /// the picker, so matching the qualified name would make a search like
    /// "public" hit everything.
    public func tables(in schema: DatabaseSchema?, schemaName: String?) -> [TableInfo] {
        guard let schema, let schemaName else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return schema.tables
            .filter { $0.schema == schemaName }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name < $1.name }
    }

    public func selectedTable(in schema: DatabaseSchema?) -> TableInfo? {
        guard let schema, let selectedTableID else { return nil }
        return schema.tables.first { $0.id == selectedTableID }
    }
}
