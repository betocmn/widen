import CryptoKit
import Foundation

public enum TextToSQLSemanticValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case float(Double)
    case string(String)
    case uuid(String)
    case date(String)
    case timestampWithTimeZone(String)
    case timestampWithoutTimeZone(String)
    case json(String)
    case interval(months: Int32, days: Int32, microseconds: Int64)
    case bytes(String)
    case unsupported(String)

    public func equivalent(to other: TextToSQLSemanticValue, tolerance: Double) -> Bool {
        switch (self, other) {
        case (.null, .null):
            true
        case (.bool(let left), .bool(let right)):
            left == right
        case (.number(let left), .number(let right)):
            NSDecimalNumber(decimal: left).compare(NSDecimalNumber(decimal: right)) == .orderedSame
        case (.float(let left), .float(let right)):
            Self.floatsEquivalent(left, right, tolerance: tolerance)
        case (.number(let left), .float(let right)):
            Self.floatsEquivalent(NSDecimalNumber(decimal: left).doubleValue, right, tolerance: tolerance)
        case (.float(let left), .number(let right)):
            Self.floatsEquivalent(left, NSDecimalNumber(decimal: right).doubleValue, tolerance: tolerance)
        case (.string(let left), .string(let right)):
            Self.normalizedString(left) == Self.normalizedString(right)
        case (.uuid(let left), .uuid(let right)):
            left.lowercased() == right.lowercased()
        case (.uuid(let left), .string(let right)), (.string(let right), .uuid(let left)):
            left.lowercased() == Self.normalizedString(right)
        case (.date(let left), .date(let right)):
            left == right
        case (.timestampWithTimeZone(let left), .timestampWithTimeZone(let right)):
            left == right
        case (.timestampWithoutTimeZone(let left), .timestampWithoutTimeZone(let right)):
            left == right
        case (.json(let left), .json(let right)):
            left == right
        case (
            .interval(let leftMonths, let leftDays, let leftMicros),
            .interval(let rightMonths, let rightDays, let rightMicros)
        ):
            leftMonths == rightMonths && leftDays == rightDays && leftMicros == rightMicros
        case (.bytes(let left), .bytes(let right)):
            left == right
        default:
            false
        }
    }

    var canonicalString: String {
        switch self {
        case .null:
            "null"
        case .bool(let value):
            "bool:\(value)"
        case .number(let value):
            "number:\(NSDecimalNumber(decimal: value).stringValue)"
        case .float(let value):
            "float:\(String(format: "%.17g", value))"
        case .string(let value):
            "string:\(Self.normalizedString(value))"
        case .uuid(let value):
            "uuid:\(value.lowercased())"
        case .date(let value):
            "date:\(value)"
        case .timestampWithTimeZone(let value):
            "timestamptz:\(value)"
        case .timestampWithoutTimeZone(let value):
            "timestamp:\(value)"
        case .json(let value):
            "json:\(value)"
        case .interval(let months, let days, let microseconds):
            "interval:months=\(months);days=\(days);microseconds=\(microseconds)"
        case .bytes(let value):
            "bytes:\(value)"
        case .unsupported(let type):
            "unsupported:\(type)"
        }
    }

    public static func canonicalJSONOrString(_ value: String) -> TextToSQLSemanticValue {
        if let uuid = UUID(uuidString: value) {
            return .uuid(uuid.uuidString.lowercased())
        }
        if let json = canonicalJSON(value) {
            return .json(json)
        }
        return .string(value)
    }

    public static func canonicalJSON(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
            let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func floatsEquivalent(_ left: Double, _ right: Double, tolerance: Double) -> Bool {
        guard left.isFinite, right.isFinite else { return left == right }
        return abs(left - right) <= max(0, tolerance)
    }

    private static func normalizedString(_ value: String) -> String {
        if let uuid = UUID(uuidString: value) {
            return uuid.uuidString.lowercased()
        }
        return value
    }
}

public struct TextToSQLSemanticQueryResult: Equatable, Sendable {
    public var columns: [String]
    public var columnTypes: [String]
    public var rows: [[TextToSQLSemanticValue]]

    public init(
        columns: [String],
        columnTypes: [String] = [],
        rows: [[TextToSQLSemanticValue]]
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.rows = rows
    }
}

public struct TextToSQLSemanticComparisonResult: Equatable, Sendable {
    public var equivalent: Bool
    public var mismatchCategory: String?
    public var goldenRowCount: Int
    public var candidateRowCount: Int
    public var goldenDigest: String
    public var candidateDigest: String

