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
        return TextToSQLReleaseGateInput(
            totalResults: summary.totalResults,
            endToEndPass: gateCount(summary.endToEndPass),
            safetyValid: gateCount(summary.safetyValid),
            schemaValid: gateCount(summary.schemaValid),
            clarificationDecisionPass: gateCount(summary.clarificationDecisionPass),
            transportSuccess: gateCount(summary.transportSuccess),
            repeatedNoProgressRepairCount: summary.repeatedNoProgressRepairCount
        )
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
            "| Commit | \(tableCell(run.manifest.commitSHA)) |",
            "| Started | \(tableCell(run.manifest.startedAt)) |",
            "| Finished | \(tableCell(run.manifest.finishedAt)) |",
            "| Backend | \(tableCell(run.manifest.backendMode)) |",
            "| Cloud agent | \(tableCell(run.manifest.cloudAgentMode ?? "-")) |",
            "| Model | \(tableCell(run.manifest.model ?? "-")) |",
            "| Repeats | \(run.manifest.repeatCount) |",
            "| Results | \(input.totalResults) |",
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

        if !evaluation.failureMessages.isEmpty {
            lines += [
                "",
                "## Failures",
                "",
            ]
            lines += evaluation.failureMessages.map { "- \($0)" }
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
            "| Case | Repeat | Status | Semantic Status | Clarification Correct | Safety | Schema | Repeated/No-Progress Repair |",
            "| --- | ---: | --- | --- | --- | --- | --- | --- |",
        ]
        for result in matches {
            lines.append(
                "| \(tableCell(result.caseID)) | \(result.repeatIndex) | \(tableCell(result.status.rawValue)) | \(tableCell(result.metrics.semanticStatus?.rawValue ?? "-")) | \(clarificationCorrectness(result)) | \(booleanCell(result.metrics.safetyValid)) | \(booleanCell(result.metrics.schemaValid)) | \(repeatedNoProgressRepair(result) ? "Yes" : "No") |"
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

    private static func resultSort(_ lhs: TextToSQLEvalResult, _ rhs: TextToSQLEvalResult) -> Bool {
        if lhs.caseID != rhs.caseID {
            return lhs.caseID < rhs.caseID
        }
        if lhs.backend != rhs.backend {
            return lhs.backend.rawValue < rhs.backend.rawValue
        }
        return lhs.repeatIndex < rhs.repeatIndex
    }

    private static func clarificationCorrectness(_ result: TextToSQLEvalResult) -> String {
        if result.caseID == "preseason.top-wins-ambiguous" {
            return result.status == .passed ? "Pass" : "Fail"
        }
        return "-"
    }

    private static func booleanCell(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "Pass" : "Fail"
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
