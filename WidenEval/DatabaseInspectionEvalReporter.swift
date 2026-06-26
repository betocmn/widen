import Foundation

enum DatabaseInspectionEvalReporter {
    static func write(run: DatabaseInspectionEvalRun, options: EvalCLIOptions) throws -> EvalOutputPaths {
        let directory = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
            .appendingPathComponent(DateFormatter.evalTimestamp.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = EvalOutputPaths(
            directory: directory,
            run: directory.appendingPathComponent("run.json"),
            cases: directory.appendingPathComponent("cases.jsonl"),
            summary: directory.appendingPathComponent("summary.md")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: paths.run)
        try jsonLines(run.results, to: paths.cases)
        try summaryMarkdown(run).write(to: paths.summary, atomically: true, encoding: .utf8)
        return paths
    }

    private static func jsonLines(_ results: [DatabaseInspectionEvalResult], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try results.map { result in
            String(decoding: try encoder.encode(result), as: UTF8.self)
        }
        .joined(separator: "\n")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func summaryMarkdown(_ run: DatabaseInspectionEvalRun) -> String {
        var lines: [String] = [
            "# Database Inspection Tool Eval",
            "",
            "**Evaluation scope:** Deterministic database-inspection tools only. No LLM, SQL generation, validation, repair, schema retrieval scoring, or OpenRouter calls are used.",
            "",
            "## Run",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Suite | \(tableCell("\(run.manifest.suiteName) v\(run.manifest.suiteVersion)")) |",
            "| Commit | \(tableCell(run.manifest.commitSHA)) |",
            "| Cases | \(run.manifest.caseCount) |",
            "| Started | \(tableCell(run.manifest.startedAt)) |",
            "| Finished | \(tableCell(run.manifest.finishedAt)) |",
            "| Deterministic digest | \(tableCell(run.manifest.deterministicDigest)) |",
            "| Acceptance | \(run.acceptance.passed ? "passed" : "failed") |",
            "",
            "## Summary",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Cases | \(run.summary.caseCount) |",
            "| Passed | \(run.summary.passed) |",
            "| Failed | \(run.summary.failed) |",
            "| Calls attempted | \(run.summary.callsAttempted) |",
            "| Policy-denied calls | \(run.summary.policyDeniedCalls) |",
            "| Redacted values | \(run.summary.redactedValues) |",
            "| Max result bytes | \(run.summary.maxResultBytes) |",
            "| Truncations | \(run.summary.truncationCount) |",
            "| Total latency | \(run.summary.totalLatencyMs) ms |",
            "",
        ]
        if !run.acceptance.messages.isEmpty {
            lines += [
                "## Acceptance Messages",
                "",
            ]
            lines += run.acceptance.messages.map { "- \($0)" }
            lines.append("")
        }
        lines += [
            "## Cases",
            "",
            "| Case | Passed | Calls | Policy denied | Redacted | Bytes | Latency | Truncated | Digest | Messages |",
            "| --- | --- | ---: | ---: | ---: | --- | ---: | --- | --- | --- |",
        ]
        for result in run.results.sorted(by: { $0.caseID < $1.caseID }) {
            lines.append(
                "| \(tableCell(result.caseID)) | \(result.passed ? "yes" : "no") | \(result.callsAttempted) | \(result.policyDeniedCalls) | \(result.redactedValues) | \(tableCell(result.resultByteSizes.map(String.init).joined(separator: ", "))) | \(result.latencyMs) ms | \(result.truncated ? "yes" : "no") | \(tableCell(String(result.deterministicDigest.prefix(12)))) | \(tableCell(result.messages.joined(separator: "; "))) |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
