import Foundation

public enum DatabaseInspectionToolName: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case inspectRelationSize = "inspect_relation_size"
    case inspectColumnProfile = "inspect_column_profile"
    case inspectDistinctValues = "inspect_distinct_values"
    case inspectSampleRows = "inspect_sample_rows"
}

public enum DatabaseInspectionResultAudience: String, Codable, Equatable, Sendable {
    case local
    case cloud
}

public enum DatabaseInspectionErrorCode: String, Codable, Equatable, Hashable, Sendable {
    case unknownTool
    case malformedArguments
    case missingArgument
    case invalidArgumentType
    case argumentOutOfRange
    case invalidObjectID
    case staleObjectID
    case wrongObjectKind
    case objectOutsideSnapshot
    case columnTableMismatch
    case policyDenied
    case unsafeColumnType
    case resultBudgetExceeded
    case sessionBudgetExceeded
    case timeout
    case cancelled
    case databaseError
    case internalFailure
}

public struct DatabaseInspectionError: Codable, Error, Equatable, Sendable {
    public var code: DatabaseInspectionErrorCode
    public var message: String
    public var argument: String?

    public init(code: DatabaseInspectionErrorCode, message: String, argument: String? = nil) {
        self.code = code
        self.message = message
        self.argument = argument
    }

    var payload: JSONValue {
        var object: [String: JSONValue] = [
            "code": .string(code.rawValue),
            "message": .string(message),
        ]
        if let argument {
            object["argument"] = .string(argument)
        }
        return .object(object)
    }

    static func policy(_ message: String, argument: String? = nil) -> Self {
        .init(code: .policyDenied, message: message, argument: argument)
    }

    static func typed(_ message: String, argument: String? = nil) -> Self {
        .init(code: .invalidArgumentType, message: message, argument: argument)
    }

    static func range(_ message: String, argument: String? = nil) -> Self {
        .init(code: .argumentOutOfRange, message: message, argument: argument)
    }

    static func stale(_ message: String, argument: String? = nil) -> Self {
        .init(code: .staleObjectID, message: message, argument: argument)
    }
}

public struct DatabaseInspectionTruncation: Codable, Equatable, Sendable {
    public var truncated: Bool
    public var reason: String?
    public var suggestion: String?

    public init(truncated: Bool = false, reason: String? = nil, suggestion: String? = nil) {
        self.truncated = truncated
        self.reason = reason
        self.suggestion = suggestion
    }
}

public struct DatabaseInspectionDiagnostic: Codable, Equatable, Sendable {
    public var toolName: String
    public var tableID: String?
    public var columnIDs: [String]
    public var rowCount: Int
    public var valueCount: Int
    public var bytesReturned: Int
    public var redactionCount: Int
    public var cloudShareable: Bool
    public var latencyMs: Int
    public var errorCode: DatabaseInspectionErrorCode?

    public init(
        toolName: String,
        tableID: String? = nil,
        columnIDs: [String] = [],
        rowCount: Int = 0,
        valueCount: Int = 0,
        bytesReturned: Int = 0,
        redactionCount: Int = 0,
        cloudShareable: Bool = false,
        latencyMs: Int = 0,
        errorCode: DatabaseInspectionErrorCode? = nil
    ) {
        self.toolName = toolName
        self.tableID = tableID
        self.columnIDs = columnIDs
        self.rowCount = rowCount
        self.valueCount = valueCount
        self.bytesReturned = bytesReturned
        self.redactionCount = redactionCount
        self.cloudShareable = cloudShareable
        self.latencyMs = latencyMs
        self.errorCode = errorCode
    }
}

public struct DatabaseInspectionResult: Codable, Equatable, Sendable {
    public var callID: String
    public var toolName: String
    public var success: Bool
    public var payload: JSONValue?
    public var error: DatabaseInspectionError?
    public var truncation: DatabaseInspectionTruncation
    public var outputByteCount: Int
    public var diagnostic: DatabaseInspectionDiagnostic

    public init(
        callID: String,
        toolName: String,
        success: Bool,
        payload: JSONValue? = nil,
        error: DatabaseInspectionError? = nil,
        truncation: DatabaseInspectionTruncation = DatabaseInspectionTruncation(),
        outputByteCount: Int = 0,
        diagnostic: DatabaseInspectionDiagnostic
    ) {
        self.callID = callID
        self.toolName = toolName
        self.success = success
        self.payload = payload
        self.error = error
        self.truncation = truncation
        self.outputByteCount = outputByteCount
        self.diagnostic = diagnostic
    }
}

