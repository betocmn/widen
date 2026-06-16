import Foundation

protocol QueryExecuting: Sendable {
    /// Runs a read query. This path is the one the auto-retry loop uses, so it
    /// must refuse writes — a write reaching here is rejected, never executed.
    func run(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService
    ) async throws -> QueryResult

    /// Runs a write (INSERT/UPDATE/DELETE). Only the explicit Run path calls
    /// this, and only after the confirmation gate for destructive writes.
    func runWrite(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService,
        confirmedDangerous: Bool
    ) async throws -> QueryResult
}

extension QueryExecuting {
    /// Default so read-only test doubles keep compiling. Real execution routes
    /// writes through `QueryExecutionService.runWrite`.
    func runWrite(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService,
        confirmedDangerous: Bool
    ) async throws -> QueryResult {
        try await run(sql: sql, config: config, postgres: postgres)
    }
}

/// Validates and executes user- or AI-written SQL. The model is never
/// trusted: every statement goes through `SQLSafetyValidator` before reaching
/// the database. Reads run read-only with a statement timeout; writes run only
/// through `runWrite`, which the auto-retry machinery can never reach.
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
        // Structural backstop for the hard invariant: the read path — the only
        // one the auto-retry loop uses — never sends a write to the database.
        guard !validation.kind.isWrite else {
            throw AppError.executionFailed(
                "Write queries cannot run automatically; press Run to execute this query.")
        }
        return try await postgres.executeReadOnly(
            sql: normalizedSQL,
            hasLimit: validation.hasLimit,
            rowLimit: config.defaultRowLimit,
            timeoutSeconds: config.statementTimeoutSeconds
        )
    }

    public func runWrite(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService,
        confirmedDangerous: Bool
    ) async throws -> QueryResult {
        let validation = SQLSafetyValidator.validate(sql)
        guard validation.isValid, let normalizedSQL = validation.normalizedSQL else {
            throw AppError.validationFailed(validation.errors)
        }
        guard validation.kind.isWrite else {
            // A read sent down the write path is a programming error.
            throw AppError.executionFailed("Only write queries can run on the write path.")
        }
        // Destructive writes (DELETE, UPDATE without WHERE) require the user to
        // have confirmed in the dialog. Backstop for the UI gate.
        guard !validation.requiresConfirmation || confirmedDangerous else {
            throw AppError.executionFailed("This query needs confirmation before it can run.")
        }
        return try await postgres.executeWrite(
            sql: normalizedSQL,
            timeoutSeconds: config.statementTimeoutSeconds,
            kind: validation.kind
        )
    }
}
