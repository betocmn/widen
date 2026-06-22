import Foundation

import WidenKit

struct EvalOutputPaths {
    var directory: URL
    var run: URL
    var cases: URL
    var summary: URL
}

enum EvalReporter {
    static func write(run: EvalRun, options: EvalCLIOptions) throws -> EvalOutputPaths {
        let directory = outputDirectory(base: options.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = EvalOutputPaths(
            directory: directory,
            run: directory.appendingPathComponent("run.json"),
            cases: directory.appendingPathComponent("cases.jsonl"),
            summary: directory.appendingPathComponent("summary.md")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = EvalRunFile(manifest: run.manifest, summary: run.summary)
        try encoder.encode(manifest).write(to: paths.run)
        try jsonLines(run.results, to: paths.cases)
        try summaryMarkdown(run).write(to: paths.summary, atomically: true, encoding: .utf8)
        return paths
    }

    private static func outputDirectory(base: String) -> URL {
        let timestamp = DateFormatter.evalTimestamp.string(from: Date())
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
    }

    private static func jsonLines(_ results: [TextToSQLEvalResult], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try results.map { result in
            let data = try encoder.encode(result)
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func summaryMarkdown(_ run: EvalRun) -> String {
        let summary = run.summary
        let passRate = String(format: "%.1f%%", summary.passRate * 100)
        let averageTableCoverage = String(
            format: "%.1f%%",
            summary.averageRequiredTableCoverage * 100
        )
        let averageColumnCoverage = String(
            format: "%.1f%%",
            summary.averageRequiredColumnBindingCoverage * 100
        )
        let averageLatency = String(format: "%.1f", summary.latency.averageMs)
        let averagePromptSize = summary.averagePromptSize.map { String(format: "%.0f", $0) } ?? "-"
        let maxPromptSize = summary.maxPromptSize.map(String.init) ?? "-"
        let modelCalls = summary.totalModelCalls.map(String.init) ?? "-"

        var lines: [String] = [
            "# Text-to-SQL Eval Baseline",
            "",
            "## Run",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Suite | \(run.manifest.suiteName) v\(run.manifest.suiteVersion) |",
            "| Commit | \(run.manifest.commitSHA) |",
            "| Started | \(run.manifest.startedAt) |",
            "| Finished | \(run.manifest.finishedAt) |",
            "| Backend | \(run.manifest.backendMode) |",
            "| Model | \(run.manifest.model ?? "-") |",
            "| OS | \(run.manifest.osVersion) |",
            "| Architecture | \(run.manifest.architecture) |",
            "| Cases | \(run.manifest.caseCount) |",
            "| Repeats | \(run.manifest.repeatCount) |",
            "",
            "## Schema Fixtures",
            "",
            "| Fixture | SHA-256 |",
            "| --- | --- |",
        ]
        for key in run.manifest.schemaFixtureHashes.keys.sorted() {
            lines.append("| \(key) | \(run.manifest.schemaFixtureHashes[key] ?? "-") |")
        }

        lines += [
            "",
            "## Summary",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Results | \(summary.totalResults) |",
            "| Passed | \(summary.passed) |",
            "| Pass rate | \(passRate) |",
            "| Backend available | \(summary.backendAvailable) |",
            "| Transport success | \(summary.transportSuccess) |",
            "| Structured response parsed | \(summary.structuredResponseParsed) |",
            "| Decision matches | \(summary.decisionMatches) |",
            "| Safety valid | \(summary.safetyValid) |",
            "| Schema valid | \(summary.schemaValid) |",
            "| Forbidden binding violations | \(summary.forbiddenBindingViolationCount) |",
            "| Avg required-table coverage | \(averageTableCoverage) |",
            "| Avg required-column coverage | \(averageColumnCoverage) |",
            "| Total model calls | \(modelCalls) |",
            "| Avg prompt size | \(averagePromptSize) |",
            "| Max prompt size | \(maxPromptSize) |",
            "| Token usage | unavailable |",
            "| Estimated cloud cost | unavailable |",
            "",
            "## Latency",
            "",
            "| Metric | Milliseconds |",
            "| --- | ---: |",
            "| Min | \(summary.latency.minMs) |",
            "| Average | \(averageLatency) |",
            "| P50 | \(summary.latency.p50Ms) |",
            "| P95 | \(summary.latency.p95Ms) |",
            "| Max | \(summary.latency.maxMs) |",
            "",
            "## Status Counts",
            "",
            "| Status | Count |",
            "| --- | ---: |",
        ]
        for status in TextToSQLEvalCaseStatus.allCases {
            lines.append("| \(status.rawValue) | \(summary.statusCounts[status.rawValue, default: 0]) |")
        }

        lines += [
            "",
            "## Per Case",
            "",
            "| Case | Backend | Repeat | Status | Diagnostics |",
            "| --- | --- | ---: | --- | --- |",
        ]
        for result in run.results.sorted(by: resultSort) {
            lines.append(
                "| \(result.caseID) | \(result.backend.rawValue) | \(result.repeatIndex) | \(result.status.rawValue) | \(diagnosticsSummary(result)) |"
            )
        }

        lines += [
            "",
            "Raw prompts and raw model output are intentionally omitted from this summary.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func resultSort(
        _ lhs: TextToSQLEvalResult,
        _ rhs: TextToSQLEvalResult
    ) -> Bool {
        if lhs.caseID != rhs.caseID { return lhs.caseID < rhs.caseID }
        if lhs.backend.rawValue != rhs.backend.rawValue {
            return lhs.backend.rawValue < rhs.backend.rawValue
        }
        return lhs.repeatIndex < rhs.repeatIndex
    }

    private static func diagnosticsSummary(_ result: TextToSQLEvalResult) -> String {
        var parts: [String] = []
        if !result.diagnostics.missingTables.isEmpty {
            parts.append("missing tables: \(result.diagnostics.missingTables.joined(separator: ", "))")
        }
        if !result.diagnostics.missingColumnBindings.isEmpty {
            parts.append(
                "missing columns: \(result.diagnostics.missingColumnBindings.joined(separator: ", "))"
            )
        }
        if !result.diagnostics.missingOperations.isEmpty {
            parts.append(
                "missing ops: \(result.diagnostics.missingOperations.map(\.rawValue).joined(separator: ", "))"
            )
        }
        if !result.metrics.forbiddenBindingViolations.isEmpty {
            parts.append(
                "forbidden: \(result.metrics.forbiddenBindingViolations.joined(separator: ", "))"
            )
        }
        if !result.diagnostics.safetyErrors.isEmpty {
            parts.append("safety: \(result.diagnostics.safetyErrors.joined(separator: " "))")
        }
        if !result.diagnostics.schemaErrors.isEmpty {
            parts.append("schema: \(result.diagnostics.schemaErrors.joined(separator: " "))")
        }
        if let error = result.diagnostics.errorMessage {
            parts.append(error)
        }
        return parts.isEmpty ? "-" : parts.joined(separator: "; ").replacingOccurrences(of: "|", with: "\\|")
    }
}

private struct EvalRunFile: Codable {
    var manifest: EvalRunManifest
    var summary: EvalRunSummary
}

extension DateFormatter {
    fileprivate static let evalTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
