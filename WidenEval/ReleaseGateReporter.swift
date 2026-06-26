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

        lines += [
            "",
            "## Artifacts",
            "",
            "| Artifact | Path |",
            "| --- | --- |",
            "| Eval directory | \(tableCell(evalOutput.directory.path)) |",
            "| Run JSON | \(tableCell(evalOutput.run.path)) |",
            "| Cases JSONL | \(tableCell(evalOutput.cases.path)) |",
            "| Eval summary | \(tableCell(evalOutput.summary.path)) |",
            "",
            "This release gate is required for PR 12. A failed gate means text-to-SQL should not be described as production-ready.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
