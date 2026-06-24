import Foundation

enum SchemaRetrievalEvalReporter {
    static func write(run: SchemaRetrievalEvalRun, options: EvalCLIOptions) throws -> EvalOutputPaths {
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
        try encoder.encode(run).write(to: paths.run)
        try jsonLines(run.results, to: paths.cases)
        try summaryMarkdown(run).write(to: paths.summary, atomically: true, encoding: .utf8)
        return paths
    }

    private static func outputDirectory(base: String) -> URL {
        URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(DateFormatter.evalTimestamp.string(from: Date()), isDirectory: true)
    }

    private static func jsonLines(_ results: [SchemaRetrievalEvalResult], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try results.map { result in
            String(decoding: try encoder.encode(result), as: UTF8.self)
        }
        .joined(separator: "\n")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func summaryMarkdown(_ run: SchemaRetrievalEvalRun) -> String {
        var lines: [String] = [
            "# Schema Retrieval Eval",
            "",
            "**Evaluation scope:** This run evaluates deterministic schema retrieval only. It does not call Foundation Models, OpenRouter, SQL generation, repair, validation, or PostgreSQL.",
            "",
            "## Run",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Suite | \(tableCell("\(run.manifest.suiteName) v\(run.manifest.suiteVersion)")) |",
            "| Commit | \(tableCell(run.manifest.commitSHA)) |",
            "| Retriever | \(tableCell(run.manifest.retrieverMode)) |",
            "| Cases | \(run.manifest.caseCount) |",
            "| Started | \(tableCell(run.manifest.startedAt)) |",
            "| Finished | \(tableCell(run.manifest.finishedAt)) |",
            "| Acceptance | \(run.acceptance.passed ? "passed" : "failed") |",
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

        for key in run.summaries.keys.sorted() {
            guard let summary = run.summaries[key] else { continue }
            lines += summarySection(summary)
        }

        lines += [
            "## Miss Diagnostics",
            "",
            "| Case | Retriever | Missing Required | Missing Alternatives | Missing Columns | Forbidden Distractors | No-result | Top Results |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for result in run.results.sorted(by: resultSort) where isMiss(result) {
            lines.append(
                "| \(tableCell(result.caseID)) | \(tableCell(result.retriever.rawValue)) | \(tableCell(result.missingRequiredTables.joined(separator: ", "))) | \(tableCell(alternativeGroups(result.missingAlternativeTableGroups))) | \(tableCell(result.missingRequiredColumnMatches.joined(separator: ", "))) | \(tableCell(result.forbiddenDistractorViolations.map(\.table).joined(separator: ", "))) | \(tableCell(noResultStatus(result))) | \(tableCell(result.rankedTables.prefix(8).joined(separator: ", "))) |"
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func summarySection(_ summary: SchemaRetrievalSummary) -> [String] {
        [
            "## \(summary.retriever.rawValue.capitalized) Summary",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Cases | \(summary.caseCount) |",
            "| Required-table Recall@3 | \(percent(summary.requiredTableRecallAt3)) |",
            "| Required-table Recall@5 | \(percent(summary.requiredTableRecallAt5)) |",
            "| Required-table Recall@8 | \(percent(summary.requiredTableRecallAt8)) |",
            "| All required tables present@3 | \(percent(summary.allRequiredTablesPresentAt3)) |",
            "| All required tables present@5 | \(percent(summary.allRequiredTablesPresentAt5)) |",
            "| All required tables present@8 | \(percent(summary.allRequiredTablesPresentAt8)) |",
            "| Primary table top@3 | \(percent(summary.primaryTableTop3)) |",
            "| Primary table MRR | \(String(format: "%.3f", summary.primaryTableMRR)) |",
            "| Alternative group present@3 | \(percent(summary.alternativeGroupPresentAt3)) |",
            "| Alternative group present@5 | \(percent(summary.alternativeGroupPresentAt5)) |",
            "| Alternative group present@8 | \(percent(summary.alternativeGroupPresentAt8)) |",
            "| No-result expectation pass rate | \(percent(summary.noResultExpectationPassRate)) |",
            "| Required join-path recall | \(percent(summary.requiredJoinPathRecall)) |",
            "| Wrong-schema collisions | \(summary.wrongSchemaCollisionCount) |",
            "| No-result/low-signal count | \(summary.noResultOrLowSignalCount) |",
            "| Forbidden distractor violations | \(summary.forbiddenDistractorViolationCount) |",
            "| Index build duration | \(summary.indexBuildDurationMs.map { "\($0) ms" } ?? "-") |",
            "| Index serialized size | \(summary.indexSerializedSizeBytes.map { "\($0) bytes" } ?? "-") |",
            "| Query latency p50 | \(summary.queryLatency.p50Ms) ms |",
            "| Query latency p95 | \(summary.queryLatency.p95Ms) ms |",
            "",
        ]
    }

    private static func isMiss(_ result: SchemaRetrievalEvalResult) -> Bool {
        !result.missingRequiredTables.isEmpty
            || !result.missingAlternativeTableGroups.isEmpty
            || !result.missingRequiredColumnMatches.isEmpty
            || !result.forbiddenDistractorViolations.isEmpty
            || result.noResultExpectationPassed == false
            || result.requiredJoinPathResults.contains { !$0.recovered }
    }

    private static func resultSort(
        _ lhs: SchemaRetrievalEvalResult,
        _ rhs: SchemaRetrievalEvalResult
    ) -> Bool {
        if lhs.caseID == rhs.caseID {
            return lhs.retriever.rawValue < rhs.retriever.rawValue
        }
        return lhs.caseID < rhs.caseID
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func alternativeGroups(_ groups: [[String]]) -> String {
        groups.map { $0.joined(separator: " + ") }.joined(separator: " OR ")
    }

    private static func noResultStatus(_ result: SchemaRetrievalEvalResult) -> String {
        result.noResultExpectationPassed == false ? "failed" : ""
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