public struct DatabaseInspectionPolicy: Codable, Equatable, Sendable {
    public var allowLocalDataInspection: Bool
    public var allowCloudDataInspection: Bool
    public var allowSampleRows: Bool
    public var allowFullTableScans: Bool
    public var allowDistinctValuesInProfiles: Bool
    public var audience: DatabaseInspectionResultAudience
    public var maximumCallCount: Int
    public var maximumResultBytes: Int
    public var maximumSessionResultBytes: Int
    public var maximumReturnedRows: Int
    public var maximumDistinctValues: Int
    public var maximumSampleColumns: Int
    public var maximumTextCharacters: Int
    public var maximumJSONCharacters: Int
    public var lowCardinalityDistinctLimit: Int
    public var statementTimeoutMilliseconds: Int
    public var lockTimeoutMilliseconds: Int
    public var idleTransactionTimeoutMilliseconds: Int
    public var maximumArgumentsJSONBytes: Int
    public var maximumCallIDBytes: Int
    public var maximumToolNameBytes: Int
    public var sensitiveNameFragments: [String]
    public var redactedColumnStableIDs: Set<String>

    public init(
        allowLocalDataInspection: Bool = false,
        allowCloudDataInspection: Bool = false,
        allowSampleRows: Bool = false,
        allowFullTableScans: Bool = false,
        allowDistinctValuesInProfiles: Bool = false,
        audience: DatabaseInspectionResultAudience = .local,
        maximumCallCount: Int = 4,
        maximumResultBytes: Int = 8_000,
        maximumSessionResultBytes: Int = 20_000,
        maximumReturnedRows: Int = 20,
        maximumDistinctValues: Int = 20,
        maximumSampleColumns: Int = 8,
        maximumTextCharacters: Int = 160,
        maximumJSONCharacters: Int = 400,
        lowCardinalityDistinctLimit: Int = 20,
        statementTimeoutMilliseconds: Int = 2_000,
        lockTimeoutMilliseconds: Int = 500,
        idleTransactionTimeoutMilliseconds: Int = 5_000,
        maximumArgumentsJSONBytes: Int = 2_048,
        maximumCallIDBytes: Int = 128,
        maximumToolNameBytes: Int = 64,
        sensitiveNameFragments: [String] = Self.defaultSensitiveNameFragments,
        redactedColumnStableIDs: Set<String> = []
    ) {
        self.allowLocalDataInspection = allowLocalDataInspection
        self.allowCloudDataInspection = allowCloudDataInspection
        self.allowSampleRows = allowSampleRows
        self.allowFullTableScans = allowFullTableScans
        self.allowDistinctValuesInProfiles = allowDistinctValuesInProfiles
        self.audience = audience
        self.maximumCallCount = maximumCallCount
        self.maximumResultBytes = min(maximumResultBytes, 64_000)
        self.maximumSessionResultBytes = min(maximumSessionResultBytes, 128_000)
        self.maximumReturnedRows = min(max(maximumReturnedRows, 1), 20)
        self.maximumDistinctValues = min(max(maximumDistinctValues, 1), 20)
        self.maximumSampleColumns = min(max(maximumSampleColumns, 1), 8)
        self.maximumTextCharacters = min(max(maximumTextCharacters, 1), 1_000)
        self.maximumJSONCharacters = min(max(maximumJSONCharacters, 1), 2_000)
        self.lowCardinalityDistinctLimit = min(max(lowCardinalityDistinctLimit, 1), 100)
        self.statementTimeoutMilliseconds = min(max(statementTimeoutMilliseconds, 100), 10_000)
        self.lockTimeoutMilliseconds = min(max(lockTimeoutMilliseconds, 50), 5_000)
        self.idleTransactionTimeoutMilliseconds = min(max(idleTransactionTimeoutMilliseconds, 100), 15_000)
        self.maximumArgumentsJSONBytes = maximumArgumentsJSONBytes
        self.maximumCallIDBytes = maximumCallIDBytes
        self.maximumToolNameBytes = maximumToolNameBytes
        self.sensitiveNameFragments = sensitiveNameFragments
        self.redactedColumnStableIDs = redactedColumnStableIDs
    }

    public static let disabled = DatabaseInspectionPolicy()

    public static func localDataInspection(
        allowFullTableScans: Bool = false,
        allowDistinctValuesInProfiles: Bool = false,
        allowSampleRows: Bool = false
    ) -> DatabaseInspectionPolicy {
        DatabaseInspectionPolicy(
            allowLocalDataInspection: true,
            allowCloudDataInspection: false,
            allowSampleRows: allowSampleRows,
            allowFullTableScans: allowFullTableScans,
            allowDistinctValuesInProfiles: allowDistinctValuesInProfiles,
            audience: .local
        )
    }

