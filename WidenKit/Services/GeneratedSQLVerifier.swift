import Foundation

public struct PostgresConnectionHandle: Sendable {
    public var postgres: PostgresService

    public init(postgres: PostgresService) {
        self.postgres = postgres
    }
}

public enum SQLSafetyMode: String, Codable, Equatable, Sendable {
    case generatedRead
    case generatedWrite

    public init(kind: SQLStatementKind) {
        self = kind.isWrite ? .generatedWrite : .generatedRead
    }
}

public enum SQLVerificationStage: String, Codable, Equatable, Sendable {
    case skipped
    case transaction
    case prepare
    case deallocate
    case rollback
}

public enum SQLVerificationStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case notAvailable
    case skippedNoConnection
    case skippedNonRead
    case skippedStaticValidationFailed
    case passed
    case failed
}

public struct SQLVerificationResult: Codable, Equatable, Sendable {
    public var passed: Bool
    public var diagnostic: DatabaseDiagnostic?
    public var elapsedMs: Int
    public var stage: SQLVerificationStage
    public var status: SQLVerificationStatus
    public var message: String?

    public init(
        passed: Bool,
        diagnostic: DatabaseDiagnostic? = nil,
        elapsedMs: Int,
        stage: SQLVerificationStage,
        status: SQLVerificationStatus,
        message: String? = nil
    ) {
        self.passed = passed
        self.diagnostic = diagnostic
        self.elapsedMs = elapsedMs
        self.stage = stage
        self.status = status
        self.message = message
    }

    public static func skipped(
        _ status: SQLVerificationStatus,
        message: String,
        elapsedMs: Int = 0
    ) -> SQLVerificationResult {
        SQLVerificationResult(
            passed: false,
            elapsedMs: elapsedMs,
            stage: .skipped,
            status: status,
            message: message
        )
    }

    public static func passed(elapsedMs: Int) -> SQLVerificationResult {
        SQLVerificationResult(
            passed: true,
            elapsedMs: elapsedMs,
            stage: .deallocate,
            status: .passed
        )
    }

    public static func failed(
        diagnostic: DatabaseDiagnostic?,
        elapsedMs: Int,
        stage: SQLVerificationStage,
        message: String? = nil
    ) -> SQLVerificationResult {
        SQLVerificationResult(
            passed: false,
            diagnostic: diagnostic,
            elapsedMs: elapsedMs,
            stage: stage,
            status: .failed,
            message: message
        )
    }
}

public protocol GeneratedSQLVerifying: Sendable {
    func verify(
        sql: String,
        connection: PostgresConnectionHandle,
        safetyMode: SQLSafetyMode
    ) async throws -> SQLVerificationResult
}

public struct PostgresSQLVerifier: GeneratedSQLVerifying {
    public init() {}

    public func verify(
        sql: String,
        connection: PostgresConnectionHandle,
        safetyMode: SQLSafetyMode
    ) async throws -> SQLVerificationResult {
        guard safetyMode == .generatedRead else {
            return .skipped(
                .skippedNonRead,
                message: "PostgreSQL verification is only run for generated read SQL."
            )
        }
        if let placeholder = Self.bindPlaceholder(in: sql) {
            let diagnostic = DatabaseDiagnostic(
                kind: .syntaxError,
                message: "Generated SQL uses a PostgreSQL bind parameter (\(placeholder)), which cannot be executed as a standalone query. Inline the parameter value instead."
            )
            return .failed(
                diagnostic: diagnostic,
                elapsedMs: 0,
                stage: .transaction,
                message: diagnostic.displayMessage
            )
        }
        return try await connection.postgres.verifyGeneratedReadOnlySQL(sql)
    }

    private static func bindPlaceholder(in sql: String) -> String? {
        let stripped = SQLSafetyValidator.strip(sql).text
        guard let range = stripped.range(of: #"\$[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return String(stripped[range])
    }
}
