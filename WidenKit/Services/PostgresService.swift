import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// Owns the PostgreSQL client lifecycle and runs queries.
public actor PostgresService {
    let logger: Logger

    public init() {
        self.logger = Self.makeLogger(label: "widen.postgres")
    }

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

    /// One-shot connectivity check used by the settings screen. Builds a
    /// transient client, runs `SELECT 1`, and tears everything down. Never
    /// touches the live client.
    public static func testConnection(
        config: DatabaseConnectionConfig,
        password: String?
    ) async throws {
        let logger = makeLogger(label: "widen.postgres.test")
        let client = PostgresClient(
            configuration: makeConfiguration(config, password: password),
            backgroundLogger: logger
        )
        let runTask = Task { await client.run() }
        defer { runTask.cancel() }
        do {
            try await withTimeout(seconds: 15) {
                _ = try await client.query("SELECT 1 AS ok", logger: logger).collect()
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    /// Races `body` against a wall-clock timeout so the UI can never hang on a
    /// stuck connection attempt.
    static func withTimeout<T: Sendable>(
        seconds: Int,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppError.connectionFailed("Timed out waiting for the server to respond.")
            }
            guard let result = try await group.next() else {
                throw AppError.connectionFailed("Timed out waiting for the server to respond.")
            }
            group.cancelAll()
            return result
        }
    }
}
