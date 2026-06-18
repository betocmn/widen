import Foundation
import Observation

struct QueryExecutionAttempt {
    var result: QueryResult?
    var errorMessage: String?
    var failure: QueryFailure?
    var wasDiscarded = false
    var wasUnsafeWrite = false
}

/// State for the SQL editor and results panels.
@MainActor
@Observable
public final class QueryResultViewModel {
    /// Called exactly once when a run finishes: `(result, nil)` on success,
    /// `(nil, error)` on failure, cancellation, or local validation failure.
    public typealias RunCompletion = @MainActor (QueryResult?, String?) -> Void

    public var sqlText = ""
    public private(set) var validation: SQLValidationResult?
    public private(set) var schemaValidation: SQLSchemaValidationResult?
    public private(set) var result: QueryResult?
    public private(set) var isRunning = false
    public private(set) var canStopWaiting = false
    public private(set) var runError: String?
    public private(set) var runFailure: QueryFailure?
    /// Metadata of the last model generation that filled the editor.
    public private(set) var generation: SQLGenerationResult?

    private var activeRunID: Int?
    private var activeRunKind: ActiveRunKind?
    private var nextRunID = 0
    private var runTask: Task<Void, Never>?
    private var onFinish: RunCompletion?
    private var onAttemptFinish: ((QueryExecutionAttempt) -> Void)?
    private let executor: any QueryExecuting

    public init() {
        self.executor = QueryExecutionService()
    }

    init(executor: any QueryExecuting) {
        self.executor = executor
    }

    public func validate(schema: DatabaseSchema? = nil) {
        let safety = SQLSafetyValidator.validate(sqlText)
        schemaValidation = nil
        guard let schema,
            safety.isValid,
            !sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            validation = safety
            return
        }

