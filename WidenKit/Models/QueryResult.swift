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

public enum QueryResultDisplayPolicy {
    public static let maxRowsPerPage = 20

    public static func pageCount(forRowCount rowCount: Int) -> Int {
        max(1, (max(rowCount, 0) + maxRowsPerPage - 1) / maxRowsPerPage)
    }

    public static func clampedPage(_ page: Int, rowCount: Int) -> Int {
        min(max(page, 0), pageCount(forRowCount: rowCount) - 1)
    }

    public static func rows(_ rows: [[String?]], page: Int) -> [[String?]] {
        let page = clampedPage(page, rowCount: rows.count)
        let start = page * maxRowsPerPage
        guard start < rows.count else { return [] }
        let end = min(start + maxRowsPerPage, rows.count)
        return Array(rows[start..<end])
    }

    public static func visibleRange(forRowCount rowCount: Int, page: Int) -> Range<Int>? {
        guard rowCount > 0 else { return nil }
        let page = clampedPage(page, rowCount: rowCount)
        let start = page * maxRowsPerPage
        let end = min(start + maxRowsPerPage, rowCount)
        return start..<end
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
