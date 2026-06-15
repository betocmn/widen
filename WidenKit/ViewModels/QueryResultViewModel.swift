import Foundation
import Observation

struct QueryExecutionAttempt {
    var result: QueryResult?
    var errorMessage: String?
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
    public private(set) var result: QueryResult?
    public private(set) var isRunning = false
    public private(set) var runError: String?
    /// Metadata of the last model generation that filled the editor.
    public private(set) var generation: SQLGenerationResult?

    private var activeRunID: Int?
    private var nextRunID = 0
    private var runTask: Task<Void, Never>?
    private var onFinish: RunCompletion?
    private let executor: any QueryExecuting

    public init() {
        self.executor = QueryExecutionService()
    }

    init(executor: any QueryExecuting) {
        self.executor = executor
    }

    public func validate() {
        validation = SQLSafetyValidator.validate(sqlText)
    }

    /// Starts the query in a cancellable task. Cancellation only stops the app
    /// from waiting — the server-side guard is the statement timeout.
    public func startRun(
        connection: DatabaseConnectionConfig?,
        postgres: PostgresService,
        isConnected: Bool,
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
        result = nil
        runError = nil
        isRunning = true
        runTask = Task {
            await run(
                sql: runSQL,
                connection: connection, postgres: postgres,
                isConnected: isConnected, runID: runID)
        }
    }

    public func cancelRun() {
        cancelActiveRun(reportError: true, fireCompletion: true)
    }

    private func discardActiveRun() {
        cancelActiveRun(reportError: false, fireCompletion: false)
    }

    private func cancelActiveRun(reportError: Bool, fireCompletion shouldFire: Bool) {
        runTask?.cancel()
        runTask = nil
        activeRunID = nil
        if isRunning {
            isRunning = false
            if reportError {
                runError = "Stopped waiting for the query. The server may still finish it in the background."
            }
        }
        if shouldFire {
            fireCompletion()
        } else {
            onFinish = nil
        }
    }

    public func clear() {
        discardActiveRun()
        sqlText = ""
        validation = nil
        result = nil
        runError = nil
        generation = nil
    }

    func clearGeneratedSQLForRetry() {
        discardActiveRun()
        sqlText = ""
        validation = nil
        result = nil
        runError = nil
        generation = nil
    }

    /// Called by the chat flow when the model fills the editor. The generated
    /// SQL is validated immediately so the user sees its status before Run.
    public func setGeneration(_ generation: SQLGenerationResult) {
        self.generation = generation
        sqlText = generation.sql
        result = nil
        runError = nil
        validate()
    }

    /// Fills the editor with SQL the user typed directly — no generation
    /// metadata. Validated immediately, like a generation.
    public func setDirectSQL(_ sql: String) {
        sqlText = sql
        generation = nil
        result = nil
        runError = nil
        validate()
    }

    /// Restores persisted editor state when a session is rehydrated. Unlike
    /// `setGeneration`, this never treats the SQL as a fresh generation.
    public func restore(sqlText: String, generation: SQLGenerationResult?) {
        self.sqlText = sqlText
        self.generation = generation
        result = nil
        runError = nil
        validation = nil
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
        isConnected: Bool
    ) async -> QueryExecutionAttempt {
        let validation = SQLSafetyValidator.validate(sql)
        guard validation.isValid else {
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: AppError.validationFailed(validation.errors).localizedDescription
            )
        }
        guard isConnected, let config = connection else {
            return QueryExecutionAttempt(
                result: nil,
                errorMessage: AppError.notConnected.errorDescription
            )
        }

        do {
            let result = try await executor.run(
                sql: sql,
                config: config,
                postgres: postgres
            )
            return QueryExecutionAttempt(result: result, errorMessage: nil)
        } catch is CancellationError {
            return QueryExecutionAttempt(
                result: nil,
                errorMessage:
                    "Stopped waiting for the query. The server may still finish it in the background."
            )
        } catch {
            return QueryExecutionAttempt(result: nil, errorMessage: error.localizedDescription)
        }
    }

    private func run(
        sql: String,
        connection: DatabaseConnectionConfig?,
        postgres: PostgresService,
        isConnected: Bool,
        runID: Int
    ) async {
        validation = SQLSafetyValidator.validate(sql)
        guard let validation, validation.isValid else {
            if isActiveRun(runID) {
                let errors = validation?.errors ?? ["SQL is invalid."]
                runError = AppError.validationFailed(errors).localizedDescription
            }
            finishRun(runID)
            return
        }
        guard isConnected, let config = connection else {
            if isActiveRun(runID) {
                runError = AppError.notConnected.errorDescription
            }
            finishRun(runID)
            return
        }

        do {
            let newResult = try await executor.run(
                sql: sql,
                config: config,
                postgres: postgres
            )
            if isActiveRun(runID) {
                result = newResult
            }
        } catch is CancellationError {
            if isActiveRun(runID) {
                runError = "Stopped waiting for the query. The server may still finish it in the background."
            }
        } catch {
            if isActiveRun(runID) {
                runError = error.localizedDescription
            }
        }
        finishRun(runID)
    }

    private func isActiveRun(_ runID: Int) -> Bool {
        activeRunID == runID
    }

    private func finishRun(_ runID: Int) {
        guard isActiveRun(runID) else { return }
        isRunning = false
        runTask = nil
        activeRunID = nil
        fireCompletion()
    }

    /// Fires the pending completion exactly once with the final state. The
    /// stored callback is cleared before invoking, so a re-entrant start
    /// inside the callback can never double-fire it.
    private func fireCompletion() {
        let callback = onFinish
        onFinish = nil
        callback?(result, runError)
    }
}