        let schemaValidation = SQLSchemaValidator.validate(sql: sqlText, against: schema)
        self.schemaValidation = schemaValidation
        validation = GeneratedSQLValidator.combine(
            safety: safety,
            schemaValidation: schemaValidation
        )
    }

    /// Starts the query in a cancellable task. Cancellation only stops the app
    /// from waiting — the server-side guard is the statement timeout.
    /// `confirmed` is true only when the user approved a destructive write
    /// (DELETE, or UPDATE without WHERE) in the confirmation dialog. It is
    /// passed straight to the write executor and ignored for reads.
    public func startRun(
        connection: DatabaseConnectionConfig?,
        postgres: PostgresService,
        isConnected: Bool,
        confirmed: Bool = false,
        onFinish: RunCompletion? = nil
    ) {
        // The guard must precede storing the callback, so a rejected start
        // never clobbers the completion of the run already in flight.
        guard !isRunning else { return }
        let runSQL = sqlText
        self.onFinish = onFinish
        nextRunID += 1
        let runID = nextRunID
        activeRunID = runID
        activeRunKind = .visible
        canStopWaiting = true
        result = nil
        runError = nil
        runFailure = nil
        isRunning = true
        runTask = Task {
            await run(
                sql: runSQL,
                connection: connection, postgres: postgres,
                isConnected: isConnected, runID: runID, confirmed: confirmed)
        }
    }

    public func cancelRun() {
        cancelActiveRun(reportError: true, fireCompletion: true)
    }

    @discardableResult
    private func discardActiveRun() -> Bool {
        cancelActiveRun(reportError: false, fireCompletion: false)
    }

    @discardableResult
    private func cancelActiveRun(reportError: Bool, fireCompletion shouldFire: Bool) -> Bool {
        guard activeRunID == nil || canStopWaiting else { return false }
        let runKind = activeRunKind
        runTask?.cancel()
        runTask = nil
        activeRunID = nil
        activeRunKind = nil
        canStopWaiting = false
        if isRunning {
            isRunning = false
            if reportError {
                runError = Self.stoppedWaitingMessage
                runFailure = QueryFailure(message: Self.stoppedWaitingMessage)
            }
        }
        if shouldFire {
            if runKind == .generatedSQLAttempt {
                fireAttemptCompletion(
                    QueryExecutionAttempt(result: nil, errorMessage: runError, failure: runFailure)
                )
            } else {
                fireCompletion()
            }
        } else if runKind == .generatedSQLAttempt {
            fireAttemptCompletion(
                QueryExecutionAttempt(result: nil, errorMessage: nil, wasDiscarded: true)
            )
        } else {
            onFinish = nil
            onAttemptFinish = nil
        }
        return true
    }

    @discardableResult
    public func clear() -> Bool {
        guard discardActiveRun() else { return false }
        sqlText = ""
        validation = nil
        schemaValidation = nil
        result = nil
        runError = nil
        runFailure = nil
        generation = nil
        return true
    }

    /// Called by the chat flow when the model fills the editor. The generated
    /// SQL is validated immediately so the user sees its status before Run.
    public func setGeneration(_ generation: SQLGenerationResult, schema: DatabaseSchema? = nil) {
        self.generation = generation
        sqlText = generation.sql
        result = nil
        runError = nil
        runFailure = nil
        validate(schema: schema)
    }

    /// Fills the editor with SQL the user typed directly — no generation
    /// metadata. Validated immediately, like a generation.
    public func setDirectSQL(_ sql: String) {
        sqlText = sql
        generation = nil
        result = nil
        runError = nil
        runFailure = nil
        validate()
    }

    /// Restores persisted editor state when a session is rehydrated. Unlike
    /// `setGeneration`, this never treats the SQL as a fresh generation.
    public func restore(sqlText: String, generation: SQLGenerationResult?) {
        self.sqlText = sqlText
        self.generation = generation
        result = nil
        runError = nil
        runFailure = nil
        validation = nil
        schemaValidation = nil
        if !sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validate()
        }
    }

    /// Executes a generated repair attempt without filling the visible SQL
    /// preview first. Failed attempts stay hidden while the model learns from
    /// the database error and tries again.
    func executeGeneratedSQLAttempt(
        sql: String,
        connection: DatabaseConnectionConfig?,
        postgres: PostgresService,
        isConnected: Bool,
        schema: DatabaseSchema? = nil
    ) async -> QueryExecutionAttempt {
        let safety = SQLSafetyValidator.validate(sql)
        let validation =
            schema.map { GeneratedSQLValidator.validate(sql: sql, schema: $0) }
            ?? safety
        guard validation.isValid else {
            let failure = Self.failure(from: AppError.validationFailed(validation.errors))
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: failure.message,
                failure: failure
            )
        }
        // Hard invariant: the auto-retry path never executes a write. If the
        // model produced one, stop here so it never reaches the database.
        guard !validation.kind.isWrite else {
            let failure = QueryFailure(
                message:
                    "The model produced a data-modifying query while repairing a read, so I stopped before showing it."
            )
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: failure.message,
                failure: failure,
                wasUnsafeWrite: true
            )
        }
        guard isConnected, let config = connection else {
            let failure = Self.failure(from: AppError.notConnected)
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: failure.message,
                failure: failure
            )
        }
        guard !isRunning else {
            let failure = QueryFailure(message: "A query is already running.")
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: failure.message,
                failure: failure
            )
        }

        return await withCheckedContinuation { continuation in
            startGeneratedSQLAttempt(
                sql: sql,
                config: config,
                postgres: postgres
            ) { attempt in
                continuation.resume(returning: attempt)
            }
        }
    }

    private func startGeneratedSQLAttempt(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService,
        onFinish: @escaping (QueryExecutionAttempt) -> Void
    ) {
        nextRunID += 1
        let runID = nextRunID
        activeRunID = runID
        activeRunKind = .generatedSQLAttempt
        canStopWaiting = true
        onAttemptFinish = onFinish
        result = nil
        runError = nil
        runFailure = nil
        isRunning = true
        runTask = Task {
            await runGeneratedSQLAttempt(sql: sql, config: config, postgres: postgres, runID: runID)
        }
    }

    private func run(
        sql: String,
        connection: DatabaseConnectionConfig?,
        postgres: PostgresService,
        isConnected: Bool,
        runID: Int,
        confirmed: Bool
    ) async {
        validation = SQLSafetyValidator.validate(sql)
        schemaValidation = nil
        runFailure = nil
        guard let validation, validation.isValid else {
            if isActiveRun(runID) {
                let errors = validation?.errors ?? ["SQL is invalid."]
                let failure = Self.failure(from: AppError.validationFailed(errors))
                runError = failure.message
                runFailure = failure
            }
            finishRun(runID)
            return
        }
        guard isConnected, let config = connection else {
            if isActiveRun(runID) {
                let failure = Self.failure(from: AppError.notConnected)
                runError = failure.message
                runFailure = failure
            }
            finishRun(runID)
            return
        }

        do {
            // Writes run only through `runWrite`; the auto-retry loop never
            // reaches this branch because it uses a separate hidden run path.
            if validation.kind.isWrite, isActiveRun(runID) {
                canStopWaiting = false
            }
            let newResult =
                validation.kind.isWrite
                ? try await executor.runWrite(
                    sql: sql,
                    config: config,
                    postgres: postgres,
                    confirmedDangerous: confirmed
                )
                : try await executor.run(
                    sql: sql,
                    config: config,
                    postgres: postgres
                )
            if isActiveRun(runID) {
                result = newResult
                runFailure = nil
            }
        } catch is CancellationError {
            if isActiveRun(runID) {
                let failure = QueryFailure(message: Self.stoppedWaitingMessage)
                runError = failure.message
                runFailure = failure
            }
        } catch {
            if isActiveRun(runID) {
                let failure = Self.failure(from: error)
                runError = failure.message
                runFailure = failure
            }
        }
        finishRun(runID)
    }

    private func runGeneratedSQLAttempt(
        sql: String,
        config: DatabaseConnectionConfig,
        postgres: PostgresService,
        runID: Int
    ) async {
        let attempt: QueryExecutionAttempt
        do {
            let newResult = try await executor.run(
                sql: sql,
                config: config,
                postgres: postgres
            )
            attempt = QueryExecutionAttempt(result: newResult, errorMessage: nil)
        } catch is CancellationError {
            let failure = QueryFailure(message: Self.stoppedWaitingMessage)
            attempt = QueryExecutionAttempt(
                result: nil,
                errorMessage: failure.message,
                failure: failure
            )
        } catch {
            let failure = Self.failure(from: error)
            attempt = QueryExecutionAttempt(result: nil, errorMessage: failure.message, failure: failure)
        }
        finishGeneratedSQLAttempt(runID, attempt: attempt)
    }

    private func isActiveRun(_ runID: Int) -> Bool {
        activeRunID == runID
    }

    private func finishRun(_ runID: Int) {
        guard isActiveRun(runID) else { return }
        isRunning = false
        runTask = nil
        activeRunID = nil
        activeRunKind = nil
        canStopWaiting = false
        fireCompletion()
    }

    private func finishGeneratedSQLAttempt(_ runID: Int, attempt: QueryExecutionAttempt) {
        guard isActiveRun(runID) else { return }
        result = attempt.result
        runError = attempt.errorMessage
        runFailure = attempt.failure
        isRunning = false
        runTask = nil
        activeRunID = nil
        activeRunKind = nil
        canStopWaiting = false
        fireAttemptCompletion(attempt)
    }

    /// Fires the pending completion exactly once with the final state. The
    /// stored callback is cleared before invoking, so a re-entrant start
    /// inside the callback can never double-fire it.
    private func fireCompletion() {
        let callback = onFinish
        onFinish = nil
        callback?(result, runError)
    }

    private func fireAttemptCompletion(_ attempt: QueryExecutionAttempt) {
        let callback = onAttemptFinish
        onAttemptFinish = nil
        callback?(attempt)
    }

    private static let stoppedWaitingMessage =
        "Stopped waiting for the query. The server may still finish it in the background."

    private static func failure(from error: any Error) -> QueryFailure {
        if let appError = error as? AppError {
            return QueryFailure(
                message: appError.errorDescription ?? appError.localizedDescription,
                diagnostic: appError.databaseDiagnostic
            )
        }
        return QueryFailure(message: error.localizedDescription)
    }

}

private enum ActiveRunKind {
    case visible
    case generatedSQLAttempt
}
