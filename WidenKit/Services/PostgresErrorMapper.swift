import Foundation
import NIOCore
import PostgresNIO

/// Translates PostgresNIO / NIO errors into user-readable `AppError`s.
enum PostgresErrorMapper {
    static func map(_ error: any Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError {
            return .executionFailed("The operation was cancelled.")
        }
        guard let psql = error as? PSQLError else {
            return .connectionFailed(describe(error))
        }

        if let server = psql.serverInfo {
            let message = server[.message] ?? "The server reported an error."
            switch server[.sqlState] ?? "" {
            case "28P01", "28000":
                return .authenticationFailed(message)
            case "3D000":
                return .databaseNotFound(message)
            case "57014":
                return .queryTimeout
            default:
                var detail = message
                if let hint = server[.hint] { detail += " Hint: \(hint)" }
                return .executionFailed(detail)
            }
        }

        switch psql.code {
        case .connectionError:
            let detail = psql.underlying.map { describe($0) }
                ?? "Is PostgreSQL running on that host and port?"
            return .connectionFailed(detail)
        case .authMechanismRequiresPassword:
            return .authenticationFailed("The server requires a password.")
        case .serverClosedConnection:
            return .connectionFailed("The server closed the connection.")
        case .queryCancelled:
            return .executionFailed("The query was cancelled.")
        default:
            return .executionFailed(describe(psql))
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let ioError = error as? IOError {
            return ioError.localizedDescription
        }
        if let localized = error as? LocalizedError,
            let message = localized.errorDescription
        {
            return message
        }
        return String(describing: error)
    }
}
