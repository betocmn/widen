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

    public var name = "Local Postgres"
    public var host = "localhost"
    public var portText = "5432"
    public var database = ""
    public var username = NSUserName()
    public var password = ""
    public var sslMode: SSLMode = .disable
    public var rowLimitText = "100"
    public var timeoutText = "10"

    public private(set) var validationErrors: [String] = []
    public private(set) var testState: TestState = .idle
    public private(set) var saveError: String?
    public private(set) var isSaving = false

    private var existing: DatabaseConnectionConfig?
    private let keychain = KeychainService()

    public init() {}

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
        password = (try? keychain.loadPassword(for: config.id)) ?? ""
        validationErrors = []
        testState = .idle
        saveError = nil
    }

    /// Validates the form per the roadmap rules and builds a config, or
    /// records the validation errors and returns nil.
    public func buildConfig() -> DatabaseConnectionConfig? {
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

        validationErrors = errors
        guard errors.isEmpty, let port, let rowLimit, let timeout else { return nil }

        var config = existing ?? DatabaseConnectionConfig()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        config.name = trimmedName.isEmpty ? "Local Postgres" : trimmedName
        config.host = trimmedHost
        config.port = port
        config.database = trimmedDatabase
        config.username = trimmedUsername
        config.sslMode = sslMode
        config.defaultRowLimit = rowLimit
        config.statementTimeoutSeconds = timeout
        config.updatedAt = Date()
        return config
    }

    public func testConnection() async {
        guard let config = buildConfig() else {
            testState = .idle
            return
        }
        testState = .testing
        do {
            try await PostgresService.testConnection(config: config, password: password)
            testState = .success
        } catch {
            testState = .failure(error.localizedDescription)
        }
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
        return config
    }

    /// Resets the form to its defaults for a brand-new connection.
    public func startNew() {
        existing = nil
        name = "Local Postgres"
        host = "localhost"
        portText = "5432"
        database = ""
        username = NSUserName()
        password = ""
        sslMode = .disable
        rowLimitText = "100"
        timeoutText = "10"
        validationErrors = []
        testState = .idle
        saveError = nil
    }
}
