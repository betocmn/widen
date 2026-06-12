import Foundation
import Observation

@MainActor
@Observable
public final class ConnectionSettingsViewModel {
    public enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private struct FormSnapshot: Equatable {
        var name: String
        var host: String
        var portText: String
        var database: String
        var username: String
        var password: String
        var sslMode: SSLMode
        var rowLimitText: String
        var timeoutText: String
        var databaseContext: String
    }

    public var name = ""
    public var host = "localhost"
    public var portText = "5432"
    public var database = ""
    public var username = "postgres"
    public var password = ""
    public var sslMode: SSLMode = .disable
    public var rowLimitText = "100"
    public var timeoutText = "10"
    public var databaseContext = ""

    public private(set) var validationErrors: [String] = []
    public private(set) var testState: TestState = .idle
    public private(set) var saveError: String?
    public private(set) var isSaving = false

    private var existing: DatabaseConnectionConfig?
    private var cleanSnapshot: FormSnapshot?
    private let keychain = KeychainService()
    private let connectionTester: @Sendable (DatabaseConnectionConfig, String) async throws -> Void

    public var hasUnsavedChanges: Bool {
        cleanSnapshot != currentSnapshot
    }

    public init(
        connectionTester: @escaping @Sendable (DatabaseConnectionConfig, String) async throws ->
            Void = { config, password in
                try await PostgresService.testConnection(config: config, password: password)
            }
    ) {
        self.connectionTester = connectionTester
        markClean()
    }

    /// Prefills the form from a saved connection (password from the Keychain).
    public func load(from config: DatabaseConnectionConfig) {
        existing = config
        name = config.name
        host = config.host
        portText = String(config.port)
        database = config.database
        username = config.username
        sslMode = config.sslMode
        rowLimitText = String(config.defaultRowLimit)
        timeoutText = String(config.statementTimeoutSeconds)
        databaseContext = config.databaseContext
        password = (try? keychain.loadPassword(for: config.id)) ?? ""
        validationErrors = []
        testState = .idle
        saveError = nil
        markClean()
    }

    /// Validates the form per the roadmap rules and builds a config, or
    /// records the validation errors and returns nil.
    public func buildConfig() -> DatabaseConnectionConfig? {
        let result = makeConfig()
        validationErrors = result.errors
        return result.config
    }

    public func testConnection() async {
        let result = makeConfig()
        guard let config = result.config else {
            validationErrors = []
            testState = .failure(result.errors.joined(separator: "\n"))
            return
        }
        validationErrors = []
        testState = .testing
        do {
            try await connectionTester(config, password)
            testState = .success
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func makeConfig() -> (config: DatabaseConnectionConfig?, errors: [String]) {
        var errors: [String] = []

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty {
            errors.append("Host is required.")
        }
        let port = Int(portText.trimmingCharacters(in: .whitespaces))
        if port.map({ (1...65535).contains($0) }) != true {
            errors.append("Port must be between 1 and 65535.")
        }
        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        if trimmedDatabase.isEmpty {
            errors.append("Database is required.")
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        if trimmedUsername.isEmpty {
            errors.append("Username is required.")
        }
        // Password may be empty: local Postgres often uses trust auth.
        let rowLimit = Int(rowLimitText.trimmingCharacters(in: .whitespaces))
        if rowLimit.map({ (1...10_000).contains($0) }) != true {
            errors.append("Row limit must be between 1 and 10,000.")
        }
        let timeout = Int(timeoutText.trimmingCharacters(in: .whitespaces))
        if timeout.map({ (1...120).contains($0) }) != true {
            errors.append("Timeout must be between 1 and 120 seconds.")
        }
        let trimmedDatabaseContext = databaseContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDatabaseContext.count > SQLPromptBuilder.maxDatabaseContextCharacters {
            errors.append(
                "Query context must be \(SQLPromptBuilder.maxDatabaseContextCharacters.formatted()) characters or fewer."
            )
        }

        guard errors.isEmpty, let port, let rowLimit, let timeout else {
            return (nil, errors)
        }

        var config = existing ?? DatabaseConnectionConfig()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        config.name = trimmedName.isEmpty ? trimmedDatabase : trimmedName
        config.host = trimmedHost
        config.port = port
        config.database = trimmedDatabase
        config.username = trimmedUsername
        config.sslMode = sslMode
        config.defaultRowLimit = rowLimit
        config.statementTimeoutSeconds = timeout
        config.databaseContext = trimmedDatabaseContext
        config.updatedAt = Date()
        return (config, [])
    }

    /// Saves the config (JSON) and password (Keychain). There is no eager
    /// connect — databases connect lazily when one of their sessions is
    /// selected. Returns the saved config on success.
    @discardableResult
    public func save(appState: AppState) -> DatabaseConnectionConfig? {
        guard let config = buildConfig() else { return nil }
        saveError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try appState.addOrUpdateConnection(config, password: password)
        } catch {
            saveError = error.localizedDescription
            return nil
        }
        existing = config
        markClean()
        return config
    }

    /// Resets the form to its defaults for a brand-new connection.
    public func startNew() {
        existing = nil
        name = ""
        host = "localhost"
        portText = "5432"
        database = ""
        username = "postgres"
        password = ""
        sslMode = .disable
        rowLimitText = "100"
        timeoutText = "10"
        databaseContext = ""
        validationErrors = []
        testState = .idle
        saveError = nil
        markClean()
    }

    private var currentSnapshot: FormSnapshot {
        FormSnapshot(
            name: name,
            host: host,
            portText: portText,
            database: database,
            username: username,
            password: password,
            sslMode: sslMode,
            rowLimitText: rowLimitText,
            timeoutText: timeoutText,
            databaseContext: databaseContext
        )
    }

    private func markClean() {
        cleanSnapshot = currentSnapshot
    }
}
