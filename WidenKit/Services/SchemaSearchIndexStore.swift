import CryptoKit
import Foundation

private final class InFlightSchemaIndexBuild: @unchecked Sendable {
    let id = UUID()
    let task: Task<LocalSchemaSearcher, Error>

    init(task: Task<LocalSchemaSearcher, Error>) {
        self.task = task
    }
}

public actor SchemaSearchIndexStore {
    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Widen", isDirectory: true)
            .appendingPathComponent("schema-indexes", isDirectory: true)
    }()

    private let directory: URL
    private let retentionLimit: Int
    private let buildDelayNanoseconds: UInt64
    private var memoryCache: [String: LocalSchemaSearcher] = [:]
    private var inFlightBuilds: [String: InFlightSchemaIndexBuild] = [:]

    public init(
        directory: URL = SchemaSearchIndexStore.defaultDirectory,
        retentionLimit: Int = 12,
        buildDelayNanoseconds: UInt64 = 0
    ) {
        self.directory = directory
        self.retentionLimit = max(1, retentionLimit)
        self.buildDelayNanoseconds = buildDelayNanoseconds
    }

    public func searcher(for snapshot: SchemaSearchSnapshot) async throws -> LocalSchemaSearcher {
        try Task.checkCancellation()
        let key = try Self.cacheKey(for: snapshot)
        let cacheID = key.cacheID
        if let cached = memoryCache[cacheID] {
            try Task.checkCancellation()
            return cached
        }
        if let build = inFlightBuilds[cacheID] {
            return try await finishBuild(build, cacheID: cacheID)
        }

        let directory = directory
        let retentionLimit = retentionLimit
        let delay = buildDelayNanoseconds
        let task = Task.detached(priority: .utility) {
            try await Self.loadOrBuildSearcher(
                snapshot: snapshot,
                key: key,
                directory: directory,
                retentionLimit: retentionLimit,
                buildDelayNanoseconds: delay
            )
        }
        let build = InFlightSchemaIndexBuild(task: task)
        inFlightBuilds[cacheID] = build
        return try await finishBuild(build, cacheID: cacheID)
    }

    public func removeAllCachedSearchers() {
        for build in inFlightBuilds.values {
            build.task.cancel()
        }
        memoryCache.removeAll()
        inFlightBuilds.removeAll()
    }

    private func finishBuild(
        _ build: InFlightSchemaIndexBuild,
        cacheID: String
    ) async throws -> LocalSchemaSearcher {
        do {
            let searcher = try await build.task.value
            memoryCache[cacheID] = searcher
            inFlightBuilds[cacheID] = nil
            try Task.checkCancellation()
            return searcher
        } catch {
            if inFlightBuilds[cacheID]?.id == build.id {
                inFlightBuilds[cacheID] = nil
            }
            throw error
        }
    }

    public static func schemaFingerprint(for schema: DatabaseSchema) throws -> String {
        let payload = SchemaSearchFingerprintPayload(schema: schema)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return sha256(data)
    }

    static func cacheKey(for snapshot: SchemaSearchSnapshot) throws -> SchemaSearchIndexCacheKey {
        SchemaSearchIndexCacheKey(
            connectionID: snapshot.connectionID,
            selectedSchemas: snapshot.selectedSchemas.sorted(),
            schemaFingerprint: try schemaFingerprint(for: snapshot),
            indexFormatVersion: LocalSchemaSearchIndex.formatVersion,
            tokenizerVersion: SchemaSearchTokenizer.version,
            scorerVersion: LocalSchemaSearchIndex.scorerVersion
        )
    }

    private static func schemaFingerprint(for snapshot: SchemaSearchSnapshot) throws -> String {
        let payload = SchemaSearchFingerprintPayload(snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return sha256(data)
    }

    private static func loadOrBuildSearcher(
        snapshot: SchemaSearchSnapshot,
        key: SchemaSearchIndexCacheKey,
        directory: URL,
        retentionLimit: Int,
        buildDelayNanoseconds: UInt64
    ) async throws -> LocalSchemaSearcher {
        try Task.checkCancellation()
        try prepareDirectory(directory)
        if let index = try loadIndex(key: key, directory: directory) {
            return LocalSchemaSearcher(index: index)
        }

        if buildDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: buildDelayNanoseconds)
        }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        var index = LocalSchemaSearchIndex.build(
            snapshot: snapshot,
            fingerprint: key.schemaFingerprint
        )
        index.buildDurationMs = schemaSearchMilliseconds(started.duration(to: .now))
        try Task.checkCancellation()
        index = try writeIndex(index, key: key, directory: directory)
        try pruneStaleIndexes(in: directory, keeping: retentionLimit)
        return LocalSchemaSearcher(index: index)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
    }

    private static func loadIndex(
        key: SchemaSearchIndexCacheKey,
        directory: URL
    ) throws -> LocalSchemaSearchIndex? {
        let url = fileURL(for: key, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(SchemaSearchIndexEnvelope.self, from: data)
            guard envelope.key == key,
                envelope.index.formatVersion == LocalSchemaSearchIndex.formatVersion,
                envelope.index.tokenizerVersion == SchemaSearchTokenizer.version,
                envelope.index.scorerVersion == LocalSchemaSearchIndex.scorerVersion
            else {
                return nil
            }
            var index = envelope.index
            index.serializedSizeBytes = data.count
            return index
        } catch {
            return nil
        }
    }

    private static func writeIndex(
        _ index: LocalSchemaSearchIndex,
        key: SchemaSearchIndexCacheKey,
        directory: URL
    ) throws -> LocalSchemaSearchIndex {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var index = index
        var data = try encoder.encode(SchemaSearchIndexEnvelope(key: key, index: index))
        index.serializedSizeBytes = data.count
        data = try encoder.encode(SchemaSearchIndexEnvelope(key: key, index: index))

        let url = fileURL(for: key, directory: directory)
        let temporaryURL = directory.appendingPathComponent("\(key.cacheID).tmp-\(UUID().uuidString)")
        let fileManager = FileManager.default
        do {
            let created = fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
            guard created else {
                throw CocoaError(.fileWriteUnknown)
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return index
    }

    private static func pruneStaleIndexes(in directory: URL, keeping limit: Int) throws {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return lhsDate > rhsDate
        }
        for url in urls.dropFirst(limit) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func fileURL(for key: SchemaSearchIndexCacheKey, directory: URL) -> URL {
        directory.appendingPathComponent("\(key.cacheID).json")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SchemaSearchIndexCacheKey: Codable, Equatable, Hashable, Sendable {
    var connectionID: UUID
    var selectedSchemas: [String]
    var schemaFingerprint: String
    var indexFormatVersion: Int
    var tokenizerVersion: String
    var scorerVersion: String

    var cacheID: String {
        let text = [
            connectionID.uuidString,
            selectedSchemas.joined(separator: ","),
            schemaFingerprint,
            String(indexFormatVersion),
            tokenizerVersion,
            scorerVersion,
        ]
        .joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct SchemaSearchIndexEnvelope: Codable, Sendable {
    var key: SchemaSearchIndexCacheKey
    var index: LocalSchemaSearchIndex
}

private struct SchemaSearchFingerprintPayload: Codable {
    var schemas: [String]
    var tables: [Table]
    var foreignKeyConstraints: [SchemaForeignKeyConstraintInfo]

    init(schema: DatabaseSchema) {
        self.schemas = schema.schemas.map(\.name).sorted()
        self.tables = schema.tables.sorted {
            if $0.schema == $1.schema {
                return $0.name < $1.name
            }
            return $0.schema < $1.schema
        }
        .map(Table.init(table:))
        self.foreignKeyConstraints = schema.effectiveForeignKeyConstraints
    }

    init(snapshot: SchemaSearchSnapshot) {
        let selected = Set(snapshot.selectedSchemas)
        self.schemas = snapshot.schema.schemas.map(\.name).filter {
            selected.isEmpty || selected.contains($0)
        }
        .sorted()
        self.tables = snapshot.schemaSearchTables.sorted {
            if $0.schema == $1.schema {
                return $0.name < $1.name
            }
            return $0.schema < $1.schema
        }
        .map(Table.init(table:))
        self.foreignKeyConstraints = snapshot.schemaSearchRelationships
    }

    struct Table: Codable {
        var schema: String
        var name: String
        var type: TableType
        var comment: String?
        var columns: [Column]
        var keyConstraints: [SchemaKeyConstraintInfo]

        init(table: TableInfo) {
            self.schema = table.schema
            self.name = table.name
            self.type = table.type
            self.comment = table.comment
            self.columns = table.columns.sorted { $0.ordinalPosition < $1.ordinalPosition }.map(Column.init(column:))
            self.keyConstraints = table.keyConstraints.sorted {
                if $0.kind == $1.kind {
                    return $0.constraintName < $1.constraintName
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    struct Column: Codable {
        var name: String
        var comment: String?
        var dataType: String
        var udtSchema: String?
        var udtName: String?
        var isNullable: Bool
        var ordinalPosition: Int
        var valueConstraints: [ColumnValueConstraint]

        init(column: ColumnInfo) {
            self.name = column.name
            self.comment = column.comment
            self.dataType = column.dataType
            self.udtSchema = column.udtSchema
            self.udtName = column.udtName
            self.isNullable = column.isNullable
            self.ordinalPosition = column.ordinalPosition
            self.valueConstraints = (column.valueConstraints ?? []).sorted {
                if $0.kind == $1.kind {
                    return ($0.constraintName ?? "") < ($1.constraintName ?? "")
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }
}
