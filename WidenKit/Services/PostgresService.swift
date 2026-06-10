import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// Owns the PostgreSQL client lifecycle and runs queries.
///
/// Lifecycle: `connect` creates a pooled `PostgresClient` and starts its
/// `run()` loop in a long-lived task; `disconnect` cancels that task, which
/// closes the client. A client is never reused after its run task is
/// cancelled — reconnecting always builds a fresh client.
public actor PostgresService {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    let logger: Logger

    public init() {
        self.logger = Self.makeLogger(label: "widen.postgres")
    }

    public var isConnected: Bool { client != nil }

    /// Establishes a new client and verifies connectivity, so authentication
    /// and missing-database errors surface immediately.
    public func connect(config: DatabaseConnectionConfig, password: String?) async throws {
        disconnect()
        // Probe with a single throwaway connection first: the pooled client
        // retries failed connections in the background, so server FATALs
        // (bad credentials, missing database) would otherwise only surface as
        // a generic timeout.
        try await Self.probe(config: config, password: password)

        let client = PostgresClient(
            configuration: Self.makeConfiguration(config, password: password),
            backgroundLogger: logger
        )
        self.client = client
        // `run()` must be called exactly once per client; cancelling the task
        // closes the client and its connections.
        self.runTask = Task { await client.run() }
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        client = nil
    }

    /// Runs a read query and decodes every row inside the actor, so only
    /// `Sendable` values cross the actor boundary.
    public func query<T: Sendable>(
        _ sql: String,
        decode: @escaping @Sendable (PostgresRandomAccessRow) throws -> T
    ) async throws -> [T] {
        guard let client else { throw AppError.notConnected }
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var results: [T] = []
            for try await row in rows {
                results.append(try decode(row.makeRandomAccess()))
            }
            return results
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    /// Executes a validated query inside a read-only transaction with a
    /// statement timeout, pinned to a single pooled connection.
    ///
    /// When `hasLimit` is false the query is wrapped in a
    /// `LIMIT rowLimit + 1` subquery: the extra row only signals truncation
    /// and is dropped from the returned result.
    public func executeReadOnly(
        sql: String,
        hasLimit: Bool,
        rowLimit: Int,
        timeoutSeconds: Int
    ) async throws -> QueryResult {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let start = ContinuousClock.now
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN READ ONLY", logger: logger)
                do {
                    // SET cannot take bind parameters; timeoutSeconds is
                    // app-validated (1…120).
                    try await connection.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = \(timeoutSeconds * 1000)"),
                        logger: logger
                    )

                    let finalSQL =
                        hasLimit
                        ? sql
                        : "SELECT * FROM (\n\(sql)\n) AS widen_subquery LIMIT \(rowLimit + 1)"
                    let stream = try await connection.query(
                        PostgresQuery(unsafeSQL: finalSQL),
                        logger: logger
                    )

                    let columns = stream.columns.map(\.name)
                    var rows: [[String?]] = []
                    for try await row in stream {
                        let randomAccess = row.makeRandomAccess()
                        rows.append(
                            (0..<randomAccess.count).map {
                                PostgresCellFormatter.string(for: randomAccess[$0])
                            }
                        )
                    }
                    try await connection.query("COMMIT", logger: logger)

                    var truncated = false
                    if !hasLimit, rows.count > rowLimit {
                        truncated = true
                        rows.removeLast()
                    }
                    let elapsed = start.duration(to: .now)
                    return QueryResult(
                        columns: columns,
                        rows: rows,
                        rowCount: rows.count,
                        truncated: truncated,
                        executionTimeMs: Int(elapsed / .milliseconds(1))
                    )
                } catch {
                    // Leave the pooled connection in a clean state.
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    // MARK: - Configuration

    static func makeLogger(label: String) -> Logger {
        var logger = Logger(label: label)
        logger.logLevel = .critical
        return logger
    }

    nonisolated static func makeConfiguration(
        _ config: DatabaseConnectionConfig,
        password: String?
    ) -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch config.sslMode {
        case .disable:
            tls = .disable
        case .prefer, .require:
            // Local-development semantics: encrypt the connection but do not
            // verify the server certificate (local Postgres typically uses a
            // self-signed certificate, if any). Documented in the README.
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            tls = config.sslMode == .prefer ? .prefer(tlsConfig) : .require(tlsConfig)
        }

        var configuration = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: (password?.isEmpty ?? true) ? nil : password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        configuration.options.connectTimeout = .seconds(10)
        configuration.options.minimumConnections = 0
        configuration.options.maximumConnections = 4
        return configuration
    }

    /// One-shot connectivity check used by the settings screen. Never touches
    /// the live client.
    public static func testConnection(
        config: DatabaseConnectionConfig,
        password: String?
    ) async throws {
        try await probe(config: config, password: password)
    }

    /// Opens a single direct connection, runs `SELECT 1`, and closes it.
    /// Unlike the pooled client, a direct connection throws the server's real
    /// error (authentication failure, unknown database, refused connection)
    /// immediately.
    static func probe(config: DatabaseConnectionConfig, password: String?) async throws {
        let logger = makeLogger(label: "widen.postgres.probe")
        do {
            let configuration = try makeConnectionConfiguration(config, password: password)
            try await withTimeout(seconds: 15) {
                let connection = try await PostgresConnection.connect(
                    on: PostgresConnection.defaultEventLoopGroup.any(),
                    configuration: configuration,
                    id: 1,
                    logger: logger
                )
                do {
                    _ = try await connection.query("SELECT 1 AS ok", logger: logger).collect()
                    try await connection.close()
                } catch {
                    try? await connection.close()
                    throw error
                }
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    nonisolated static func makeConnectionConfiguration(
        _ config: DatabaseConnectionConfig,
        password: String?
    ) throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS
        switch config.sslMode {
        case .disable:
            tls = .disable
        case .prefer, .require:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            // Unlike the pooled client, the direct-connection API takes a
            // pre-built NIOSSLContext.
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            tls = config.sslMode == .prefer ? .prefer(sslContext) : .require(sslContext)
        }
        return PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: (password?.isEmpty ?? true) ? nil : password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
    }

    /// Races `body` against a wall-clock timeout so the UI can never hang on a
    /// stuck connection attempt.
    static func withTimeout<T: Sendable>(
        seconds: Int,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TimeoutRaceState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let workerTask = Task {
                    do {
                        let value = try await body()
                        state.complete(.success(value), cancelWorker: false)
                    } catch {
                        state.complete(.failure(error), cancelWorker: false)
                    }
                }
                let timerTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        state.complete(
                            .failure(
                                AppError.connectionFailed(
                                    "Timed out waiting for the server to respond.")),
                            cancelWorker: true
                        )
                    } catch {
                        // The worker completed or the caller cancelled first.
                    }
                }
                state.install(
                    continuation: continuation,
                    workerTask: workerTask,
                    timerTask: timerTask
                )
            }
        } onCancel: {
            state.complete(.failure(CancellationError()), cancelWorker: true)
        }
    }
}

private final class TimeoutRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var workerTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var result: Result<T, any Error>?

    func install(
        continuation: CheckedContinuation<T, any Error>,
        workerTask: Task<Void, Never>,
        timerTask: Task<Void, Never>
    ) {
        let completed: Result<T, any Error>?

        lock.lock()
        if let result {
            completed = result
        } else {
            completed = nil
            self.continuation = continuation
            self.workerTask = workerTask
            self.timerTask = timerTask
        }
        lock.unlock()

        if let completed {
            workerTask.cancel()
            timerTask.cancel()
            continuation.resume(with: completed)
        }
    }

    func complete(_ result: Result<T, any Error>, cancelWorker: Bool) {
        let continuationToResume: CheckedContinuation<T, any Error>?
        let workerTaskToCancel: Task<Void, Never>?
        let timerTaskToCancel: Task<Void, Never>?

        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuationToResume = continuation
        workerTaskToCancel = workerTask
        timerTaskToCancel = timerTask
        continuation = nil
        workerTask = nil
        timerTask = nil
        lock.unlock()

        if cancelWorker {
            workerTaskToCancel?.cancel()
        }
        timerTaskToCancel?.cancel()
        continuationToResume?.resume(with: result)
    }
}
