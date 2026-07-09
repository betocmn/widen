import Foundation

import WidenKit

struct TextToSQLReleaseGateOutput {
    var summary: URL
    var evaluation: TextToSQLReleaseGateEvaluation
}

enum TextToSQLReleaseGateReporter {
    static func write(
        run: EvalRun,
        evalOutput: EvalOutputPaths,
        version: String
    ) throws -> TextToSQLReleaseGateOutput {
        let evaluationInput = input(for: run)
        let evaluation = TextToSQLReleaseGate.evaluate(evaluationInput)
        let directory = URL(fileURLWithPath: "docs/evals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary = directory.appendingPathComponent("\(version).md")
        try markdown(
            run: run,
            evalOutput: evalOutput,
            version: version,
            input: evaluationInput,
            evaluation: evaluation
        )
        .write(to: summary, atomically: true, encoding: .utf8)
        return TextToSQLReleaseGateOutput(summary: summary, evaluation: evaluation)
    }

    static func input(for run: EvalRun) -> TextToSQLReleaseGateInput {
        let summary = run.backendSummaries[.cloud] ?? run.summary
        let gateResults = releaseGateResults(for: run)
        let completedResults = gateResults.filter { $0.status.isCompletedEvaluation }.count
        let skippedBudgetResults = gateResults.filter { $0.status == .skippedBudgetLimit }.count
        let providerBudgetUnavailableResults = gateResults.filter {
            $0.status.isProviderBudgetUnavailable
        }.count
        let expectedResults = TextToSQLReleaseGate.expectedResultCount
        let accountedResults = completedResults
            + skippedBudgetResults
            + providerBudgetUnavailableResults
        let missingResults = max(0, expectedResults - accountedResults)
        return TextToSQLReleaseGateInput(
            totalResults: gateResults.count,
            expectedResults: expectedResults,
            completedResults: completedResults,
            missingResults: missingResults,
            skippedBudgetResults: skippedBudgetResults,
            providerBudgetUnavailableResults: providerBudgetUnavailableResults,
            endToEndPass: gateCount(summary.endToEndPass),
            safetyValid: gateCount(summary.safetyValid),
            schemaValid: gateCount(summary.schemaValid),
            clarificationDecisionPass: gateCount(summary.clarificationDecisionPass),
            transportSuccess: gateCount(summary.transportSuccess),
            repeatedNoProgressRepairCount: summary.repeatedNoProgressRepairCount
        )
    }

    private static func releaseGateResults(for run: EvalRun) -> [TextToSQLEvalResult] {
        let cloudResults = run.results.filter { $0.backend == .cloud }
        if run.backendSummaries[.cloud] != nil || !cloudResults.isEmpty {
            return cloudResults
        }
        return run.results
    }

    private static func gateCount(_ count: EvalCountSummary) -> TextToSQLReleaseGateCount {
        TextToSQLReleaseGateCount(count: count.count, denominator: count.denominator)
    }

    private static func gateCount(_ count: EvalCountSummary?) -> TextToSQLReleaseGateCount? {
        count.map(gateCount)
    }

    private static func markdown(
        run: EvalRun,
        evalOutput: EvalOutputPaths,
        version: String,
        input: TextToSQLReleaseGateInput,
        evaluation: TextToSQLReleaseGateEvaluation
    ) -> String {
        var lines: [String] = [
            "# Text-to-SQL Release Gate \(version)",
            "",
            "**Gate:** \(evaluation.passed ? "Passed" : "Failed")",
            "",
            "## Run",
            "",
            "| Field | Value |",
            "| --- | --- |",
            "| Suite | \(tableCell("\(run.manifest.suiteName) v\(run.manifest.suiteVersion)")) |",
            "| Evaluation mode | \(tableCell(run.manifest.evaluationMode)) |",
            "| Run ID | \(tableCell(run.manifest.runID ?? "-")) |",
            "| Parent run ID | \(tableCell(run.manifest.parentRunID ?? "-")) |",
            "| Resumed from | \(tableCell(manifestArtifactPath(run.manifest.resumedFrom))) |",
            "| Commit | \(tableCell(run.manifest.commitSHA)) |",
            "| Started | \(tableCell(run.manifest.startedAt)) |",
            "| Finished | \(tableCell(run.manifest.finishedAt)) |",
            "| Backend | \(tableCell(run.manifest.backendMode)) |",
            "| Cloud agent | \(tableCell(run.manifest.cloudAgentMode ?? "-")) |",
            "| Schema agent clarification correction | \(tableCell(run.manifest.schemaAgentClarificationCorrectionMode ?? "-")) |",
            "| Schema agent intent coverage | \(tableCell(run.manifest.schemaAgentIntentCoverageMode ?? "-")) |",
            "| Model | \(tableCell(run.manifest.model ?? "-")) |",
            "| Repeats | \(run.manifest.repeatCount) |",
            "| Results | \(input.totalResults) |",
            "| Complete | \(input.completedResults == input.expectedResults ? "Yes" : "No") |",
            "| Expected results | \(input.expectedResults) |",
            "| Completed results | \(input.completedResults) |",
            "| Missing results | \(input.missingResults) |",
            "| Skipped by budget | \(input.skippedBudgetResults) |",
            "| Provider budget unavailable | \(input.providerBudgetUnavailableResults) |",
            "| Budget stop | \(tableCell(run.manifest.budgetStopReason ?? "-")) |",
            "",
            "## Gate Criteria",
            "",
            "| Criterion | Observed | Required | Status |",
            "| --- | --- | --- | --- |",
        ]

        for criterion in evaluation.criteria {
            lines.append(
                "| \(tableCell(criterion.label)) | \(tableCell(criterion.observed)) | \(tableCell(criterion.required)) | \(criterion.passed ? "Pass" : "Fail") |"
            )
        }

        if !evaluation.incompleteFailureMessages.isEmpty {
            lines += [
                "",
                "## Incomplete Run",
                "",
            ]
            lines += evaluation.incompleteFailureMessages.map { "- \($0)" }
        }

        if !evaluation.thresholdFailureMessages.isEmpty {
            lines += [
                "",
                "## Threshold Failures",
                "",
            ]
            lines += evaluation.thresholdFailureMessages.map { "- \($0)" }
        }

        lines += historicalRegressionSection(results: run.results)

        lines += [
            "",
            "## Artifacts",
            "",
            "| Artifact | Path |",
            "| --- | --- |",
            "| Eval directory | \(tableCell(artifactPath(evalOutput.directory))) |",
            "| Run JSON | \(tableCell(artifactPath(evalOutput.run))) |",
            "| Cases JSONL | \(tableCell(artifactPath(evalOutput.cases))) |",
            "| Eval summary | \(tableCell(artifactPath(evalOutput.summary))) |",
            "",
            "This release gate is required for PR 12. A failed gate means text-to-SQL should not be described as production-ready.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func historicalRegressionSection(results: [TextToSQLEvalResult]) -> [String] {
        let historicalCaseIDs = [
            "preseason.top-wins-ambiguous",
            "preseason.top-wins-defined",
        ]
        let matches = results
            .filter { historicalCaseIDs.contains($0.caseID) }
            .sorted(by: resultSort)
        guard !matches.isEmpty else { return [] }

        var lines = [
            "",
            "## Historical Regression Cases",
            "",
            "These Preseason top-wins cases cover the historical failure class around column ownership, mixed-case timestamps, interval comparisons, and repeated/no-progress repair loops.",
            "",
            "| Case | Repeat | Evaluation | Status | Semantic Status | Clarification/Semantic Result | Invalid Tool A/B Binding | Quoted Timestamp | Timestamp/Interval Type | Repeated/No-Progress Repair |",
            "| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for result in matches {
            let evaluated = result.status.isCompletedEvaluation
            lines.append(
                "| \(tableCell(result.caseID)) | \(result.repeatIndex) | \(evaluated ? "Evaluated" : "Not evaluated") | \(tableCell(result.status.rawValue)) | \(tableCell(result.metrics.semanticStatus?.rawValue ?? "-")) | \(evaluated ? historicalResultDescription(result) : "Not evaluated") | \(evaluated ? (invalidToolABBinding(result) ? "Fail" : "Pass") : "-") | \(evaluated ? quotedTimestampCheck(result) : "-") | \(evaluated ? timestampIntervalCheck(result) : "-") | \(evaluated ? (repeatedNoProgressRepair(result) ? "Fail" : "Pass") : "-") |"
            )
        }
        return lines
    }

    private static func artifactPath(_ url: URL) -> String {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let artifact = url.standardizedFileURL
        let directoryPath = currentDirectory.path
        let artifactPath = artifact.path
        guard artifactPath == directoryPath || artifactPath.hasPrefix(directoryPath + "/") else {
            return artifact.lastPathComponent
        }
        let relative = artifactPath.dropFirst(directoryPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : String(relative)
    }

    private static func manifestArtifactPath(_ path: String?) -> String {
        guard let path else { return "-" }
        return artifactPath(URL(fileURLWithPath: path))
    }

    private static func resultSort(_ lhs: TextToSQLEvalResult, _ rhs: TextToSQLEvalResult) -> Bool {
        if lhs.caseID != rhs.caseID {
            return lhs.caseID < rhs.caseID
        }
        if lhs.backend != rhs.backend {
            return lhs.backend.rawValue < rhs.backend.rawValue
        }
        return lhs.repeatIndex < rhs.repeatIndex
    }

    private static func historicalResultDescription(_ result: TextToSQLEvalResult) -> String {
        if result.caseID == "preseason.top-wins-ambiguous" {
            return result.status == .passed ? "Clarified correctly" : "Clarification failed"
        }
        if result.caseID == "preseason.top-wins-defined" {
            return result.metrics.semanticStatus == .passed
                ? "Semantic DB eval passed"
                : "Semantic DB eval failed"
        }
        return "-"
    }

    private static func invalidToolABBinding(_ result: TextToSQLEvalResult) -> Bool {
        let forbidden = Set(result.metrics.forbiddenBindingViolations.map { $0.lowercased() })
        return forbidden.contains("public.preseason_match_evaluation.tool_a_id")
            || forbidden.contains("public.preseason_match_evaluation.tool_b_id")
            || result.referencedColumnBindings.contains {
                let normalized = $0.lowercased()
                return normalized == "public.preseason_match_evaluation.tool_a_id"
                    || normalized == "public.preseason_match_evaluation.tool_b_id"
            }
            || result.diagnostics.schemaErrors.contains {
                let normalized = $0.lowercased()
                return normalized.contains("public.preseason_match_evaluation")
                    && (normalized.contains("tool_a_id") || normalized.contains("tool_b_id"))
            }
    }

    private static func quotedTimestampCheck(_ result: TextToSQLEvalResult) -> String {
        guard let sql = result.generatedSQL,
            sql.range(of: "createdAt", options: .caseInsensitive) != nil
        else { return "-" }
        let unquotedPattern = #"(?<!")\bcreatedAt\b(?!")"#
        return sql.range(of: unquotedPattern, options: [.regularExpression, .caseInsensitive]) == nil
            ? "Pass"
            : "Fail"
    }

    private static func timestampIntervalCheck(_ result: TextToSQLEvalResult) -> String {
        guard let sql = result.generatedSQL,
            sql.range(of: "interval", options: .caseInsensitive) != nil
        else { return "-" }
        let invalidPattern =
            #"(?is)("createdAt"|createdAt|created_at|updated_at)\s*(=|<|>|<=|>=)\s*interval\b"#
        return sql.range(of: invalidPattern, options: .regularExpression) == nil ? "Pass" : "Fail"
    }

    private static func repeatedNoProgressRepair(_ result: TextToSQLEvalResult) -> Bool {
        result.trace?.stages.contains {
            $0.failureCategory == .repeatedNoProgressRepair
        } == true
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

struct TextToSQLReleaseTriageOutput {
    var triage: URL
    var copiedSummary: URL?
}

enum TextToSQLReleaseTriageCategory: String, CaseIterable {
    case backendUnavailable
    case transportFailure
    case modelToolProtocolFailure = "model/tool protocol failure"
    case missingTerminalToolResult = "missing terminal tool result"
    case malformedTerminalResult = "malformed terminal result"
    case toolBudgetExhausted = "tool budget exhausted"
    case schemaToolError = "schema-tool error"
    case noSchemaMatch = "no schema match"
    case noJoinPath = "no join path"
    case terminalSQLReferencesUninspectedObject = "terminal SQL references uninspected object"
    case staticSafetyFailure = "static safety failure"
    case staticSchemaFailure = "static schema failure"
    case postgreSQLVerificationFailure = "PostgreSQL verification failure"
    case wrongDecisionExpectedSQLGotClarification = "wrong decision: expected SQL, got clarification"
    case wrongDecisionExpectedClarificationGotSQL = "wrong decision: expected clarification, got SQL"
    case clarificationQualityFailure = "clarification quality failure"
    case semanticResultMismatch = "semantic result mismatch"
    case candidateExecutionFailure = "candidate execution failure"
    case timeoutCancellation = "timeout/cancellation"
    case other
}

enum TextToSQLReleaseTriageReporter {
    static func write(
        run: EvalRun,
        evalOutput: EvalOutputPaths,
        copyVersion: String?
    ) throws -> TextToSQLReleaseTriageOutput {
        let casesByID = loadCasesByID(suitePath: run.manifest.suitePath)
        let markdown = triageMarkdown(run: run, casesByID: casesByID)
        let triage = evalOutput.directory.appendingPathComponent("triage.md")
        try markdown.write(to: triage, atomically: true, encoding: .utf8)
        let copied = try copySummaryIfNeeded(markdown: markdown, version: copyVersion)
        return TextToSQLReleaseTriageOutput(triage: triage, copiedSummary: copied)
    }

    static func writeExisting(
        runJSONPath: String,
        copyVersion: String?
    ) throws -> TextToSQLReleaseTriageOutput {
        let runURL = URL(fileURLWithPath: runJSONPath).standardizedFileURL
        let directory = runURL.deletingLastPathComponent()
        let runFile = try JSONDecoder().decode(
            ReleaseTriageRunFile.self,
            from: Data(contentsOf: runURL)
        )
        let results = try readCasesJSONL(
            directory.appendingPathComponent("cases.jsonl")
        )
        let backendSummaries = Dictionary(
            uniqueKeysWithValues: runFile.backendSummaries.compactMap { key, value in
                TextToSQLEvalBackend(rawValue: key).map { ($0, value) }
            }
        )
        let run = EvalRun(
            manifest: runFile.manifest,
            results: results,
            summary: runFile.summary,
            backendSummaries: backendSummaries
        )
        let casesByID = loadCasesByID(suitePath: run.manifest.suitePath)
        let markdown = triageMarkdown(run: run, casesByID: casesByID)
        let triage = directory.appendingPathComponent("triage.md")
        try markdown.write(to: triage, atomically: true, encoding: .utf8)
        let copied = try copySummaryIfNeeded(markdown: markdown, version: copyVersion)
        return TextToSQLReleaseTriageOutput(triage: triage, copiedSummary: copied)
    }

    private static func triageMarkdown(
        run: EvalRun,
        casesByID: [String: TextToSQLEvalCase]
    ) -> String {
        let expectedKeys = expectedKeys(for: run, casesByID: casesByID)
        let completeness = TextToSQLEvalRunCompleteness.evaluate(
            expectedKeys: expectedKeys,
            results: run.results
        )
        let failed = run.results
            .filter(Self.isTriageFailure)
            .map { TriageRow(result: $0, evalCase: casesByID[$0.caseID]) }
        let grouped = Dictionary(grouping: failed, by: \.category)

        var lines: [String] = [
            completeness.isComplete
                ? "# Text-to-SQL Release Gate Triage"
                : "# Text-to-SQL Release Gate Triage (Partial)",
            "",
            "This report is redacted: it omits raw prompts, raw model output, result rows, API keys, and full schema dumps.",
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
            "| Schema agent clarification correction | \(tableCell(run.manifest.schemaAgentClarificationCorrectionMode ?? "-")) |",
            "| Schema agent intent coverage | \(tableCell(run.manifest.schemaAgentIntentCoverageMode ?? "-")) |",
            "| Model | \(tableCell(run.manifest.model ?? "-")) |",
            "| Results | \(run.results.count) |",
            "| Complete | \(completeness.isComplete ? "Yes" : "No") |",
            "| Expected results | \(completeness.expectedResultCount) |",
            "| Completed results | \(completeness.completedResultCount) |",
            "| Missing results | \(completeness.missingResultCount) |",
            "| Skipped by budget | \(completeness.skippedBudgetCount) |",
            "| Provider budget unavailable | \(completeness.providerBudgetUnavailableCount) |",
            "| Resumed from | \(tableCell(artifactPath(run.manifest.resumedFrom))) |",
            "| Budget stop | \(tableCell(run.manifest.budgetStopReason ?? "-")) |",
            "| Failed results | \(failed.count) |",
            "",
            "## Failure Categories",
            "",
            "| Category | Count |",
            "| --- | ---: |",
        ]

        for category in TextToSQLReleaseTriageCategory.allCases {
            lines.append("| \(tableCell(category.rawValue)) | \(grouped[category]?.count ?? 0) |")
        }

        for category in TextToSQLReleaseTriageCategory.allCases {
            let rows = (grouped[category] ?? []).sorted(by: TriageRow.sort)
            guard !rows.isEmpty else { continue }
            lines += [
                "",
                "## \(category.rawValue)",
                "",
                "| Case | Repeat | Expected | Actual | Status | Semantic | Verification | Terminal | Query Plan | Policy | Mismatch | Schema Tools | Described | Inspected Objects | SQL Tables | Repeated Repair |",
                "| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | --- | --- | --- |",
            ]
            for row in rows {
                lines.append(row.markdownRow)
            }
        }

        lines += notEvaluatedSection(completeness: completeness)
        lines += historicalPreseasonTriageSection(
            run: run,
            expectedKeys: expectedKeys,
            completeness: completeness
        )

        lines += [
            "",
            "## Notes",
            "",
            "- Categories are derived from stable result statuses, semantic statuses, validation statuses, trace failure categories, tool traces, and structured agent diagnostics.",
            "- SQL text, raw prompts, model text, database row values, and full schemas are intentionally omitted.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func isTriageFailure(_ result: TextToSQLEvalResult) -> Bool {
        guard result.status.isCompletedEvaluation else { return false }
        if result.status != .passed { return true }
        if result.metrics.endToEndPassed == false { return true }
        switch result.metrics.semanticStatus {
        case .resultMismatch, .candidateExecutionFailure, .goldenFixtureFailure,
            .resultLimitExceeded, .semanticEnvironmentUnavailable, .fixtureInvalid:
            return true
        case .passed, .notApplicable, nil:
            return false
        }
    }

    private static func notEvaluatedSection(
        completeness: TextToSQLEvalRunCompleteness
    ) -> [String] {
        guard !completeness.notEvaluated.isEmpty else { return [] }
        var lines = [
            "",
            "## Not Evaluated",
            "",
            "| Case | Backend | Repeat | Reason |",
            "| --- | --- | ---: | --- |",
        ]
        for slot in completeness.notEvaluated.sorted(by: notEvaluatedSort) {
            lines.append(
                "| \(tableCell(slot.key.caseID)) | \(tableCell(slot.key.backend.rawValue)) | \(slot.key.repeatIndex) | \(tableCell(slot.reason.rawValue)) |"
            )
        }
        return lines
    }

    private static func historicalPreseasonTriageSection(
        run: EvalRun,
        expectedKeys: [TextToSQLEvalResultKey],
        completeness: TextToSQLEvalRunCompleteness
    ) -> [String] {
        let historicalIDs = [
            "preseason.top-wins-ambiguous",
            "preseason.top-wins-defined",
        ]
        let resultByKey = Dictionary(
            run.results.map { (TextToSQLEvalResultKey(result: $0), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let historicalBackends = Set(
            expectedKeys.map(\.backend)
                + run.results
                .filter { historicalIDs.contains($0.caseID) }
                .map(\.backend)
        )
        let backends = historicalBackends.isEmpty
            ? [TextToSQLEvalBackend.cloud]
            : historicalBackends.sorted { $0.rawValue < $1.rawValue }
        let fallbackKeys = backends.flatMap { backend in
            historicalIDs.flatMap { caseID in
                (1...max(1, run.manifest.repeatCount)).map { repeatIndex in
                    TextToSQLEvalResultKey(
                        caseID: caseID,
                        backend: backend,
                        repeatIndex: repeatIndex
                    )
                }
            }
        }

        var lines = [
            "",
            "## Historical Preseason Cases",
            "",
            "| Case | Backend | Repeat | Evaluation | Status | Semantic Status | Clarification/Semantic Result | Repeated/No-Progress Repair | Invalid Tool A/B Binding | Quoted Timestamp | Notes |",
            "| --- | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for key in fallbackKeys.sorted(by: keySort) {
            guard historicalIDs.contains(key.caseID) else { continue }
            if let result = resultByKey[key], result.status.isCompletedEvaluation {
                lines.append(
                    "| \(tableCell(key.caseID)) | \(tableCell(key.backend.rawValue)) | \(key.repeatIndex) | Evaluated | \(tableCell(result.status.rawValue)) | \(tableCell(result.metrics.semanticStatus?.rawValue ?? "-")) | \(historicalPreseasonResultDescription(result)) | \(repeatedNoProgressRepair(result) ? "Yes" : "No") | \(invalidToolABBinding(result) ? "Fail" : "Pass") | \(quotedTimestampCheck(result)) | \(tableCell(historicalNote(result))) |"
                )
            } else if let result = resultByKey[key] {
                lines.append(
                    "| \(tableCell(key.caseID)) | \(tableCell(key.backend.rawValue)) | \(key.repeatIndex) | Not evaluated | \(tableCell(result.status.rawValue)) | \(tableCell(result.metrics.semanticStatus?.rawValue ?? "-")) | Not evaluated | - | - | - | \(tableCell(result.diagnostics.errorMessage ?? result.status.notEvaluatedReason?.rawValue ?? "-")) |"
                )
            } else {
                lines.append(
                    "| \(tableCell(key.caseID)) | \(tableCell(key.backend.rawValue)) | \(key.repeatIndex) | Not evaluated | - | - | Not evaluated | - | - | - | missing |"
                )
            }
        }
        return lines
    }

    private static func historicalPreseasonResultDescription(_ result: TextToSQLEvalResult)
        -> String
    {
        if result.caseID == "preseason.top-wins-ambiguous" {
            return result.status == .passed ? "Clarified correctly" : "Clarification failed"
        }
        if result.caseID == "preseason.top-wins-defined" {
            return result.metrics.semanticStatus == .passed
                ? "Semantic DB eval passed"
                : "Semantic DB eval failed"
        }
        return "-"
    }

    private static func historicalNote(_ result: TextToSQLEvalResult) -> String {
        var notes: [String] = []
        if repeatedNoProgressRepair(result) {
            notes.append("repeated/no-progress repair")
        }
        if result.metrics.forbiddenBindingViolations.contains(where: {
            $0.localizedCaseInsensitiveContains("tool_a_id")
                || $0.localizedCaseInsensitiveContains("tool_b_id")
        }) {
            notes.append("invalid tool A/B binding")
        }
        if result.metrics.semanticStatus == .resultMismatch {
            notes.append("semantic mismatch")
        }
        return notes.isEmpty ? "-" : notes.joined(separator: "; ")
    }

    private static func invalidToolABBinding(_ result: TextToSQLEvalResult) -> Bool {
        let forbidden = Set(result.metrics.forbiddenBindingViolations.map { $0.lowercased() })
        return forbidden.contains("public.preseason_match_evaluation.tool_a_id")
            || forbidden.contains("public.preseason_match_evaluation.tool_b_id")
            || result.referencedColumnBindings.contains {
                let normalized = $0.lowercased()
                return normalized == "public.preseason_match_evaluation.tool_a_id"
                    || normalized == "public.preseason_match_evaluation.tool_b_id"
            }
            || result.diagnostics.schemaErrors.contains {
                let normalized = $0.lowercased()
                return normalized.contains("public.preseason_match_evaluation")
                    && (normalized.contains("tool_a_id") || normalized.contains("tool_b_id"))
            }
    }

    private static func quotedTimestampCheck(_ result: TextToSQLEvalResult) -> String {
        guard let sql = result.generatedSQL,
            sql.range(of: "createdAt", options: .caseInsensitive) != nil
        else { return "-" }
        let unquotedPattern = #"(?<!")\bcreatedAt\b(?!")"#
        return sql.range(of: unquotedPattern, options: [.regularExpression, .caseInsensitive]) == nil
            ? "Pass"
            : "Fail"
    }

    private static func artifactPath(_ path: String?) -> String {
        guard let path else { return "-" }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        let artifact = URL(fileURLWithPath: path).standardizedFileURL
        let directoryPath = currentDirectory.path
        let artifactPath = artifact.path
        guard artifactPath == directoryPath || artifactPath.hasPrefix(directoryPath + "/") else {
            return artifact.lastPathComponent
        }
        let relative = artifactPath.dropFirst(directoryPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : String(relative)
    }

    private static func expectedKeys(
        for run: EvalRun,
        casesByID: [String: TextToSQLEvalCase]
    ) -> [TextToSQLEvalResultKey] {
        let caseIDs: [String]
        if let selected = run.manifest.selectedCaseIDs, !selected.isEmpty {
            caseIDs = selected
        } else if run.manifest.caseCount == casesByID.count {
            caseIDs = casesByID.keys.sorted()
        } else {
            caseIDs = orderedUniqueCaseIDs(run.results)
        }
        let backends = backends(for: run.manifest.backendMode)
        return backends.flatMap { backend in
            caseIDs.flatMap { caseID in
                (1...max(1, run.manifest.repeatCount)).map { repeatIndex in
                    TextToSQLEvalResultKey(
                        caseID: caseID,
                        backend: backend,
                        repeatIndex: repeatIndex
                    )
                }
            }
        }
    }

    private static func backends(for backendMode: String) -> [TextToSQLEvalBackend] {
        switch backendMode {
        case "local":
            return [.local]
        case "cloud":
            return [.cloud]
        case "both":
            return [.local, .cloud]
        default:
            return [.cloud]
        }
    }

    private static func orderedUniqueCaseIDs(_ results: [TextToSQLEvalResult]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for result in results where !seen.contains(result.caseID) {
            seen.insert(result.caseID)
            ordered.append(result.caseID)
        }
        return ordered
    }

    private static func notEvaluatedSort(
        _ lhs: TextToSQLEvalNotEvaluatedSlot,
        _ rhs: TextToSQLEvalNotEvaluatedSlot
    ) -> Bool {
        keySort(lhs.key, rhs.key)
    }

    private static func keySort(
        _ lhs: TextToSQLEvalResultKey,
        _ rhs: TextToSQLEvalResultKey
    ) -> Bool {
        if lhs.caseID != rhs.caseID { return lhs.caseID < rhs.caseID }
        if lhs.backend != rhs.backend { return lhs.backend.rawValue < rhs.backend.rawValue }
        return lhs.repeatIndex < rhs.repeatIndex
    }

    private struct TriageRow {
        var result: TextToSQLEvalResult
        var evalCase: TextToSQLEvalCase?

        var category: TextToSQLReleaseTriageCategory {
            Self.category(for: result, expected: evalCase?.expected.decision)
        }

        var markdownRow: String {
            let expected = evalCase?.expected.decision.rawValue ?? "-"
            let actual = Self.actualDecision(result)
            let diagnostics = result.metrics.openRouterAgentDiagnostics
            let evidence = diagnostics?.schemaEvidence
            let terminal = diagnostics?.terminalAction
                ?? result.metrics.openRouterAgentTerminalOutcome
                ?? "-"
            let queryPlan = QueryPlanReportSummary.redactedSummary(
                for: diagnostics?.terminalQueryPlan ?? ""
            ) ?? "-"
            let policy = Self.policySummary(diagnostics)
            let mismatch = Self.semanticMismatchSummary(result, evalCase: evalCase)
            let schemaToolCalls = result.metrics.openRouterSchemaToolCallCount
                ?? result.trace?.schemaToolCalls.count
                ?? 0
            let described = evidence?.describedTableIDs.count ?? 0
            let inspectedObjects = evidence?.describedTableIDs.prefix(8).joined(separator: ", ") ?? "-"
            let sqlTables = result.referencedTables.prefix(8).joined(separator: ", ")
            return [
                tableCell(result.caseID),
                String(result.repeatIndex),
                tableCell(expected),
                tableCell(actual),
                tableCell(result.status.rawValue),
                tableCell(result.metrics.semanticStatus?.rawValue ?? "-"),
                tableCell(result.metrics.postgresVerificationStatus?.rawValue ?? "-"),
                tableCell(terminal),
                tableCell(queryPlan),
                tableCell(policy),
                tableCell(mismatch),
                String(schemaToolCalls),
                String(described),
                tableCell(inspectedObjects.isEmpty ? "-" : inspectedObjects),
                tableCell(sqlTables.isEmpty ? "-" : sqlTables),
                repeatedNoProgressRepair(result) ? "Yes" : "No",
            ].joined(separator: " | ").withMarkdownTablePipes
        }

        private static func policySummary(
            _ diagnostics: OpenRouterSchemaToolAgentDiagnostics?
        ) -> String {
            guard let diagnostics,
                !diagnostics.clarificationPolicyDecision.isEmpty
            else { return "-" }
            var parts = [diagnostics.clarificationPolicyDecision]
            if diagnostics.evidenceSufficientForSQL {
                parts.append("evidence sufficient")
            }
            if diagnostics.overClarificationCorrectionAttempted {
                parts.append(
                    diagnostics.overClarificationCorrectionSucceeded
                        ? "correction succeeded"
                        : "correction attempted"
                )
            }
            if !diagnostics.unresolvedDecisionKinds.isEmpty {
                parts.append("unresolved: " + diagnostics.unresolvedDecisionKinds.joined(separator: ","))
            }
            if !diagnostics.sqlIntentCoverageDecision.isEmpty {
                parts.append("intent: " + diagnostics.sqlIntentCoverageDecision)
            }
            if diagnostics.intentCoverageCorrectionAttempted {
                parts.append(
                    diagnostics.intentCoverageCorrectionSucceeded
                        ? "intent correction succeeded"
                        : "intent correction attempted"
                )
            }
            return parts.joined(separator: "; ")
        }

        private static func semanticMismatchSummary(
            _ result: TextToSQLEvalResult,
            evalCase: TextToSQLEvalCase?
        ) -> String {
            guard result.metrics.semanticStatus == .resultMismatch else { return "-" }
            if let category = result.metrics.openRouterAgentDiagnostics?.sqlIntentCoverageMismatchCategory,
                !category.isEmpty,
                category != "unknown mismatch"
            {
                return category
            }
            let diagnostics = result.metrics.openRouterAgentDiagnostics
            return SchemaToolAgentSQLIntentCoveragePolicy.semanticMismatchCategory(
                question: evalCase?.question ?? "",
                databaseContext: evalCase?.databaseContext ?? "",
                evidence: diagnostics?.schemaEvidence ?? OpenRouterSchemaToolEvidenceSummary(),
                sql: result.generatedSQL ?? "",
                comparatorMismatchCategory: result.metrics.semanticMismatchCategory
            )
        }

        static func sort(_ lhs: TriageRow, _ rhs: TriageRow) -> Bool {
            if lhs.result.caseID != rhs.result.caseID {
                return lhs.result.caseID < rhs.result.caseID
            }
            return lhs.result.repeatIndex < rhs.result.repeatIndex
        }

        private static func category(
            for result: TextToSQLEvalResult,
            expected: TextToSQLEvalDecision?
        ) -> TextToSQLReleaseTriageCategory {
            if !result.metrics.backendAvailable || result.status == .backendUnavailable {
                return .backendUnavailable
            }
            if result.status == .evalTimeout
                || result.trace?.stages.contains(where: { $0.failureCategory == .cancellation }) == true
            {
                return .timeoutCancellation
            }
            if result.status == .transportFailure || !result.metrics.transportSuccess {
                return .transportFailure
            }
            if result.metrics.openRouterAgentDiagnostics?.appSideRejectionReason == .budgetExhausted
                || hasToolBudgetError(result)
            {
                return .toolBudgetExhausted
            }
            if result.metrics.openRouterAgentDiagnostics?.appSideRejectionReason == .uninspectedObject {
                return .terminalSQLReferencesUninspectedObject
            }
            if result.metrics.openRouterAgentDiagnostics?.appSideRejectionReason == .malformedTerminal {
                if result.metrics.openRouterAgentDiagnostics?.terminalToolSeen == false {
                    return .missingTerminalToolResult
                }
                return .malformedTerminalResult
            }
            if result.status == .parseFailure,
                result.metrics.openRouterAgentDiagnostics?.terminalToolSeen == false
            {
                return .missingTerminalToolResult
            }
            if result.trace?.schemaToolCalls.contains(where: { $0.outcome == .error }) == true {
                return .schemaToolError
            }
            if result.trace?.schemaToolCalls.contains(where: {
                $0.toolName == SchemaToolName.searchSchema.rawValue
                    && $0.outcome == .success
                    && $0.returnedObjectCount == 0
            }) == true {
                return .noSchemaMatch
            }
            if result.trace?.schemaToolCalls.contains(where: {
                $0.toolName == SchemaToolName.findJoinPaths.rawValue
                    && $0.outcome == .success
                    && $0.returnedObjectCount == 0
            }) == true {
                return .noJoinPath
            }
            if result.metrics.safetyValid == false {
                return .staticSafetyFailure
            }
            if result.metrics.schemaValid == false || result.status == .wrongSchemaObjects {
                return .staticSchemaFailure
            }
            if result.metrics.postgresVerificationStatus == .failed {
                return .postgreSQLVerificationFailure
            }
            if expected == .sql, actualDecision(result) == TextToSQLEvalDecision.clarify.rawValue {
                return .wrongDecisionExpectedSQLGotClarification
            }
            if expected == .clarify, actualDecision(result) == TextToSQLEvalDecision.sql.rawValue {
                return .wrongDecisionExpectedClarificationGotSQL
            }
            if expected == .clarify, result.metrics.clarificationQuality == false {
                return .clarificationQualityFailure
            }
            if result.metrics.semanticStatus == .candidateExecutionFailure {
                return .candidateExecutionFailure
            }
            if result.metrics.semanticStatus == .resultMismatch {
                return .semanticResultMismatch
            }
            if result.status == .parseFailure || result.status == .generationFailure {
                return .modelToolProtocolFailure
            }
            return .other
        }

        private static func actualDecision(_ result: TextToSQLEvalResult) -> String {
            if result.generatedSQL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return TextToSQLEvalDecision.sql.rawValue
            }
            if result.clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return TextToSQLEvalDecision.clarify.rawValue
            }
            if let action = result.metrics.openRouterAgentDiagnostics?.terminalAction {
                return action
            }
            return "-"
        }

        private static func hasToolBudgetError(_ result: TextToSQLEvalResult) -> Bool {
            result.trace?.schemaToolCalls.contains {
                $0.errorCode == .sessionBudgetExceeded || $0.errorCode == .resultBudgetExceeded
            } == true
                || result.trace?.inspectionToolCalls.contains {
                    $0.errorCode == .sessionBudgetExceeded || $0.errorCode == .resultBudgetExceeded
                } == true
        }
    }

    private static func readCasesJSONL(_ url: URL) throws -> [TextToSQLEvalResult] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .map { line in
                try decoder.decode(TextToSQLEvalResult.self, from: Data(line.utf8))
            }
    }

    private static func loadCasesByID(suitePath: String) -> [String: TextToSQLEvalCase] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: suitePath)),
            let suite = try? JSONDecoder().decode(TextToSQLEvalSuite.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: suite.cases.map { ($0.id, $0) })
    }

    private static func copySummaryIfNeeded(markdown: String, version: String?) throws -> URL? {
        guard let version else { return nil }
        let directory = URL(fileURLWithPath: "docs/evals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(version)-triage.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func repeatedNoProgressRepair(_ result: TextToSQLEvalResult) -> Bool {
        result.trace?.stages.contains {
            $0.failureCategory == .repeatedNoProgressRepair
        } == true
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

private struct ReleaseTriageRunFile: Codable {
    var manifest: EvalRunManifest
    var summary: EvalRunSummary
    var backendSummaries: [String: EvalRunSummary]
}

private extension String {
    var withMarkdownTablePipes: String {
        "| \(self) |"
    }
}
