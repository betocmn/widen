import Foundation

/// A fully-materialised query result. All values are display strings for the
/// MVP; `nil` means SQL NULL.
public struct QueryResult: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var rowCount: Int
    public var truncated: Bool
    public var executionTimeMs: Int

    public init(
        columns: [String],
        rows: [[String?]],
        rowCount: Int,
        truncated: Bool,
        executionTimeMs: Int
    ) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.truncated = truncated
        self.executionTimeMs = executionTimeMs
    }

    /// RFC-4180-style CSV: fields containing commas, quotes, or newlines are
    /// quoted with doubled inner quotes. NULL becomes an empty field.
    public func csv() -> String {
        var lines = [columns.map(Self.csvField).joined(separator: ",")]
        for row in rows {
            lines.append(row.map { Self.csvField($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

public enum QueryResultExport {
    public static func csvFilename(for sessionTitle: String) -> String {
        let words = sessionTitle
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let base = words.isEmpty ? "results" : words.joined(separator: "-")
        return "\(base).csv"
    }
}
