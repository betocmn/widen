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
            evaluationScope(for: run),
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
            "| Cloud agent | \(tableCell(run.manifest.cloudAgentMode ?? "-")) |",
            "| Model | \(tableCell(run.manifest.model ?? "-")) |",
            "| OS | \(tableCell(run.manifest.osVersion)) |",
            "| Architecture | \(tableCell(run.manifest.architecture)) |",
            "| Cases | \(run.manifest.caseCount) |",
            "| Repeats | \(run.manifest.repeatCount) |",
            "| Case timeout | \(run.manifest.caseTimeoutSeconds) seconds |",
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
        lines += postgresVerificationStatusCountSection(
            title: "PostgreSQL Verification Status Counts",
            summary: run.summary
        )
        lines += openRouterSection(results: run.results)
        lines += semanticStatusCountSection(title: "Semantic Status Counts", summary: run.summary)
        lines += staticSemanticCrossTabSection(title: "Static/Semantic Cross-Tab", summary: run.summary)
        if run.backendSummaries.count > 1 {
            for backend in sortedBackends(run.backendSummaries.keys) {
                guard let summary = run.backendSummaries[backend] else { continue }
                lines += statusCountSection(
                    title: "\(backend.rawValue.capitalized) Status Counts",
                    summary: summary
                )
                lines += semanticStatusCountSection(
                    title: "\(backend.rawValue.capitalized) Semantic Status Counts",
                    summary: summary
                )
                lines += postgresVerificationStatusCountSection(
                    title: "\(backend.rawValue.capitalized) PostgreSQL Verification Status Counts",
                    summary: summary
                )
                lines += staticSemanticCrossTabSection(
                    title: "\(backend.rawValue.capitalized) Static/Semantic Cross-Tab",
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
            "| Case | Backend | Repeat | Static Status | PostgreSQL Verification | Semantic Status | Semantic Result | Diagnostics |",
            "| --- | --- | ---: | --- | --- | --- | --- | --- |",
        ]
        for result in run.results.sorted(by: resultSort) {
            lines.append(
                "| \(tableCell(result.caseID)) | \(tableCell(result.backend.rawValue)) | \(result.repeatIndex) | \(tableCell(result.status.rawValue)) | \(tableCell(result.metrics.postgresVerificationStatus?.rawValue ?? "-")) | \(tableCell(result.metrics.semanticStatus?.rawValue ?? "-")) | \(semanticSummary(result)) | \(diagnosticsSummary(result)) |"
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

    private static func evaluationScope(for run: EvalRun) -> String {
        if run.manifest.evaluationMode == "openrouter-transport-smoke" {
            return "**Evaluation scope:** The smoke run invokes the shared production text-to-SQL pipeline only to exercise OpenRouter transport, request-mode selection, structured-response parsing, retry accounting, and safe provider diagnostics. It does not establish SQL semantic accuracy."
        }

        let verificationAttempted = postgresVerificationAttempted(in: run.summary)

        if run.manifest.evaluationMode.contains("seeded-postgres-semantic") {
            let verificationClause = verificationAttempted
                ? "through local validation and PostgreSQL verification, "
                : "through local validation, "
            return "**Evaluation scope:** The eval invokes the shared production text-to-SQL pipeline \(verificationClause)keeps the static-shape score, then independently executes eligible final SQL decisions against seeded PostgreSQL fixtures for semantic result-set grading."
        }

        let verificationClause = verificationAttempted
            ? "through local validation and PostgreSQL verification, "
            : "through local validation and validation-only repair, "
        return "**Evaluation scope:** The eval invokes the shared production text-to-SQL pipeline \(verificationClause)then applies a static-shape score to the final decision. It does not establish result-set or semantic correctness."
    }

    private static func postgresVerificationAttempted(in summary: EvalRunSummary) -> Bool {
        guard let counts = summary.postgresVerificationStatusCounts else { return false }
        return (counts[SQLVerificationStatus.passed.rawValue, default: 0]
            + counts[SQLVerificationStatus.failed.rawValue, default: 0]) > 0
    }

    private static func summarySection(title: String, summary: EvalRunSummary) -> [String] {
        let averageLatency = String(format: "%.1f", summary.latency.averageMs)
        let averagePromptSize = summary.averageEstimatedInitialPromptCharacters
            .map { String(format: "%.0f", $0) } ?? "-"
        let maxPromptSize = summary.maxEstimatedInitialPromptCharacters.map(String.init) ?? "-"
        let modelCalls = summary.totalModelCalls.map(String.init) ?? "-"
        let tokenUsage = summary.totalTokenUsage.map(String.init) ?? "-"
        let cloudCost = summary.estimatedCloudCostUSD
            .map { String(format: "$%.6f", $0) } ?? "-"
        let schemaToolCalls = summary.totalSchemaToolCalls.map(String.init) ?? "-"
        let inspectionToolCalls = summary.totalInspectionToolCalls.map(String.init) ?? "-"
        let agentTurns = summary.totalAgentModelTurns.map(String.init) ?? "-"
        let agentHTTPAttempts = summary.totalAgentHTTPAttempts.map(String.init) ?? "-"
        let toolBudgetFailures = summary.toolBudgetFailureCount.map(String.init) ?? "-"

        return [
            "",
            "## \(title)",
            "",
            "| Metric | Value |",
            "| --- | --- |",
            "| Results | \(summary.totalResults) |",
            "| Passed | \(summary.passed) |",
            "| Static-shape pass rate | \(percent(summary.passRate)) |",
            "| Semantic end-to-end passed | \(summary.semanticPassed.map(String.init) ?? "-") |",
            "| Semantic end-to-end pass rate | \(summary.semanticPassRate.map(percent) ?? "-") |",
            "| SQL semantic pass rate | \(summary.sqlSemanticPass.map { count($0) } ?? "-") |",
            "| Clarification decision pass rate | \(summary.clarificationDecisionPass.map { count($0) } ?? "-") |",
            "| Overall end-to-end pass rate | \(summary.endToEndPass.map { count($0) } ?? "-")\(summary.endToEndPassRate.map { " (\(percent($0)))" } ?? "") |",
            "| Semantic environment available | \(summary.semanticEnvironmentAvailable.map { count($0) } ?? "-") |",
            "| Semantic execution attempted | \(summary.semanticExecutionAttempted.map { count($0) } ?? "-") |",
            "| Semantic result equivalent | \(summary.resultEquivalent.map { count($0) } ?? "-") |",
            "| Golden execution succeeded | \(summary.goldenExecutionSucceeded.map { count($0) } ?? "-") |",
            "| Candidate execution succeeded | \(summary.candidateExecutionSucceeded.map { count($0) } ?? "-") |",
            "| Backend available | \(count(summary.backendAvailable)) |",
            "| Transport success | \(count(summary.transportSuccess, suffix: " evaluated")) |",
            "| Structured response parsed | \(count(summary.structuredResponseParsed, suffix: " evaluated")) |",
            "| Decision matches | \(count(summary.decisionMatches)) |",
            "| Safety valid | \(count(summary.safetyValid, suffix: " evaluated")) |",
            "| Schema valid | \(count(summary.schemaValid, suffix: " evaluated")) |",
            "| PostgreSQL verification attempted pass rate | \(summary.postgresVerificationAttemptedPass.map { count($0) } ?? "-") |",
            "| Forbidden binding violations | \(summary.forbiddenBindingViolationCount) |",
            "| Average required-table coverage | \(average(summary.requiredTableCoverage, suffix: " SQL results evaluated")) |",
            "| Average required-column coverage | \(average(summary.requiredColumnBindingCoverage, suffix: " SQL results evaluated")) |",
            "| Total model calls | \(modelCalls) |",
            "| Schema-tool calls | \(schemaToolCalls) |",
            "| Inspection-tool calls | \(inspectionToolCalls) |",
            "| Agent logical model turns | \(agentTurns) |",
            "| Agent HTTP attempts | \(agentHTTPAttempts) |",
            "| Tool-budget failures | \(toolBudgetFailures) |",
            "| Avg estimated initial prompt characters | \(averagePromptSize) |",
            "| Max estimated initial prompt characters | \(maxPromptSize) |",
            "| Token usage | \(tokenUsage) |",
            "| Estimated cloud cost | \(cloudCost) |",
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

    private static func postgresVerificationStatusCountSection(
        title: String,
        summary: EvalRunSummary
    ) -> [String] {
        guard let counts = summary.postgresVerificationStatusCounts else { return [] }
        var lines = [
            "",
            "## \(title)",
            "",
            "| Status | Count |",
            "| --- | ---: |",
        ]
        for status in SQLVerificationStatus.allCases {
            lines.append("| \(status.rawValue) | \(counts[status.rawValue, default: 0]) |")
        }
        return lines
    }

    private static func openRouterSection(results: [TextToSQLEvalResult]) -> [String] {
        let openRouterResults = results.filter { result in
            result.backend == .cloud
                && (
                    result.metrics.openRouterStructuredOutputMode != nil
                        || result.metrics.openRouterRetryCount != nil
                        || result.metrics.openRouterRequestedModelID != nil
                        || result.diagnostics.openRouterFailureCategory != nil
                        || result.metrics.openRouterAgentSelectionReason != nil
                        || result.metrics.openRouterAgentLogicalTurnCount != nil
                        || result.metrics.openRouterAgentHTTPAttemptCount != nil
                        || result.metrics.openRouterSchemaToolCallCount != nil
                        || result.metrics.openRouterInspectionToolCallCount != nil
                        || result.metrics.openRouterAgentTerminalOutcome != nil
                )
        }
        guard !openRouterResults.isEmpty else { return [] }

        let retries = openRouterResults.compactMap(\.metrics.openRouterRetryCount)
        let retryTotal = retries.reduce(0, +)
        let retryAverage = retries.isEmpty ? "-" : String(format: "%.2f", Double(retryTotal) / Double(retries.count))
        let tokenUsage = openRouterResults.compactMap(\.metrics.tokenUsage).reduce(0, +)
        let cost = openRouterResults.compactMap(\.metrics.estimatedCloudCostUSD).reduce(0, +)
        let failureCounts = counts(openRouterResults.compactMap(\.diagnostics.openRouterFailureCategory))
        let modeCounts = counts(openRouterResults.compactMap(\.metrics.openRouterStructuredOutputMode))
        let returnedModelCounts = counts(
            openRouterResults.compactMap {
                $0.metrics.openRouterReturnedModelID ?? $0.diagnostics.openRouterReturnedModelID
            }
        )
        let providerCounts = counts(
            openRouterResults.compactMap {
                $0.metrics.openRouterProviderName ?? $0.diagnostics.openRouterProviderName
            }
        )
        let selectionCounts = counts(openRouterResults.compactMap(\.metrics.openRouterAgentSelectionReason))
        let terminalCounts = counts(openRouterResults.compactMap(\.metrics.openRouterAgentTerminalOutcome))
        let schemaToolCalls = openRouterResults.compactMap(\.metrics.openRouterSchemaToolCallCount)
            .reduce(0, +)
        let inspectionToolCalls = openRouterResults.compactMap(\.metrics.openRouterInspectionToolCallCount)
            .reduce(0, +)
        let agentTurns = openRouterResults.compactMap(\.metrics.openRouterAgentLogicalTurnCount)
            .reduce(0, +)
        let agentHTTPAttempts = openRouterResults.compactMap(\.metrics.openRouterAgentHTTPAttemptCount)
            .reduce(0, +)

        var lines = [
            "",
            "## OpenRouter Transport",
            "",
            "| Metric | Value |",
            "| --- | --- |",
            "| HTTP success | \(count(EvalCountSummary(count: openRouterResults.filter(\.metrics.transportSuccess).count, denominator: openRouterResults.count))) |",
            "| Structured parse success | \(count(EvalCountSummary(count: openRouterResults.filter(\.metrics.structuredResponseParsed).count, denominator: openRouterResults.count))) |",
            "| Typed provider failures | \(failureCounts.values.reduce(0, +)) |",
            "| Retry total | \(retryTotal) |",
            "| Retry average | \(retryAverage) |",
            "| Schema-tool calls | \(schemaToolCalls == 0 ? "-" : String(schemaToolCalls)) |",
            "| Inspection-tool calls | \(inspectionToolCalls == 0 ? "-" : String(inspectionToolCalls)) |",
            "| Agent logical model turns | \(agentTurns == 0 ? "-" : String(agentTurns)) |",
            "| Agent HTTP attempts | \(agentHTTPAttempts == 0 ? "-" : String(agentHTTPAttempts)) |",
            "| Token usage | \(tokenUsage == 0 ? "-" : String(tokenUsage)) |",
            "| Estimated cloud cost | \(cost == 0 ? "-" : String(format: "$%.6f", cost)) |",
            "",
            "### OpenRouter Output Modes",
            "",
            "| Mode | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(modeCounts)
        lines += [
            "",
            "### OpenRouter Agent Selection",
            "",
            "| Selection | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(selectionCounts)
        lines += [
            "",
            "### OpenRouter Agent Terminal Outcomes",
            "",
            "| Outcome | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(terminalCounts)
        lines += [
            "",
            "### OpenRouter Failures",
            "",
            "| Category | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(failureCounts)
        lines += [
            "",
            "### OpenRouter Returned Models",
            "",
            "| Model | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(returnedModelCounts)
        lines += [
            "",
            "### OpenRouter Providers",
            "",
            "| Provider | Count |",
            "| --- | ---: |",
        ]
        lines += tableRows(providerCounts)
        return lines
    }

    private static func semanticStatusCountSection(title: String, summary: EvalRunSummary) -> [String] {
        guard let counts = summary.semanticStatusCounts else { return [] }
        var lines = [
            "",
            "## \(title)",
            "",
            "| Semantic Status | Count |",
            "| --- | ---: |",
        ]
        for status in TextToSQLSemanticStatus.allCases {
            lines.append("| \(status.rawValue) | \(counts[status.rawValue, default: 0]) |")
        }
        return lines
    }

    private static func staticSemanticCrossTabSection(
        title: String,
        summary: EvalRunSummary
    ) -> [String] {
        guard let crossTab = summary.staticSemanticCrossTab else { return [] }
        return [
            "",
            "## \(title)",
            "",
            "| Category | Count |",
            "| --- | ---: |",
            "| static pass / semantic pass | \(crossTab.staticPassSemanticPass) |",
            "| static pass / semantic fail | \(crossTab.staticPassSemanticFail) |",
            "| static fail / semantic pass | \(crossTab.staticFailSemanticPass) |",
            "| static fail / semantic fail | \(crossTab.staticFailSemanticFail) |",
        ]
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

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
    }

    private static func tableRows(_ counts: [String: Int]) -> [String] {
        if counts.isEmpty { return ["| - | 0 |"] }
        return counts.keys.sorted().map { key in
            "| \(tableCell(key)) | \(counts[key, default: 0]) |"
        }
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
        if let category = result.diagnostics.openRouterFailureCategory {
            parts.append("openrouter: \(category)")
        }
        if let kind = result.diagnostics.postgresVerificationDiagnosticKind
            ?? result.metrics.postgresVerificationDiagnosticKind
        {
            parts.append("postgres: \(kind.rawValue)")
        }
        if let sqlState = result.diagnostics.postgresVerificationSQLState
            ?? result.metrics.postgresVerificationSQLState
        {
            parts.append("sqlstate: \(sqlState)")
        }
        if let mode = result.metrics.openRouterStructuredOutputMode {
            parts.append("mode: \(mode)")
        }
        if let retries = result.metrics.openRouterRetryCount {
            parts.append("retries: \(retries)")
        }
        if let returnedModel = result.metrics.openRouterReturnedModelID
            ?? result.diagnostics.openRouterReturnedModelID
        {
            parts.append("returned: \(returnedModel)")
        }
        if let provider = result.metrics.openRouterProviderName
            ?? result.diagnostics.openRouterProviderName
        {
            parts.append("provider: \(provider)")
        }
        return parts.isEmpty ? "-" : tableCell(parts.joined(separator: "; "))
    }

    private static func semanticSummary(_ result: TextToSQLEvalResult) -> String {
        guard result.metrics.semanticStatus != nil else { return "-" }
        var parts: [String] = []
        if let attempted = result.metrics.semanticExecutionAttempted {
            parts.append("attempted: \(attempted)")
        }
        if let environmentAvailable = result.metrics.semanticEnvironmentAvailable {
            parts.append("env: \(environmentAvailable)")
        }
        if let equivalent = result.metrics.resultEquivalent {
            parts.append("equivalent: \(equivalent)")
        }
        if let endToEnd = result.metrics.endToEndPassed {
            parts.append("end-to-end: \(endToEnd)")
        }
        if let mode = result.metrics.comparisonMode {
            parts.append("mode: \(mode.rawValue)")
        }
        if let golden = result.metrics.goldenRowCount {
            parts.append("golden rows: \(golden)")
        }
        if let candidate = result.metrics.candidateRowCount {
            parts.append("candidate rows: \(candidate)")
        }
        if let latency = result.metrics.executionLatencyMs {
            parts.append("semantic ms: \(latency)")
        }
        if let mismatch = result.metrics.semanticMismatchCategory {
            parts.append("mismatch: \(mismatch)")
        }
        if let digest = result.metrics.goldenResultDigest {
            parts.append("golden digest: \(String(digest.prefix(12)))")
        }
        if let digest = result.metrics.candidateResultDigest {
            parts.append("candidate digest: \(String(digest.prefix(12)))")
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
    static let evalTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
