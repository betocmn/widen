import Foundation

public enum SSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disable
    case prefer
    case require

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Disabled"
        case .prefer: "Prefer"
        case .require: "Require"
        }
    }
}

/// Non-secret connection configuration. The password is intentionally not part
/// of this struct — it is stored in the macOS Keychain, keyed by `id`.
public struct DatabaseConnectionConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var sslMode: SSLMode
    public var defaultRowLimit: Int
    public var statementTimeoutSeconds: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "Local Postgres",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        username: String = "",
        sslMode: SSLMode = .disable,
        defaultRowLimit: Int = 100,
        statementTimeoutSeconds: Int = 10,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.sslMode = sslMode
        self.defaultRowLimit = defaultRowLimit
        self.statementTimeoutSeconds = statementTimeoutSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
