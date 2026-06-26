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
    public var databaseContext: String
    public var allowCloudSchemaMetadata: Bool
    public var allowLocalDataInspection: Bool
    public var allowCloudDataInspection: Bool
    public var allowSampleRowInspection: Bool
    public var sensitiveColumnRules: [String]
    public var redactedColumnIDs: [String]
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
        databaseContext: String = "",
        allowCloudSchemaMetadata: Bool = true,
        allowLocalDataInspection: Bool = false,
        allowCloudDataInspection: Bool = false,
        allowSampleRowInspection: Bool = false,
        sensitiveColumnRules: [String] = [],
        redactedColumnIDs: [String] = [],
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
        self.databaseContext = databaseContext
        self.allowCloudSchemaMetadata = allowCloudSchemaMetadata
        self.allowLocalDataInspection = allowLocalDataInspection
        self.allowCloudDataInspection = allowCloudDataInspection
        self.allowSampleRowInspection = allowSampleRowInspection
        self.sensitiveColumnRules = sensitiveColumnRules
        self.redactedColumnIDs = redactedColumnIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case database
        case username
        case sslMode
        case defaultRowLimit
        case statementTimeoutSeconds
        case databaseContext
        case allowCloudSchemaMetadata
        case allowLocalDataInspection
        case allowCloudDataInspection
        case allowSampleRowInspection
        case sensitiveColumnRules
        case redactedColumnIDs
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        sslMode = try container.decode(SSLMode.self, forKey: .sslMode)
        defaultRowLimit = try container.decode(Int.self, forKey: .defaultRowLimit)
        statementTimeoutSeconds = try container.decode(Int.self, forKey: .statementTimeoutSeconds)
        databaseContext = try container.decodeIfPresent(String.self, forKey: .databaseContext) ?? ""
        allowCloudSchemaMetadata = try container.decodeIfPresent(Bool.self, forKey: .allowCloudSchemaMetadata) ?? true
        allowLocalDataInspection = try container.decodeIfPresent(Bool.self, forKey: .allowLocalDataInspection) ?? false
        allowCloudDataInspection = try container.decodeIfPresent(Bool.self, forKey: .allowCloudDataInspection) ?? false
        allowSampleRowInspection = try container.decodeIfPresent(Bool.self, forKey: .allowSampleRowInspection) ?? false
        sensitiveColumnRules = try container.decodeIfPresent([String].self, forKey: .sensitiveColumnRules) ?? []
        redactedColumnIDs = try container.decodeIfPresent([String].self, forKey: .redactedColumnIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(database, forKey: .database)
        try container.encode(username, forKey: .username)
        try container.encode(sslMode, forKey: .sslMode)
        try container.encode(defaultRowLimit, forKey: .defaultRowLimit)
        try container.encode(statementTimeoutSeconds, forKey: .statementTimeoutSeconds)
        try container.encode(databaseContext, forKey: .databaseContext)
        try container.encode(allowCloudSchemaMetadata, forKey: .allowCloudSchemaMetadata)
        try container.encode(allowLocalDataInspection, forKey: .allowLocalDataInspection)
        try container.encode(allowCloudDataInspection, forKey: .allowCloudDataInspection)
        try container.encode(allowSampleRowInspection, forKey: .allowSampleRowInspection)
        try container.encode(sensitiveColumnRules, forKey: .sensitiveColumnRules)
        try container.encode(redactedColumnIDs, forKey: .redactedColumnIDs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
