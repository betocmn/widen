import Foundation

protocol QueryExecuting: Sendable {
    func run(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService
    ) async throws -> QueryResult
}

/// Validates and executes user- or AI-written SQL. The model is never
/// trusted: every statement goes through `SQLSafetyValidator` before reaching
/// the database, and always runs read-only with a statement timeout.
public struct QueryExecutionService: QueryExecuting, Sendable {
    public init() {}

    public func run(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService
    ) async throws -> QueryResult {
        let validation = SQLSafetyValidator.validate(sql)
        guard validation.isValid, let normalizedSQL = validation.normalizedSQL else {
            throw AppError.validationFailed(validation.errors)
        }
        return try await postgres.executeReadOnly(
            sql: normalizedSQL,
            hasLimit: validation.hasLimit,
            rowLimit: config.defaultRowLimit,
            timeoutSeconds: config.statementTimeoutSeconds
        )
    }
}
