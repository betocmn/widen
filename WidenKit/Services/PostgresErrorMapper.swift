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
            let diagnostic = diagnostic(from: server)
            switch diagnostic.sqlState ?? "" {
            case "28P01", "28000":
                return .authenticationFailed(diagnostic.displayMessage)
            case "3D000":
                return .databaseNotFound(diagnostic.displayMessage)
            case "57014":
                return .databaseFailed(diagnostic)
            default:
                return .databaseFailed(diagnostic)
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

    static func diagnostic(from server: PSQLError.ServerInfo) -> DatabaseDiagnostic {
        let sqlState = server[.sqlState]
        return DatabaseDiagnostic(
            kind: DatabaseDiagnostic.kind(forSQLState: sqlState),
            sqlState: sqlState,
            severity: server[.severity] ?? server[.localizedSeverity],
            message: server[.message] ?? "The server reported an error.",
            detail: server[.detail],
            hint: server[.hint],
            position: server[.position].flatMap(Int.init),
            schemaName: server[.schemaName],
            tableName: server[.tableName],
            columnName: server[.columnName],
            dataTypeName: server[.dataTypeName],
            constraintName: server[.constraintName],
            debugFile: server[.file],
            debugLine: server[.line].flatMap(Int.init),
            debugRoutine: server[.routine]
        )
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
