import Foundation
import Observation

/// State for the SQL editor and results panels.
@MainActor
@Observable
public final class QueryResultViewModel {
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
    public func startRun(appState: AppState) {
        guard !isRunning else { return }
        nextRunID += 1
        let runID = nextRunID
        activeRunID = runID
        result = nil
        runError = nil
        isRunning = true
        runTask = Task {
            await run(appState: appState, runID: runID)
        }
    }

    public func cancelRun() {
        runTask?.cancel()
        runTask = nil
        activeRunID = nil
        if isRunning {
            isRunning = false
            runError = "Stopped waiting for the query. The server may still finish it in the background."
        }
    }

    public func clear() {
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

    private func run(appState: AppState, runID: Int) async {
        validate()
        guard let validation, validation.isValid else {
            finishRun(runID)
            return
        }
        guard appState.connectionStatus == .connected, let config = appState.config else {
            if isActiveRun(runID) {
                runError = AppError.notConnected.errorDescription
            }
            finishRun(runID)
            return
        }

        do {
            let newResult = try await executor.run(
                sql: sqlText,
                config: config,
                postgres: appState.postgres
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
    }
}
