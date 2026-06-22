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
    public var normalizedDefinition: String
    public var referencedObjectIDs: [String]
    public var originatingClarificationID: UUID?
    public var evidence: [String]
    public var createdAt: Date

    public var phrase: String { concept }

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        schemaNames: [String],
        schemaFingerprint: String,
        concept: String,
        definition: String,
        normalizedDefinition: String? = nil,
        referencedObjectIDs: [String] = [],
        originatingClarificationID: UUID? = nil,
        evidence: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.schemaNames = schemaNames.sorted()
        self.schemaFingerprint = schemaFingerprint
        self.concept = concept
        self.definition = definition
        self.normalizedDefinition = normalizedDefinition ?? definition
        self.referencedObjectIDs = referencedObjectIDs
        self.originatingClarificationID = originatingClarificationID
        self.evidence = evidence
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case connectionID
        case schemaNames
        case schemaFingerprint
        case concept
        case definition
        case normalizedDefinition
        case referencedObjectIDs
        case originatingClarificationID
        case evidence
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        connectionID = try container.decode(UUID.self, forKey: .connectionID)
        schemaNames = try container.decode([String].self, forKey: .schemaNames).sorted()
        schemaFingerprint = try container.decode(String.self, forKey: .schemaFingerprint)
        concept = try container.decode(String.self, forKey: .concept)
        definition = try container.decode(String.self, forKey: .definition)
        normalizedDefinition =
            try container.decodeIfPresent(String.self, forKey: .normalizedDefinition)
            ?? definition
        referencedObjectIDs =
            try container.decodeIfPresent([String].self, forKey: .referencedObjectIDs)
            ?? []
        originatingClarificationID =
            try container.decodeIfPresent(UUID.self, forKey: .originatingClarificationID)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connectionID, forKey: .connectionID)
        try container.encode(schemaNames, forKey: .schemaNames)
        try container.encode(schemaFingerprint, forKey: .schemaFingerprint)
        try container.encode(concept, forKey: .concept)
        try container.encode(definition, forKey: .definition)
        try container.encode(normalizedDefinition, forKey: .normalizedDefinition)
        if !referencedObjectIDs.isEmpty {
            try container.encode(referencedObjectIDs, forKey: .referencedObjectIDs)
        }
        try container.encodeIfPresent(originatingClarificationID, forKey: .originatingClarificationID)
        if !evidence.isEmpty {
            try container.encode(evidence, forKey: .evidence)
        }
        try container.encode(createdAt, forKey: .createdAt)
    }

    public func isCurrent(for schema: DatabaseSchema) -> Bool {
        schemaNames == schema.semanticBindingSchemaNames
            && schemaFingerprint == schema.semanticFingerprint
    }

    public var promptLine: String {
        let evidenceText = evidence.isEmpty ? "" : " Evidence: \(evidence.joined(separator: "; "))."
        return "\(concept): \(normalizedDefinition).\(evidenceText)"
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
                        .map {
                            [
                                $0.name,
                                $0.dataType,
                                $0.udtSchema ?? "",
                                $0.udtName ?? "",
                                "\($0.isNullable)",
                                Self.semanticConstraintFingerprint($0.valueConstraints ?? []),
                            ].joined(separator: ":")
                        }
                        .joined(separator: ",")
                    return "\(table.schema).\(table.name):\(table.type.rawValue)[\(columns)]"
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

    private static func semanticConstraintFingerprint(_ constraints: [ColumnValueConstraint]) -> String {
        constraints
            .map { constraint in
                [
                    constraint.kind.rawValue,
                    constraint.constraintName ?? "",
                    constraint.expression ?? "",
                    constraint.values.sorted().joined(separator: ","),
                ].joined(separator: "=")
            }
            .sorted()
            .joined(separator: ";")
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
