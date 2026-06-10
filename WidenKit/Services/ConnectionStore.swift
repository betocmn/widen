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

    // The MVP supports a single saved connection; the array on disk keeps the
    // format forward-compatible with multiple connections later.

    public func loadPrimary() throws -> DatabaseConnectionConfig? {
        try load().first
    }

    public func savePrimary(_ config: DatabaseConnectionConfig) throws {
        try save([config])
    }
}