    public init(
        equivalent: Bool,
        mismatchCategory: String?,
        goldenRowCount: Int,
        candidateRowCount: Int,
        goldenDigest: String,
        candidateDigest: String
    ) {
        self.equivalent = equivalent
        self.mismatchCategory = mismatchCategory
        self.goldenRowCount = goldenRowCount
        self.candidateRowCount = candidateRowCount
        self.goldenDigest = goldenDigest
        self.candidateDigest = candidateDigest
    }
}

public enum TextToSQLSemanticComparator {
    public static let version = "seeded-postgres-semantic-comparator-v2"

    public static func compare(
        golden: TextToSQLSemanticQueryResult,
        candidate: TextToSQLSemanticQueryResult,
        expectation: TextToSQLSemanticExpectation
    ) -> TextToSQLSemanticComparisonResult {
        let goldenDigest = digest(for: golden, mode: expectation.comparisonMode)
        let candidateDigest = digest(for: candidate, mode: expectation.comparisonMode)

        let projection = projected(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )
        switch projection {
        case .failure(let category):
            return TextToSQLSemanticComparisonResult(
                equivalent: false,
                mismatchCategory: category,
                goldenRowCount: golden.rows.count,
                candidateRowCount: candidate.rows.count,
                goldenDigest: goldenDigest,
                candidateDigest: candidateDigest
            )
        case .success(let golden, let candidate):
            if containsUnsupportedValue(golden) || containsUnsupportedValue(candidate) {
                return TextToSQLSemanticComparisonResult(
                    equivalent: false,
                    mismatchCategory: "comparatorUnsupportedType",
                    goldenRowCount: golden.rows.count,
                    candidateRowCount: candidate.rows.count,
                    goldenDigest: digest(for: golden, mode: expectation.comparisonMode),
                    candidateDigest: digest(for: candidate, mode: expectation.comparisonMode)
                )
            }
            let category = mismatchCategory(
                golden: golden,
                candidate: candidate,
                mode: expectation.comparisonMode,
                tolerance: expectation.floatTolerance
            )
            return TextToSQLSemanticComparisonResult(
                equivalent: category == nil,
                mismatchCategory: category,
                goldenRowCount: golden.rows.count,
                candidateRowCount: candidate.rows.count,
                goldenDigest: digest(for: golden, mode: expectation.comparisonMode),
                candidateDigest: digest(for: candidate, mode: expectation.comparisonMode)
            )
        }
    }