    public static func cloudDataInspection(
        allowFullTableScans: Bool = false,
        allowDistinctValuesInProfiles: Bool = false,
        allowSampleRows: Bool = false
    ) -> DatabaseInspectionPolicy {
        DatabaseInspectionPolicy(
            allowLocalDataInspection: true,
            allowCloudDataInspection: true,
            allowSampleRows: allowSampleRows,
            allowFullTableScans: allowFullTableScans,
            allowDistinctValuesInProfiles: allowDistinctValuesInProfiles,
            audience: .cloud
        )
    }

    public static let defaultSensitiveNameFragments = [
        "password",
        "passwd",
        "token",
        "secret",
        "api_key",
        "apikey",
        "key",
        "auth",
        "credential",
        "session",
        "email",
        "phone",
        "address",
        "raw_user_meta_data",
        "user_metadata",
        "app_metadata",
    ]

    public var canShareDataValuesWithAudience: Bool {
        audience == .local || allowCloudDataInspection
    }

    public func redacts(_ column: ColumnInfo) -> Bool {
        let stableID = SchemaObjectID.column(
            schema: column.tableSchema,
            table: column.tableName,
            name: column.name
        ).stableString
        if redactedColumnStableIDs.contains(stableID) {
            return true
        }
        let searchable = [
            column.tableSchema,
            column.tableName,
            column.name,
            column.comment ?? "",
            column.dataType,
            column.udtName ?? "",
        ].joined(separator: " ").lowercased()
        return sensitiveNameFragments.contains { fragment in
            searchable.contains(fragment.lowercased())
        }
    }
}

public enum DatabaseInspectionValueKind: String, Codable, Equatable, Sendable {
    case null
    case boolean
    case integer
    case decimal
    case float
    case uuid
    case date
    case timestamp
    case timestampWithTimeZone = "timestamp_tz"
    case text
    case json
    case unsupportedType
    case redacted
}

public struct DatabaseInspectionValue: Codable, Equatable, Sendable {
    public var kind: DatabaseInspectionValueKind
    public var stringValue: String?
    public var boolValue: Bool?
    public var integerValue: Int64?
    public var floatValue: Double?
    public var truncated: Bool
    public var byteCount: Int?

    public init(
        kind: DatabaseInspectionValueKind,
        stringValue: String? = nil,
        boolValue: Bool? = nil,
        integerValue: Int64? = nil,
        floatValue: Double? = nil,
        truncated: Bool = false,
        byteCount: Int? = nil
    ) {
        self.kind = kind
        self.stringValue = stringValue
        self.boolValue = boolValue
        self.integerValue = integerValue
        self.floatValue = floatValue
        self.truncated = truncated
        self.byteCount = byteCount
    }

    public static let null = DatabaseInspectionValue(kind: .null)
    public static let redacted = DatabaseInspectionValue(kind: .redacted)

    public static func boolean(_ value: Bool) -> Self {
        DatabaseInspectionValue(kind: .boolean, boolValue: value)
    }

    public static func integer(_ value: Int64) -> Self {
        DatabaseInspectionValue(kind: .integer, integerValue: value)
    }

    public static func decimal(_ value: String) -> Self {
        DatabaseInspectionValue(kind: .decimal, stringValue: value)
    }

    public static func float(_ value: Double) -> Self {
        DatabaseInspectionValue(kind: .float, floatValue: value)
    }

    public static func uuid(_ value: String) -> Self {
        DatabaseInspectionValue(kind: .uuid, stringValue: value)
    }

    public static func date(_ value: String) -> Self {
        DatabaseInspectionValue(kind: .date, stringValue: value)
    }

    public static func timestamp(_ value: String) -> Self {
        DatabaseInspectionValue(kind: .timestamp, stringValue: value)
    }

    public static func timestampWithTimeZone(_ value: String) -> Self {
        DatabaseInspectionValue(kind: .timestampWithTimeZone, stringValue: value)
    }

    public static func text(_ value: String, cap: Int) -> Self {
        capped(kind: .text, value: value, cap: cap)
    }

    public static func json(_ value: String, cap: Int) -> Self {
        capped(kind: .json, value: value, cap: cap)
    }

    public static func unsupported(_ type: String) -> Self {
        DatabaseInspectionValue(kind: .unsupportedType, stringValue: type)
    }

