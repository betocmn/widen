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
        let manifest = EvalRunFile(
            manifest: run.manifest,
            summary: run.summary,
            backendSummaries: Dictionary(
                uniqueKeysWithValues: run.backendSummaries.map { ($0.key.rawValue, $0.value) }
            )
        )
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
        var lines: [String] = [
            "# Text-to-SQL Eval Baseline",
            "",
            "**Evaluation scope:** The eval invokes the shared production text-to-SQL pipeline through local validation and validation-only repair, then applies a static-shape score to the final decision. It does not establish result-set or semantic correctness.",
            "",
            "## Run",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Suite | \(tableCell("\(run.manifest.suiteName) v\(run.manifest.suiteVersion)")) |",
            "| Evaluation mode | \(tableCell(run.manifest.evaluationMode)) |",
            "| Commit | \(tableCell(run.manifest.commitSHA)) |",
            "| Started | \(tableCell(run.manifest.startedAt)) |",
            "| Finished | \(tableCell(run.manifest.finishedAt)) |",
            "| Backend | \(tableCell(run.manifest.backendMode)) |",
            "| Model | \(tableCell(run.manifest.model ?? "-")) |",
            "| OS | \(tableCell(run.manifest.osVersion)) |",
            "| Architecture | \(tableCell(run.manifest.architecture)) |",
            "| Cases | \(run.manifest.caseCount) |",
            "| Repeats | \(run.manifest.repeatCount) |",
            "",
            "## Baseline Compatibility Hashes",
            "",
            "These deterministic hashes establish baseline compatibility for the suite, pipeline/scorer sources, and schema fixtures. The commit that adds a baseline cannot be recorded in that baseline's own committed content.",
            "",
            "| Artifact | SHA-256 |",
            "| --- | --- |",
            "| Suite file | \(tableCell(run.manifest.suiteFileHash)) |",
            "| Pipeline/scorer sources (\(tableCell(run.manifest.scorerVersion))) | \(tableCell(run.manifest.scorerSourceHash)) |",
            "",
            "## Schema Fixture Hashes",
            "",
            "| Fixture | SHA-256 |",
            "| --- | --- |",
        ]
        for key in run.manifest.schemaFixtureHashes.keys.sorted() {
            lines.append(
                "| \(tableCell(key)) | \(tableCell(run.manifest.schemaFixtureHashes[key] ?? "-")) |"
            )
        }

        lines += summarySection(title: "Summary", summary: run.summary)
        if run.backendSummaries.count > 1 {
            for backend in sortedBackends(run.backendSummaries.keys) {
                guard let summary = run.backendSummaries[backend] else { continue }
                lines += summarySection(
                    title: "\(backend.rawValue.capitalized) Summary",
                    summary: summary
                )
            }
        }

        lines += statusCountSection(title: "Status Counts", summary: run.summary)
        if run.backendSummaries.count > 1 {
            for backend in sortedBackends(run.backendSummaries.keys) {
                guard let summary = run.backendSummaries[backend] else { continue }
                lines += statusCountSection(
                    title: "\(backend.rawValue.capitalized) Status Counts",
                    summary: summary
                )
            }
        }

        if run.manifest.repeatCount > 1 {
            lines += repeatStabilitySections(results: run.results)
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
                "| \(tableCell(result.caseID)) | \(tableCell(result.backend.rawValue)) | \(result.repeatIndex) | \(tableCell(result.status.rawValue)) | \(diagnosticsSummary(result)) |"
            )
        }

        lines += [
            "",
            "Estimated initial prompts and raw model output are intentionally omitted from this summary.",
            "The estimated initial prompt character metrics are pre-call estimates from the eval runner, not the exact model prompt after discovery, truncation, or retry behavior.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func summarySection(title: String, summary: EvalRunSummary) -> [String] {
        let averageLatency = String(format: "%.1f", summary.latency.averageMs)
        let averagePromptSize = summary.averageEstimatedInitialPromptCharacters
            .map { String(format: "%.0f", $0) } ?? "-"
        let maxPromptSize = summary.maxEstimatedInitialPromptCharacters.map(String.init) ?? "-"
        let modelCalls = summary.totalModelCalls.map(String.init) ?? "-"

        return [
            "",
            "## \(title)",
            "",
            "| Metric | Value |",
            "| --- | --- |",
            "| Results | \(summary.totalResults) |",
            "| Passed | \(summary.passed) |",
            "| Static-shape pass rate | \(percent(summary.passRate)) |",
            "| Backend available | \(count(summary.backendAvailable)) |",
            "| Transport success | \(count(summary.transportSuccess, suffix: " evaluated")) |",
            "| Structured response parsed | \(count(summary.structuredResponseParsed, suffix: " evaluated")) |",
            "| Decision matches | \(count(summary.decisionMatches)) |",
            "| Safety valid | \(count(summary.safetyValid, suffix: " evaluated")) |",
            "| Schema valid | \(count(summary.schemaValid, suffix: " evaluated")) |",
            "| Forbidden binding violations | \(summary.forbiddenBindingViolationCount) |",
            "| Average required-table coverage | \(average(summary.requiredTableCoverage, suffix: " SQL results evaluated")) |",
            "| Average required-column coverage | \(average(summary.requiredColumnBindingCoverage, suffix: " SQL results evaluated")) |",
            "| Total model calls | \(modelCalls) |",
            "| Avg estimated initial prompt characters | \(averagePromptSize) |",
            "| Max estimated initial prompt characters | \(maxPromptSize) |",
            "| Token usage | unavailable |",
            "| Estimated cloud cost | unavailable |",
            "",
            "### Latency",
            "",
            "| Metric | Milliseconds |",
            "| --- | ---: |",
            "| Min | \(summary.latency.minMs) |",
            "| Average | \(averageLatency) |",
            "| P50 | \(summary.latency.p50Ms) |",
            "| P95 | \(summary.latency.p95Ms) |",
            "| Max | \(summary.latency.maxMs) |",
        ]
    }

    private static func statusCountSection(title: String, summary: EvalRunSummary) -> [String] {
        var lines = [
            "",
            "## \(title)",
            "",
            "| Status | Count |",
            "| --- | ---: |",
        ]
        for status in TextToSQLEvalCaseStatus.allCases {
            lines.append("| \(status.rawValue) | \(summary.statusCounts[status.rawValue, default: 0]) |")
        }
        return lines
    }

    private static func repeatStabilitySections(results: [TextToSQLEvalResult]) -> [String] {
        let caseSummaries = repeatCaseSummaries(results: results)
        let backendGroups = Dictionary(grouping: caseSummaries, by: \.backend)

        var lines = [
            "",
            "## Repeat Stability",
            "",
            "| Backend | Stable passes | Cases | Stable pass rate | Flaky cases |",
            "| --- | ---: | ---: | ---: | --- |",
        ]
        for backend in sortedBackends(backendGroups.keys) {
            let summaries = backendGroups[backend] ?? []
            let stablePasses = summaries.filter(\.stablePass).count
            let flakyCases = summaries.filter(\.flaky).map(\.caseID).sorted()
            let rate = summaries.isEmpty ? 0 : Double(stablePasses) / Double(summaries.count)
            lines.append(
                "| \(tableCell(backend.rawValue)) | \(stablePasses) | \(summaries.count) | \(percent(rate)) | \(tableCell(flakyCases.isEmpty ? "-" : flakyCases.joined(separator: ", "))) |"
            )
        }

        lines += [
            "",
            "## Per Case Repeat Stability",
            "",
            "| Case | Backend | Pass count | Statuses |",
            "| --- | --- | ---: | --- |",
        ]
        for summary in caseSummaries.sorted(by: repeatCaseSort) {
            lines.append(
                "| \(tableCell(summary.caseID)) | \(tableCell(summary.backend.rawValue)) | \(summary.passCount)/\(summary.repeatCount) | \(tableCell(summary.statuses.joined(separator: ", "))) |"
            )
        }
        return lines
    }

    private struct RepeatCaseSummary {
        var caseID: String
        var backend: TextToSQLEvalBackend
        var passCount: Int
        var repeatCount: Int
        var statuses: [String]
        var stablePass: Bool
        var flaky: Bool
    }

    private static func repeatCaseSummaries(
        results: [TextToSQLEvalResult]
    ) -> [RepeatCaseSummary] {
        let grouped = Dictionary(grouping: results) {
            "\($0.backend.rawValue)\u{1F}\($0.caseID)"
        }
        return grouped.values.map { values in
            let sorted = values.sorted { $0.repeatIndex < $1.repeatIndex }
            let passCount = sorted.filter { $0.status == .passed }.count
            let statuses = sorted.map(\.status.rawValue)
            return RepeatCaseSummary(
                caseID: sorted.first?.caseID ?? "-",
                backend: sorted.first?.backend ?? .local,
                passCount: passCount,
                repeatCount: sorted.count,
                statuses: statuses,
                stablePass: passCount == sorted.count,
                flaky: Set(statuses).count > 1
            )
        }
    }

    private static func repeatCaseSort(
        _ lhs: RepeatCaseSummary,
        _ rhs: RepeatCaseSummary
    ) -> Bool {
        if lhs.backend.rawValue != rhs.backend.rawValue {
            return lhs.backend.rawValue < rhs.backend.rawValue
        }
        return lhs.caseID < rhs.caseID
    }

    private static func sortedBackends<S: Sequence>(
        _ backends: S
    ) -> [TextToSQLEvalBackend] where S.Element == TextToSQLEvalBackend {
        backends.sorted { $0.rawValue < $1.rawValue }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func count(_ metric: EvalCountSummary, suffix: String = "") -> String {
        "\(metric.count)/\(metric.denominator)\(suffix)"
    }

    private static func average(_ metric: EvalAverageSummary, suffix: String = "") -> String {
        guard let average = metric.average else {
            return "- (0\(suffix))"
        }
        return "\(percent(average)) (\(metric.denominator)\(suffix))"
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
        return parts.isEmpty ? "-" : tableCell(parts.joined(separator: "; "))
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct EvalRunFile: Codable {
    var manifest: EvalRunManifest
    var summary: EvalRunSummary
    var backendSummaries: [String: EvalRunSummary]
}

extension DateFormatter {
    fileprivate static let evalTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
