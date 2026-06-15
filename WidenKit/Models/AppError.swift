import Foundation

/// User-readable application errors. Every case maps to a clear message that
/// is shown in the UI, never only logged.
public enum AppError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case databaseNotFound(String)
    case queryTimeout
    case validationFailed([String])
    case executionFailed(String)
    case introspectionFailed(String)
    case modelUnavailable(String)
    case modelGenerationFailed(String)
    case autofillFailed(String)
    case keychainFailed(String)
    case invalidInput([String])

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a database."
        case .connectionFailed(let detail):
            "Could not connect to the database. \(detail)"
        case .authenticationFailed(let detail):
            "Authentication failed. \(detail)"
        case .databaseNotFound(let detail):
            "Database not found. \(detail)"
        case .queryTimeout:
            "The query timed out (statement timeout exceeded)."
        case .validationFailed(let errors):
            "The SQL failed validation: \(errors.joined(separator: " "))"
        case .executionFailed(let detail):
            "Query failed: \(detail)"
        case .introspectionFailed(let detail):
            "Could not load the database schema: \(detail)"
        case .modelUnavailable(let detail):
            detail
        case .modelGenerationFailed(let detail):
            "SQL generation failed: \(detail)"
        case .autofillFailed(let detail):
            "Autofill failed: \(detail)"
        case .keychainFailed(let detail):
            "Keychain error: \(detail)"
        case .invalidInput(let errors):
            errors.joined(separator: " ")
        }
    }
}