    public var containsDataValue: Bool {
        switch kind {
        case .null, .unsupportedType, .redacted:
            false
        default:
            true
        }
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(kind.rawValue),
        ]
        switch kind {
        case .null:
            object["value"] = .null
        case .boolean:
            object["value"] = .bool(boolValue ?? false)
        case .integer:
            if let integerValue {
                if Self.isExactlyRepresentableInJSONNumber(integerValue) {
                    object["value"] = .number(Double(integerValue))
                } else {
                    object["value"] = .string(String(integerValue))
                }
            }
        case .float:
            if let floatValue {
                object["value"] = floatValue.isFinite
                    ? .number(floatValue)
                    : .string(String(describing: floatValue))
            }
        case .decimal, .uuid, .date, .timestamp, .timestampWithTimeZone, .text, .json,
            .unsupportedType:
            if let stringValue {
                object["value"] = .string(stringValue)
            }
        case .redacted:
            object["redacted"] = true
        }
        if truncated {
            object["truncated"] = true
        }
        if let byteCount {
            object["source_byte_count"] = .number(Double(byteCount))
        }
        return .object(object)
    }

    private static func isExactlyRepresentableInJSONNumber(_ value: Int64) -> Bool {
        let maximumSafeInteger: Int64 = 9_007_199_254_740_991
        return (-maximumSafeInteger...maximumSafeInteger).contains(value)
    }

    private static func capped(kind: DatabaseInspectionValueKind, value: String, cap: Int) -> Self {
        var bounded = String(value.prefix(max(cap, 1)))
        while bounded.utf8.count > cap, !bounded.isEmpty {
            bounded.removeLast()
        }
        return DatabaseInspectionValue(
            kind: kind,
            stringValue: bounded,
            truncated: bounded.count < value.count || bounded.utf8.count < value.utf8.count,
            byteCount: value.utf8.count
        )
    }
}

public struct DatabaseRelationSizeSnapshot: Equatable, Sendable {
    public var approximateRowCount: Int64?
    public var source: String

    public init(approximateRowCount: Int64?, source: String) {
        self.approximateRowCount = approximateRowCount
        self.source = source
    }
}

public struct DatabaseColumnStatisticsSnapshot: Equatable, Sendable {
    public var approximateNullFraction: Double?
    public var approximateDistinctCount: Double?

    public init(approximateNullFraction: Double? = nil, approximateDistinctCount: Double? = nil) {
        self.approximateNullFraction = approximateNullFraction
        self.approximateDistinctCount = approximateDistinctCount
    }
}

public struct DatabaseColumnAggregateSnapshot: Equatable, Sendable {
    public var rowCount: Int64
    public var nullCount: Int64
    public var distinctCount: Int64?
    public var minValue: DatabaseInspectionValue?
    public var maxValue: DatabaseInspectionValue?

    public init(
        rowCount: Int64,
        nullCount: Int64,
        distinctCount: Int64? = nil,
        minValue: DatabaseInspectionValue? = nil,
        maxValue: DatabaseInspectionValue? = nil
    ) {
        self.rowCount = rowCount
        self.nullCount = nullCount
        self.distinctCount = distinctCount
        self.minValue = minValue
        self.maxValue = maxValue
    }
}

public struct DatabaseDistinctValueRow: Equatable, Sendable {
    public var value: DatabaseInspectionValue
    public var count: Int64?

    public init(value: DatabaseInspectionValue, count: Int64? = nil) {
        self.value = value
        self.count = count
    }
}

public struct DatabaseSampleRow: Equatable, Sendable {
    public var valuesByColumnStableID: [String: DatabaseInspectionValue]

    public init(valuesByColumnStableID: [String: DatabaseInspectionValue]) {
        self.valuesByColumnStableID = valuesByColumnStableID
    }
}

public protocol DatabaseInspectionQuerying: Sendable {
    func inspectRelationSize(
        schema: String,
        table: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseRelationSizeSnapshot

    func inspectColumnStatistics(
        schema: String,
        table: String,
        column: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnStatisticsSnapshot

    func inspectColumnAggregate(
        table: TableInfo,
        column: ColumnInfo,
        includeDistinct: Bool,
        includeMinMax: Bool,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnAggregateSnapshot

    func inspectDistinctValues(
        table: TableInfo,
        column: ColumnInfo,
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseDistinctValueRow]

    func inspectSampleRows(
        table: TableInfo,
        columns: [ColumnInfo],
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseSampleRow]
}
