import Foundation

/// Persists query sessions as JSON in
/// `~/Library/Application Support/Widen/sessions.json`.
/// All sessions — including archived ones — live in this single file:
/// transcripts are small text, so one atomic write keeps persistence simple.
public struct SessionStore: Sendable {
    /// Thrown by `load()` when sessions.json exists but can't be decoded.
    /// The caller starts with no sessions and its next save rewrites the
    /// file, so the original is copied to `backupURL` first.
    public struct UnreadableFileError: LocalizedError, Sendable {
        public var backupURL: URL
        public var decodingError: DecodingError

        public var errorDescription: String? {
            "The saved sessions file could not be read. A copy was kept as \(backupURL.lastPathComponent)."
        }
    }

    let fileURL: URL

    /// - Parameter directory: Overridable for tests; defaults to
    ///   `~/Library/Application Support/Widen`.
    public init(directory: URL? = nil) {
        let dir =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")
    }

    public func load() throws -> [QuerySession] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([QuerySession].self, from: data)
        } catch let decodingError as DecodingError {
            let backupURL = unreadableFileBackupURL(at: Date())
            do {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            } catch {
                // Without a copy there is nothing to point at; report the
                // original problem.
                throw decodingError
            }
            throw UnreadableFileError(backupURL: backupURL, decodingError: decodingError)
        }
    }

    /// `sessions.unreadable-<timestamp>.json` beside the original. The
    /// timestamp is ISO 8601 basic format (`20261101T120000Z`): colons would
    /// show up as slashes in Finder.
    func unreadableFileBackupURL(at date: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("sessions.unreadable-\(formatter.string(from: date)).json")
    }

    public func save(_ sessions: [QuerySession]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions)
        try data.write(to: fileURL, options: .atomic)
    }
}
