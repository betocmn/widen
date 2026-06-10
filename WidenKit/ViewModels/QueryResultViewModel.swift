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

    private var runTask: Task<Void, Never>?
    private let executor = QueryExecutionService()

    public init() {}

    public func validate() {
        validation = SQLSafetyValidator.validate(sqlText)
    }

    /// Starts the query in a cancellable task. Cancellation only stops the app
    /// from waiting — the server-side guard is the statement timeout.
    public func startRun(appState: AppState) {
        guard !isRunning else { return }
        runTask = Task {
            await run(appState: appState)
        }
    }

    public func cancelRun() {
        runTask?.cancel()
        runTask = nil
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

    private func run(appState: AppState) async {
        runError = nil
        validate()
        guard let validation, validation.isValid else { return }
        guard appState.connectionStatus == .connected, let config = appState.config else {
            runError = AppError.notConnected.errorDescription
            return
        }

        isRunning = true
        defer { isRunning = false }
        do {
            result = try await executor.run(
                sql: sqlText,
                config: config,
                postgres: appState.postgres
            )
        } catch is CancellationError {
            runError = "Stopped waiting for the query. The server may still finish it in the background."
        } catch {
            runError = error.localizedDescription
        }
    }
}
