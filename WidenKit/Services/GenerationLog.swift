import Foundation

public struct PromptTelemetry: Codable, Equatable, Sendable {
    public var phase: String
    public var estimatedTokens: Int
    public var estimatedEnvelopeTokens: Int
    public var selectedTables: [String]
    public var pinnedTables: [String]
    public var scoreReasons: [String: [String]]
    public var validationIssueIDs: [String]
    public var canonicalizationFixes: [String]
    public var callCount: Int
    public var stopReason: String

    public init(
        phase: String,
        estimatedTokens: Int,
        estimatedEnvelopeTokens: Int,
        selectedTables: [String],
        pinnedTables: [String],
        scoreReasons: [String: [String]],
        validationIssueIDs: [String] = [],
        canonicalizationFixes: [String] = [],
        callCount: Int = 1,
        stopReason: String
    ) {
        self.phase = phase
        self.estimatedTokens = estimatedTokens
        self.estimatedEnvelopeTokens = estimatedEnvelopeTokens
        self.selectedTables = selectedTables
        self.pinnedTables = pinnedTables
        self.scoreReasons = scoreReasons
        self.validationIssueIDs = validationIssueIDs
        self.canonicalizationFixes = canonicalizationFixes
        self.callCount = callCount
        self.stopReason = stopReason
    }

    public init(
        phase: SQLGenerationMode,
        package: SchemaPromptPackage,
        context: SQLGenerationContext,
        callCount: Int,
        stopReason: String
    ) {
        let diagnostics = package.diagnostics
        self.init(
            phase: phase.rawValue,
            estimatedTokens: diagnostics.estimatedTokens,
            estimatedEnvelopeTokens: diagnostics.estimatedEnvelopeTokens,
            selectedTables: diagnostics.includedTables,
            pinnedTables: diagnostics.pinnedTables,
            scoreReasons: Dictionary(
                uniqueKeysWithValues: diagnostics.rankedTables.map {
                    ($0.tableID, $0.reasons)
                }
            ),
            validationIssueIDs: Self.validationIssueIDs(from: context),
            canonicalizationFixes: context.repairContext?.repairConstraints.compactMap {
                switch $0.kind {
                case .forbiddenIdentifier:
                    nil
                case .forbiddenUnquotedIdentifier:
                    "quote:\($0.identifier)"
                }
            } ?? [],
            callCount: callCount,
            stopReason: stopReason
        )
    }

    public var logDescription: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
            let text = String(data: data, encoding: .utf8)
        else {
            return "phase=\(phase) selectedTables=\(selectedTables.joined(separator: ",")) stopReason=\(stopReason)"
        }
        return text
    }

    private static func validationIssueIDs(from context: SQLGenerationContext) -> [String] {
        var ids: [String] = []
        if let diagnostic = context.repairContext?.diagnostic {
            ids.append(diagnostic.kind.rawValue)
            if let sqlState = diagnostic.sqlState {
                ids.append(sqlState)
            }
            if let identifier = diagnostic.identifierForRepair {
                ids.append(identifier)
            }
        }
        ids.append(contentsOf: context.repairContext?.forbiddenIdentifiers ?? [])
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Append-only debug log of every on-device generation: the full prompt and
/// the structured result (or the error). Written to
/// `~/Library/Application Support/Widen/generation.log` — local only, plain
/// text, meant for inspecting what the small local model actually saw and
/// said. Logging failures are swallowed; debugging must never break
/// generation.
public actor GenerationLog {
    public static let shared = GenerationLog()

    private let fileURL: URL
    private var isEnabled: Bool

    /// - Parameter directory: override for tests; defaults to
    ///   `~/Library/Application Support/Widen`.
    public init(directory: URL? = nil, isEnabled: Bool = true) {
        let base =
            directory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Widen", isDirectory: true)
        self.fileURL = base.appendingPathComponent("generation.log")
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func append(
        prompt: String,
        outcome: String,
        durationMs: Int,
        telemetry: PromptTelemetry? = nil
    ) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let telemetryText = telemetry.map {
            """
            --- telemetry ---
            \($0.logDescription)

            """
        } ?? ""
        let entry = """
            ==== \(stamp) · \(durationMs) ms ====
            \(telemetryText)
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
