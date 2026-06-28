import Foundation
import Testing

@testable import WidenKit

@Suite("Text-to-SQL eval run planning")
struct TextToSQLEvalRunPlanningTests {
    @Test func compatibleResumeReusesExistingResults() throws {
        let previous = Self.compatibility()
        let current = Self.compatibility()
        try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)

        let expected = Self.expectedKeys(caseIDs: ["case.a", "case.b"], repeats: 1)
        let previousResults = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.b", repeatIndex: 1, status: .passed),
        ]

        let plan = TextToSQLEvalResumePlanner.plan(
            expectedKeys: expected,
            previousResults: previousResults,
            selection: TextToSQLEvalResumeSelection(resumeMissing: true)
        )

        #expect(plan.reusableResults.map(\.caseID) == ["case.a", "case.b"])
        #expect(plan.keysToRun.isEmpty)
    }

    @Test func compatibilityRejectsChangedSuiteHash() {
        var current = Self.compatibility()
        current.suiteFileHash = "changed"

        #expect(throws: TextToSQLEvalResumeCompatibilityError.self) {
            try TextToSQLEvalResumeCompatibility.validate(
                previous: Self.compatibility(),
                current: current
            )
        }
    }

    @Test func compatibilityRejectsChangedModelBackendAndCloudAgent() {
        var current = Self.compatibility()
        current.model = "other/model"
        current.backendMode = "both"
        current.cloudAgentMode = "legacy"

        do {
            try TextToSQLEvalResumeCompatibility.validate(
                previous: Self.compatibility(),
                current: current
            )
            Issue.record("Expected compatibility rejection.")
        } catch let error as TextToSQLEvalResumeCompatibilityError {
            let fields = Set(error.issues.map(\.field))
            #expect(fields.contains("model"))
            #expect(fields.contains("backend"))
            #expect(fields.contains("cloud agent"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func resumeMissingRunsOnlyMissingOrNotEvaluatedSlots() {
        let expected = Self.expectedKeys(caseIDs: ["case.a", "case.b", "case.c"], repeats: 1)
        let previousResults = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.c", repeatIndex: 1, status: .skippedBudgetLimit),
        ]

        let plan = TextToSQLEvalResumePlanner.plan(
            expectedKeys: expected,
            previousResults: previousResults,
            selection: TextToSQLEvalResumeSelection(resumeMissing: true)
        )

        #expect(plan.reusableResults.map(\.caseID) == ["case.a"])
        #expect(plan.keysToRun.map(\.caseID) == ["case.b", "case.c"])
    }

    @Test func resumeFailedRunsOnlyFailedCases() {
        let expected = Self.expectedKeys(caseIDs: ["case.a", "case.b", "case.c"], repeats: 1)
        let previousResults = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.b", repeatIndex: 1, status: .wrongDecision),
            Self.result(caseID: "case.c", repeatIndex: 1, status: .passed, endToEndPassed: false),
        ]

        let plan = TextToSQLEvalResumePlanner.plan(
            expectedKeys: expected,
            previousResults: previousResults,
            selection: TextToSQLEvalResumeSelection(resumeFailed: true)
        )

        #expect(plan.reusableResults.map(\.caseID) == ["case.a"])
        #expect(plan.keysToRun.map(\.caseID) == ["case.b", "case.c"])
    }

    @Test func resumePreservesRepeatIndexes() {
        let expected = Self.expectedKeys(caseIDs: ["case.a"], repeats: 3)
        let previousResults = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.a", repeatIndex: 3, status: .wrongDecision),
        ]

        let missingPlan = TextToSQLEvalResumePlanner.plan(
            expectedKeys: expected,
            previousResults: previousResults,
            selection: TextToSQLEvalResumeSelection(resumeMissing: true)
        )
        let failedPlan = TextToSQLEvalResumePlanner.plan(
            expectedKeys: expected,
            previousResults: previousResults,
            selection: TextToSQLEvalResumeSelection(resumeFailed: true)
        )

        #expect(missingPlan.keysToRun.map(\.repeatIndex) == [2])
        #expect(failedPlan.keysToRun.map(\.repeatIndex) == [3])
    }

    @Test func completenessAccountsForMissingAndBudgetSkippedResults() {
        let expected = Self.expectedKeys(caseIDs: ["case.a", "case.b", "case.c"], repeats: 1)
        let results = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.b", repeatIndex: 1, status: .skippedBudgetLimit),
            Self.result(caseID: "case.c", repeatIndex: 1, status: .providerLimit),
        ]

        let completeness = TextToSQLEvalRunCompleteness.evaluate(
            expectedKeys: expected + [TextToSQLEvalResultKey(caseID: "case.d", backend: .cloud, repeatIndex: 1)],
            results: results
        )

        #expect(completeness.isComplete == false)
        #expect(completeness.completedResultCount == 1)
        #expect(completeness.skippedBudgetCount == 1)
        #expect(completeness.providerBudgetUnavailableCount == 1)
        #expect(completeness.missingResultCount == 1)
        #expect(completeness.incompleteMessage == "Release gate incomplete: only 1/4 expected results were evaluated.")
    }

    @Test func releaseGateFailsIncompleteWithExplicitMessage() {
        let input = TextToSQLReleaseGateInput(
            totalResults: 8,
            completedResults: 8,
            missingResults: 52,
            skippedBudgetResults: 0,
            providerBudgetUnavailableResults: 0,
            endToEndPass: TextToSQLReleaseGateCount(count: 8, denominator: 8),
            safetyValid: TextToSQLReleaseGateCount(count: 8, denominator: 8),
            schemaValid: TextToSQLReleaseGateCount(count: 8, denominator: 8),
            clarificationDecisionPass: TextToSQLReleaseGateCount(count: 1, denominator: 1),
            transportSuccess: TextToSQLReleaseGateCount(count: 8, denominator: 8),
            repeatedNoProgressRepairCount: 0
        )

        let evaluation = TextToSQLReleaseGate.evaluate(input)

        #expect(evaluation.passed == false)
        #expect(evaluation.incompleteFailureMessages == [
            "Release gate incomplete: only 8/60 expected results were evaluated.",
        ])
        #expect(!evaluation.thresholdFailureMessages.contains {
            $0.contains("Release gate incomplete")
        })
    }

    @Test func makefileContainsFocusedReleaseCommands() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let makefile = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Makefile")
        let text = try String(contentsOf: makefile, encoding: .utf8)

        #expect(text.contains("eval-release-preseason"))
        #expect(text.contains("--case preseason.top-wins-ambiguous --case preseason.top-wins-defined"))
        #expect(text.contains("eval-release-resume"))
        #expect(text.contains("--resume-run \"$(RESUME)\" --resume-missing"))
    }

    private static func expectedKeys(
        caseIDs: [String],
        repeats: Int
    ) -> [TextToSQLEvalResultKey] {
        caseIDs.flatMap { caseID in
            (1...repeats).map { repeatIndex in
                TextToSQLEvalResultKey(
                    caseID: caseID,
                    backend: .cloud,
                    repeatIndex: repeatIndex
                )
            }
        }
    }

    private static func result(
        caseID: String,
        repeatIndex: Int,
        status: TextToSQLEvalCaseStatus,
        endToEndPassed: Bool? = nil
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: caseID,
            backend: .cloud,
            model: "test/model",
            repeatIndex: repeatIndex,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: status != .backendUnavailable,
                transportSuccess: status == .passed,
                structuredResponseParsed: status == .passed,
                decisionMatches: status == .passed,
                latencyMs: 1,
                endToEndPassed: endToEndPassed
            )
        )
    }

    private static func compatibility() -> TextToSQLEvalResumeCompatibilityManifest {
        TextToSQLEvalResumeCompatibilityManifest(
            suiteName: "text-to-sql",
            suiteVersion: "1",
            suiteFileHash: "suite-hash",
            schemaFixtureHashes: ["commerce": "schema-hash"],
            model: "openai/gpt-5.5",
            backendMode: "cloud",
            cloudAgentMode: "tools",
            semanticDatabaseEnabled: true,
            scorerSourceHash: "source-hash",
            semanticComparatorSourceHash: "semantic-source-hash",
            setupFixtureHashes: ["commerce": "setup-hash"],
            releaseGateVersion: "0.1.0"
        )
    }
}