    public static func digest(
        for result: TextToSQLSemanticQueryResult,
        mode: TextToSQLResultComparisonMode
    ) -> String {
        let rowStrings = result.rows.map(rowKey)
        let rows = (mode == .ordered || mode == .scalar) ? rowStrings : rowStrings.sorted()
        let text = [
            zipColumnsAndTypes(result).joined(separator: ","),
            rows.joined(separator: "\n"),
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum ProjectionResult {
        case success(TextToSQLSemanticQueryResult, TextToSQLSemanticQueryResult)
        case failure(String)
    }

    private static func projected(
        golden: TextToSQLSemanticQueryResult,
        candidate: TextToSQLSemanticQueryResult,
        expectation: TextToSQLSemanticExpectation
    ) -> ProjectionResult {
        guard !expectation.requiredColumns.isEmpty else {
            if expectation.comparisonMode == .scalar {
                return .success(golden, candidate)
            }
            guard golden.columns.map(normalizedColumn) == candidate.columns.map(normalizedColumn) else {
                return .failure("columnMismatch")
            }
            return .success(golden, candidate)
        }

        guard !hasDuplicateColumns(golden.columns) else {
            return .failure("ambiguousGoldenColumn")
        }
        guard !hasDuplicateColumns(candidate.columns) else {
            return .failure("ambiguousCandidateColumn")
        }

        let goldenResolution = indexes(
            for: expectation.requiredColumns,
            in: golden.columns
        )
        let goldenIndexes: [Int]
        switch goldenResolution {
        case .success(let indexes):
            goldenIndexes = indexes
        case .missing:
            return .failure("missingGoldenColumn")
        case .ambiguous:
            return .failure("ambiguousGoldenColumn")
        }

        let candidateResolution = indexes(
            for: expectation.requiredColumns,
            in: candidate.columns
        )
        let candidateIndexes: [Int]
        switch candidateResolution {
        case .success(let indexes):
            candidateIndexes = indexes
        case .missing:
            return .failure("missingCandidateColumn")
        case .ambiguous:
            return .failure("ambiguousCandidateColumn")
        }

        if !expectation.allowExtraCandidateColumns,
            candidate.columns.count != expectation.requiredColumns.count
        {
            return .failure("unexpectedExtraColumns")
        }

        let columns = expectation.requiredColumns.map(\.canonicalName)
        return .success(
            TextToSQLSemanticQueryResult(
                columns: columns,
                columnTypes: project(golden.columnTypes, indexes: goldenIndexes),
                rows: golden.rows.map { project($0, indexes: goldenIndexes) }
            ),
            TextToSQLSemanticQueryResult(
                columns: columns,
                columnTypes: project(candidate.columnTypes, indexes: candidateIndexes),
                rows: candidate.rows.map { project($0, indexes: candidateIndexes) }
            )
        )
    }

    private enum IndexResolution {
        case success([Int])
        case missing
        case ambiguous
    }

    private static func indexes(
        for expectations: [TextToSQLSemanticColumnExpectation],
        in columns: [String]
    ) -> IndexResolution {
        let normalizedColumns = columns.map(normalizedColumn)
        var result: [Int] = []
        for expectation in expectations {
            let names = Set(([expectation.canonicalName] + expectation.aliases).map(normalizedColumn))
            let matches = normalizedColumns.enumerated().filter { names.contains($0.element) }.map(\.offset)
            guard let match = matches.first else { return .missing }
            guard matches.count == 1 else { return .ambiguous }
            result.append(match)
        }
        return .success(result)
    }

    private static func project(
        _ row: [TextToSQLSemanticValue],
        indexes: [Int]
    ) -> [TextToSQLSemanticValue] {
        indexes.map { index in
            guard index < row.count else { return .null }
            return row[index]
        }
    }

    private static func project(
        _ row: [String],
        indexes: [Int]
    ) -> [String] {
        indexes.map { index in
            guard index < row.count else { return "" }
            return row[index]
        }
    }

    private static func mismatchCategory(
        golden: TextToSQLSemanticQueryResult,
        candidate: TextToSQLSemanticQueryResult,
        mode: TextToSQLResultComparisonMode,
        tolerance: Double
    ) -> String? {
        switch mode {
        case .scalar:
            guard golden.rows.count == 1, candidate.rows.count == 1,
                golden.columns.count == 1, candidate.columns.count == 1,
                golden.rows.first?.count == 1, candidate.rows.first?.count == 1
            else { return "scalarShapeMismatch" }
            return golden.rows[0][0].equivalent(to: candidate.rows[0][0], tolerance: tolerance)
                ? nil
                : "scalarValueMismatch"
        case .ordered:
            guard golden.rows.count == candidate.rows.count else { return "rowCountMismatch" }
            for (left, right) in zip(golden.rows, candidate.rows) {
                guard rowsEquivalent(left, right, tolerance: tolerance) else {
                    return "orderedRowMismatch"
                }
            }
            return nil
        case .unordered, .projectedColumns:
            guard golden.rows.count == candidate.rows.count else { return "rowCountMismatch" }
            var remaining = candidate.rows
            for goldenRow in golden.rows {
                guard let matchIndex = remaining.firstIndex(where: {
                    rowsEquivalent(goldenRow, $0, tolerance: tolerance)
                }) else {
                    return "rowBagMismatch"
                }
                remaining.remove(at: matchIndex)
            }
            return remaining.isEmpty ? nil : "rowBagMismatch"
        }
    }

    private static func rowsEquivalent(
        _ left: [TextToSQLSemanticValue],
        _ right: [TextToSQLSemanticValue],
        tolerance: Double
    ) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0.equivalent(to: $1, tolerance: tolerance) }
    }

    private static func rowKey(_ row: [TextToSQLSemanticValue]) -> String {
        row.map(\.canonicalString).joined(separator: "\u{1E}")
    }

    private static func containsUnsupportedValue(_ result: TextToSQLSemanticQueryResult) -> Bool {
        result.rows.contains { row in
            row.contains { value in
                if case .unsupported = value { return true }
                return false
            }
        }
    }

    private static func hasDuplicateColumns(_ columns: [String]) -> Bool {
        var seen = Set<String>()
        for column in columns.map(normalizedColumn) {
            guard seen.insert(column).inserted else { return true }
        }
        return false
    }

    private static func zipColumnsAndTypes(_ result: TextToSQLSemanticQueryResult) -> [String] {
        result.columns.enumerated().map { index, column in
            let type = index < result.columnTypes.count ? result.columnTypes[index] : ""
            return "\(normalizedColumn(column)):\(type.lowercased())"
        }
    }

    private static func normalizedColumn(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
    }
}
