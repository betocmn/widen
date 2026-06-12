import Foundation

/// Persists database schema snapshots as JSON in
/// `~/Library/Application Support/Widen/schemas.json`.
/// Schemas are keyed by connection id so duplicate connection records do not
/// share cached structure accidentally.
public struct SchemaStore: Sendable {
    let fileURL: URL

    /// - Parameter directory: Overridable for tests; defaults to
    ///   `~/Library/Application Support/Widen`.
    public init(directory: URL? = nil) {
        let dir =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("schemas.json")
    }

    public func load() throws -> [UUID: DatabaseSchema] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode([String: DatabaseSchema].self, from: data)
        return raw.reduce(into: [:]) { result, pair in
            if let id = UUID(uuidString: pair.key) {
                result[id] = pair.value
            }
        }
    }

    public func save(_ schemas: [UUID: DatabaseSchema]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = Dictionary(uniqueKeysWithValues: schemas.map { ($0.key.uuidString, $0.value) })
        let data = try encoder.encode(raw)
        try data.write(to: fileURL, options: .atomic)
    }
}
