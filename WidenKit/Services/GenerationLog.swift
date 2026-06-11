import Foundation

/// Append-only debug log of every on-device generation: the full prompt and
/// the structured result (or the error). Written to
/// `~/Library/Application Support/Widen/generation.log` — local only, plain
/// text, meant for inspecting what the small local model actually saw and
/// said. Logging failures are swallowed; debugging must never break
/// generation.
public actor GenerationLog {
    public static let shared = GenerationLog()

    private let fileURL: URL

    /// - Parameter directory: override for tests; defaults to
    ///   `~/Library/Application Support/Widen`.
    public init(directory: URL? = nil) {
        let base =
            directory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = base.appendingPathComponent("generation.log")
    }

    public func append(prompt: String, outcome: String, durationMs: Int) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = """
            ==== \(stamp) · \(durationMs) ms ====
            --- prompt ---
            \(prompt)
            --- outcome ---
            \(outcome)


            """
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } catch {
            // Intentionally ignored.
        }
    }
}
