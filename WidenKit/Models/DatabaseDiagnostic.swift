import Foundation

public enum DatabaseDiagnosticKind: String, Codable, Equatable, Sendable {
    case missingRelation
    case missingColumn
    case ambiguousColumn
    case syntaxError
    case groupingError
    case datatypeMismatch
    case undefinedFunction
    case insufficientPrivilege
    case timedOut
    case cancelled
    case other
}

public struct DatabaseDiagnostic: Codable, Equatable, Sendable {
    public var kind: DatabaseDiagnosticKind
    public var sqlState: String?
    public var message: String
    public var detail: String?
    public var hint: String?
    public var position: Int?
    public var schemaName: String?
    public var tableName: String?
    public var columnName: String?

    public init(
        kind: DatabaseDiagnosticKind,
        sqlState: String? = nil,
        message: String,
        detail: String? = nil,
        hint: String? = nil,
        position: Int? = nil,
        schemaName: String? = nil,
        tableName: String? = nil,
        columnName: String? = nil
    ) {
        self.kind = kind
        self.sqlState = sqlState
        self.message = message
        self.detail = detail
        self.hint = hint
        self.position = position
        self.schemaName = schemaName
        self.tableName = tableName
        self.columnName = columnName
    }

    public static func kind(forSQLState sqlState: String?) -> DatabaseDiagnosticKind {
        switch sqlState {
        case "42P01":
            .missingRelation
        case "42703":
            .missingColumn
        case "42702":
            .ambiguousColumn
        case "42601":
            .syntaxError
        case "42803":
            .groupingError
        case "42804":
            .datatypeMismatch
        case "42883":
            .undefinedFunction
        case "42501":
            .insufficientPrivilege
        case "57014":
            .timedOut
        default:
            .other
        }
    }

    public var displayMessage: String {
        var parts = [message]
        if let detail, !detail.isEmpty {
            parts.append("Detail: \(detail)")
        }
        if let hint, !hint.isEmpty {
            parts.append("Hint: \(hint)")
        }
        if let position {
            parts.append("Position: \(position)")
        }
        return parts.joined(separator: " ")
    }

    public var identifierForRepair: String? {
        if let schemaName, let tableName {
            return "\(schemaName).\(tableName)"
        }
        if let tableName {
            return tableName
        }
        if let columnName {
            return columnName
        }
        return nil
    }
}

public struct QueryFailure: Equatable, Sendable {
    public var message: String
    public var diagnostic: DatabaseDiagnostic?

    public init(message: String, diagnostic: DatabaseDiagnostic? = nil) {
        self.message = message
        self.diagnostic = diagnostic
    }
}
