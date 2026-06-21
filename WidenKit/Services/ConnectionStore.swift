import Foundation

/// Persists non-secret connection configuration as JSON in
/// `~/Library/Application Support/Widen/connections.json`.
/// Passwords never go through this store — they live in the Keychain.
public struct ConnectionStore: Sendable {
    let fileURL: URL

    /// - Parameter directory: Overridable for tests; defaults to
    ///   `~/Library/Application Support/Widen`.
    public init(directory: URL? = nil) {
        let dir =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("connections.json")
    }

    public func load() throws -> [DatabaseConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DatabaseConnectionConfig].self, from: data)
    }

    public func save(_ configs: [DatabaseConnectionConfig]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct DatabaseSemanticBinding: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var schemaNames: [String]
    public var schemaFingerprint: String
    public var concept: String
    public var definition: String
    public var evidence: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        schemaNames: [String],
        schemaFingerprint: String,
        concept: String,
        definition: String,
        evidence: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.schemaNames = schemaNames.sorted()
        self.schemaFingerprint = schemaFingerprint
        self.concept = concept
        self.definition = definition
        self.evidence = evidence
        self.createdAt = createdAt
    }

    public func isCurrent(for schema: DatabaseSchema) -> Bool {
        schemaNames == schema.semanticBindingSchemaNames
            && schemaFingerprint == schema.semanticFingerprint
    }

    public var promptLine: String {
        let evidenceText = evidence.isEmpty ? "" : " Evidence: \(evidence.joined(separator: "; "))."
        return "\(concept): \(definition).\(evidenceText)"
    }
}

public struct DatabaseSemanticBindingStore: Sendable {
    let fileURL: URL

    public init(directory: URL? = nil) {
        let dir =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("semantic-bindings.json")
    }

    public func load() throws -> [DatabaseSemanticBinding] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DatabaseSemanticBinding].self, from: data)
    }

    public func save(_ bindings: [DatabaseSemanticBinding]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bindings)
        try data.write(to: fileURL, options: .atomic)
    }

    public func currentBindings(
        _ bindings: [DatabaseSemanticBinding],
        connectionID: UUID,
        schema: DatabaseSchema
    ) -> [DatabaseSemanticBinding] {
        bindings.filter {
            $0.connectionID == connectionID && $0.isCurrent(for: schema)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }
}

extension DatabaseSchema {
    public var semanticBindingSchemaNames: [String] {
        Array(Set(schemas.map(\.name) + tables.map(\.schema))).sorted()
    }

    public var semanticFingerprint: String {
        let parts = [
            semanticBindingSchemaNames.joined(separator: ","),
            tables
                .sorted { $0.qualifiedName < $1.qualifiedName }
                .map { table in
                    let columns = table.columns
                        .sorted { $0.ordinalPosition < $1.ordinalPosition }
                        .map { "\($0.name):\($0.dataType):\($0.isNullable)" }
                        .joined(separator: ",")
                    return "\(table.schema).\(table.name)[\(columns)]"
                }
                .joined(separator: "|"),
            foreignKeys
                .sorted { $0.summary < $1.summary }
                .map {
                    "\($0.constraintName):\($0.summary)"
                }
                .joined(separator: "|"),
        ].joined(separator: "\n")
        return Self.stableFingerprint(parts)
    }

    private static func stableFingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
