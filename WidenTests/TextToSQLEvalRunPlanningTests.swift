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

    @Test func compatibilityAllowsSelectedFixtureSubset() throws {
        var previous = Self.compatibility()
        previous.schemaFixtureHashes = [
            "commerce": "commerce-hash",
            "preseason": "preseason-hash",
        ]
        previous.setupFixtureHashes = [
            "commerce": "commerce-setup-hash",
            "preseason": "preseason-setup-hash",
        ]
        var current = previous
        current.schemaFixtureHashes = ["preseason": "preseason-hash"]
        current.setupFixtureHashes = ["preseason": "preseason-setup-hash"]

        try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
    }

    @Test func compatibilityRejectsChangedSharedFixtureHash() {
        var previous = Self.compatibility()
        previous.schemaFixtureHashes = [
            "commerce": "commerce-hash",
            "preseason": "preseason-hash",
        ]
        var current = previous
        current.schemaFixtureHashes = ["preseason": "changed"]

        do {
            try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
            Issue.record("Expected compatibility rejection.")
        } catch let error as TextToSQLEvalResumeCompatibilityError {
            #expect(error.issues.map(\.field).contains("schema fixture hashes[preseason]"))
        } catch {
            Issue.record("Unexpected error: \(error)")
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

    @Test func compatibilityRejectsChangedOrMissingExpectedCanonicalModel() {
        let current = Self.compatibility()
        var changed = current
        changed.expectedCanonicalModelID = "openai/gpt-5.5-unevaluated"
        var legacy = current
        legacy.expectedCanonicalModelID = nil

        for (previous, resumed) in [(current, changed), (legacy, current)] {
            do {
                try TextToSQLEvalResumeCompatibility.validate(
                    previous: previous,
                    current: resumed
                )
                Issue.record("Expected compatibility rejection.")
            } catch let error as TextToSQLEvalResumeCompatibilityError {
                #expect(error.issues.map(\.field) == ["expected canonical model"])
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func compatibilityDefaultsMissingSchemaAgentModesToDiagnosticsOnly() throws {
        let previous = Self.compatibility()
        var current = Self.compatibility()
        current.schemaAgentClarificationCorrectionMode =
            SchemaToolAgentClarificationCorrectionMode.diagnosticsOnly.rawValue
        current.schemaAgentIntentCoverageMode = SchemaToolAgentIntentCoverageMode.diagnosticsOnly.rawValue

        try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
    }

    @Test func compatibilityRejectsChangedSchemaAgentModes() {
        let previous = Self.compatibility()
        var current = Self.compatibility()
        current.schemaAgentClarificationCorrectionMode =
            SchemaToolAgentClarificationCorrectionMode.correctOverClarificationExperimental.rawValue
        current.schemaAgentIntentCoverageMode =
            SchemaToolAgentIntentCoverageMode.correctAndRetryExperimental.rawValue

        do {
            try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
            Issue.record("Expected compatibility rejection.")
        } catch let error as TextToSQLEvalResumeCompatibilityError {
            let fields = Set(error.issues.map(\.field))
            #expect(fields.contains("schema agent clarification correction mode"))
            #expect(fields.contains("schema agent intent coverage mode"))
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

    @Test func budgetStateSeedsReusableCompletedResults() {
        let reused = [
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed),
            Self.result(caseID: "case.b", repeatIndex: 1, status: .passed),
        ]

        let state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxCompletedResults: 2),
            seedResults: reused
        )

        #expect(state.completedResults == 2)
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == "Eval completed-result budget reached (2/2).")
    }

    @Test func cloudCostBudgetIncludesCostsStoredOnFailedResults() {
        let failed = Self.result(
            caseID: "case.a",
            repeatIndex: 1,
            status: .parseFailure,
            estimatedCloudCostUSD: 0.75
        )

        let state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxCloudCostUSD: Decimal(string: "0.75")),
            seedResults: [failed]
        )

        #expect(state.cloudCostUSD == Decimal(string: "0.75"))
        #expect(
            state.stopReasonBeforeNextResult(backend: .cloud)
                == "Eval estimated cloud-cost budget reached ($0.75/$0.75)."
        )
    }

    @Test func httpBudgetStopsCloudAndReportsRemainingAttempts() {
        let reused = [
            Self.result(
                caseID: "case.a",
                repeatIndex: 1,
                status: .passed,
                openRouterHTTPAttempts: 2
            ),
        ]

        let state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxHTTPAttempts: 2),
            seedResults: reused
        )

        #expect(state.httpAttempts == 2)
        #expect(state.remainingHTTPAttempts(for: .cloud) == 0)
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == "Eval OpenRouter HTTP-attempt budget reached (2/2).")
    }

    @Test func httpBudgetUsesCumulativeModelCallsForRepairedAgentResults() {
        let reused = [
            Self.result(
                caseID: "case.a",
                repeatIndex: 1,
                status: .passed,
                modelCallCount: 3,
                openRouterHTTPAttempts: 1
            ),
        ]

        let state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxHTTPAttempts: 3),
            seedResults: reused
        )

        #expect(state.httpAttempts == 3)
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == "Eval OpenRouter HTTP-attempt budget reached (3/3).")
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
        #expect(text.contains("eval-release-sql-shape"))
        #expect(text.contains("--case commerce.average-order-value-country"))
        #expect(text.contains("--case preseason.active-match-configs"))
        #expect(text.contains("--case support.unresolved-by-assignee"))
    }

    @Test func releaseResumeMakeArgumentsPreserveModelOverrideSemantics() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pinned = try Self.releaseResumeDryRunCommand(repoRoot: repoRoot)
        #expect(pinned.contains(#"--model "openai/gpt-5.5""#))
        #expect(!pinned.contains("--allow-model-override"))

        let inherited = try Self.releaseResumeDryRunCommand(
            repoRoot: repoRoot,
            assignments: ["ALLOW_MODEL_OVERRIDE=1"]
        )
        #expect(!inherited.contains("--model"))
        #expect(inherited.contains("--allow-model-override"))

        let explicit = try Self.releaseResumeDryRunCommand(
            repoRoot: repoRoot,
            assignments: ["ALLOW_MODEL_OVERRIDE=1", "MODEL=vendor/model"]
        )
        #expect(explicit.contains(#"--model "vendor/model""#))
        #expect(explicit.contains("--allow-model-override"))

        let environment = try Self.releaseResumeDryRunCommand(
            repoRoot: repoRoot,
            assignments: ["ALLOW_MODEL_OVERRIDE=1"],
            environmentModel: "environment/model"
        )
        #expect(environment.contains(#"--model "environment/model""#))
        #expect(environment.contains("--allow-model-override"))
    }

    @Test func makefileKeepsExperimentalSchemaAgentFlagsFocused() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let makefile = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Makefile")
        let text = try String(contentsOf: makefile, encoding: .utf8)

        let releaseRecipe = try #require(Self.makefileRecipe(named: "eval-release", in: text))
        #expect(!releaseRecipe.contains("--schema-agent-clarification-correction"))
        #expect(!releaseRecipe.contains("--schema-agent-intent-coverage"))
        #expect(!releaseRecipe.contains("--schema-agent-plan-consistency"))

        let focusedRecipe = try #require(
            Self.makefileRecipe(named: "eval-release-overclarification", in: text)
        )
        #expect(focusedRecipe.contains("--schema-agent-clarification-correction experimental"))
        #expect(focusedRecipe.contains("--schema-agent-intent-coverage experimental"))

        let sqlShapeRecipe = try #require(
            Self.makefileRecipe(named: "eval-release-sql-shape", in: text)
        )
        #expect(!sqlShapeRecipe.contains("--schema-agent-clarification-correction"))
        #expect(!sqlShapeRecipe.contains("--schema-agent-intent-coverage"))
        #expect(!sqlShapeRecipe.contains("--schema-agent-plan-consistency"))
    }

    @Test func makefileHasNoOnDeviceEvalTargets() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )

        for removed in [
            "test-fm", "eval-local", "eval-all", "eval-db-local",
            "--backend local", "--backend both", "BACKEND ?=", "$(BACKEND)",
        ] {
            #expect(!text.contains(removed), "Makefile still mentions \(removed)")
        }

        let caseCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-case",
            assignments: ["CASE=commerce.fixture", "BACKEND=local"],
            commandContaining: "--case commerce.fixture"
        )
        #expect(caseCommand.contains(#"--backend cloud --model "openai/gpt-5.5""#))
        #expect(!caseCommand.contains("--backend local"))

        let databaseCaseCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-db-case",
            assignments: ["CASE=commerce.fixture", "BACKEND=local"],
            commandContaining: "--case commerce.fixture"
        )
        #expect(databaseCaseCommand.contains(#"--backend cloud --model "openai/gpt-5.5" --semantic-db"#))
        #expect(!databaseCaseCommand.contains("--backend local"))
    }

    @Test func evalResultFromRemovedOnDeviceBackendFailsToDecodeWithClearMessage() throws {
        let line = Self.cloudResultLine0_1_0.replacingOccurrences(
            of: #""backend":"cloud""#,
            with: #""backend":"local""#
        )
        #expect(line != Self.cloudResultLine0_1_0)

        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(TextToSQLEvalResult.self, from: Data(line.utf8))
        }
        guard case .dataCorrupted(let context) = error else {
            Issue.record("Expected dataCorrupted, got \(error)")
            return
        }
        #expect(context.debugDescription.contains("removed on-device backend"))
        #expect(context.debugDescription == TextToSQLEvalBackend.removedOnDeviceBackendMessage)
        #expect(context.codingPath.map(\.stringValue) == ["backend"])
    }

    @Test func evalResultWithUnknownBackendStillFailsToDecode() {
        let line = Self.cloudResultLine0_1_0.replacingOccurrences(
            of: #""backend":"cloud""#,
            with: #""backend":"elsewhere""#
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TextToSQLEvalResult.self, from: Data(line.utf8))
        }
    }

    @Test func cloudEvalResultShapedLike0_1_0Decodes() throws {
        let result = try JSONDecoder().decode(
            TextToSQLEvalResult.self,
            from: Data(Self.cloudResultLine0_1_0.utf8)
        )

        #expect(result.backend == .cloud)
        #expect(result.caseID == "commerce.customer-paid-revenue")
        #expect(result.model == "openai/gpt-5.5")
        #expect(result.repeatIndex == 2)
        #expect(result.status == .passed)
        #expect(result.metrics.openRouterReturnedModelID == "openai/gpt-5.5-20260423")
        #expect(result.metrics.openRouterAgentHTTPAttemptCount == 3)
        #expect(result.metrics.semanticStatus == .passed)
        #expect(result.metrics.endToEndPassed == true)
        #expect(result.diagnostics.openRouterAttemptCount == 3)
        #expect(result.referencedTables == ["public.customers", "public.orders"])

        let roundTripped = try JSONDecoder().decode(
            TextToSQLEvalResult.self,
            from: JSONEncoder().encode(result)
        )
        #expect(roundTripped == result)
    }

    @Test func releaseReportsIncludeRedactedQueryPlanDiagnostics() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let releaseReporter = repoRoot.appendingPathComponent("WidenEval/ReleaseGateReporter.swift")
        let releaseText = try String(contentsOf: releaseReporter, encoding: .utf8)
        #expect(releaseText.contains("| Query Plan |"))
        #expect(releaseText.contains("terminalQueryPlan"))
        #expect(releaseText.contains("QueryPlanReportSummary.redactedSummary"))
        #expect(!releaseText.contains("queryPlan.isEmpty ? \"-\" : queryPlan"))

        let evalReporter = repoRoot.appendingPathComponent("WidenEval/EvalReporter.swift")
        let evalText = try String(contentsOf: evalReporter, encoding: .utf8)
        #expect(evalText.contains("query plan:"))
        #expect(evalText.contains("terminalQueryPlan"))
        #expect(evalText.contains("QueryPlanReportSummary.redactedSummary"))
        #expect(!evalText.contains(#"query plan: \(queryPlan)"#))
    }

    @Test func releaseTriageClassifiesSchemaAgentTimeoutSeparatelyFromToolBudget() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let releaseReporter = repoRoot.appendingPathComponent("WidenEval/ReleaseGateReporter.swift")
        let releaseText = try String(contentsOf: releaseReporter, encoding: .utf8)
        #expect(releaseText.contains("case schemaAgentTimeout = \"schema-agent timeout\""))
        #expect(releaseText.contains("| Internal schema-agent timeouts |"))

        let classifierStart = try #require(
            releaseText.range(of: "private static func category(")
        )
        let classifierText = String(releaseText[classifierStart.lowerBound...])
        let timedOutCheck = try #require(
            classifierText.range(of: "appSideRejectionReason == .timedOut")
        )
        let budgetCheck = try #require(
            classifierText.range(of: "appSideRejectionReason == .budgetExhausted")
        )
        #expect(timedOutCheck.lowerBound < budgetCheck.lowerBound)
    }

    @Test func releaseTriageReportsRedundantSchemaToolInterceptions() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let releaseReporter = repoRoot.appendingPathComponent("WidenEval/ReleaseGateReporter.swift")
        let releaseText = try String(contentsOf: releaseReporter, encoding: .utf8)
        #expect(releaseText.contains("| Redundant |"))
        #expect(releaseText.contains("redundantDuplicateToolCallCount"))
        #expect(releaseText.contains("redundantZeroResultSearchCount"))
        #expect(releaseText.contains("redundantJoinPathCallCount"))
    }

    @Test func releaseTriageReportsIntentPolicyWithoutClarificationPolicy() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let releaseReporter = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WidenEval/ReleaseGateReporter.swift")
        let releaseText = try String(contentsOf: releaseReporter, encoding: .utf8)
        let policyStart = try #require(
            releaseText.range(of: "private static func policySummary(")
        )
        let policyText = String(releaseText[policyStart.lowerBound...])

        #expect(
            policyText.contains(
                "!diagnostics.clarificationPolicyDecision.isEmpty\n"
                    + "                    || !diagnostics.sqlIntentCoverageDecision.isEmpty"
            )
        )
        #expect(policyText.contains("var parts: [String] = []"))
        #expect(policyText.contains("parts.append(diagnostics.clarificationPolicyDecision)"))
    }

    @Test func evalSourceManifestPathsExistUnderRepositoryRoot() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let oneShotPaths = TextToSQLEvalSourceManifest.scorerSourcePaths(
            includesSchemaToolAgent: false
        )
        let agentPaths = TextToSQLEvalSourceManifest.scorerSourcePaths(
            includesSchemaToolAgent: true
        )
        let semanticPaths = TextToSQLEvalSourceManifest.semanticComparatorSourcePaths

        for path in oneShotPaths + agentPaths + semanticPaths {
            #expect(
                FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(path).path
                ),
                "\(path) is listed in TextToSQLEvalSourceManifest but does not exist"
            )
        }
        #expect(Set(oneShotPaths).isSubset(of: Set(agentPaths)))
        #expect(oneShotPaths.contains("WidenKit/Models/SQLGenerationResult.swift"))
        #expect(oneShotPaths.contains("WidenKit/Models/OpenRouterCatalog.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/OpenRouterSQLGenerator.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/HTTPTransport.swift"))
        #expect(agentPaths.contains("WidenKit/Services/OpenRouterSchemaToolSQLAgent.swift"))
        #expect(agentPaths.contains("WidenKit/Services/SchemaToolRuntime.swift"))

        let hash = try TextToSQLEvalSourceManifest.sourceHash(
            relativePaths: agentPaths,
            relativeTo: repoRoot
        )
        #expect(hash.count == 64)
    }

    @Test func evalSourceHashThrowsNamingTheMissingPath() throws {
        let directory = try Self.sourceHashFixtureDirectory(files: ["a.swift": "let a = 1"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: TextToSQLEvalSourceHashError(missingPath: "Renamed/b.swift")) {
            try TextToSQLEvalSourceManifest.sourceHash(
                relativePaths: ["a.swift", "Renamed/b.swift"],
                relativeTo: directory
            )
        }
    }

    @Test func evalSourceHashIgnoresListOrderButTracksContents() throws {
        let directory = try Self.sourceHashFixtureDirectory(
            files: ["a.swift": "let a = 1", "b.swift": "let b = 2"]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let forward = try TextToSQLEvalSourceManifest.sourceHash(
            relativePaths: ["a.swift", "b.swift"],
            relativeTo: directory
        )
        let reversed = try TextToSQLEvalSourceManifest.sourceHash(
            relativePaths: ["b.swift", "a.swift"],
            relativeTo: directory
        )
        #expect(forward == reversed)

        try Data("let b = 3".utf8).write(to: directory.appendingPathComponent("b.swift"))
        let edited = try TextToSQLEvalSourceManifest.sourceHash(
            relativePaths: ["a.swift", "b.swift"],
            relativeTo: directory
        )
        #expect(edited != forward)
    }

    private static func sourceHashFixtureDirectory(files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(path))
        }
        return directory
    }

    private static func makefileRecipe(named target: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { $0 == "\(target): eval-build" }) else {
            return nil
        }
        let recipeLines = lines[(start + 1)...].prefix { line in
            line.hasPrefix("\t") || line.isEmpty
        }
        return recipeLines.joined(separator: "\n")
    }

    private static func releaseResumeDryRunCommand(
        repoRoot: URL,
        assignments: [String] = [],
        environmentModel: String? = nil
    ) throws -> String {
        try makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-release-resume",
            assignments: ["RELEASE_VERSION=fixture", "RESUME=fixture-run"] + assignments,
            environmentModel: environmentModel,
            commandContaining: "--resume-run"
        )
    }

    private static func makeDryRunCommand(
        repoRoot: URL,
        target: String,
        assignments: [String] = [],
        environmentModel: String? = nil,
        commandContaining marker: String
    ) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        for name in ["ALLOW_MODEL_OVERRIDE", "BACKEND", "CASE", "MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MODEL"] {
            environment.removeValue(forKey: name)
        }
        if let environmentModel {
            environment["MODEL"] = environmentModel
        }
        guard let makeURL = environment["PATH"]?
            .split(separator: ":")
            .map({ directory in
                URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent("make")
            })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            throw NSError(
                domain: "TextToSQLEvalRunPlanningTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not find make on PATH."]
            )
        }

        let process = Process()
        process.executableURL = makeURL
        process.currentDirectoryURL = repoRoot
        process.arguments = ["--no-print-directory", "-n", target] + assignments
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TextToSQLEvalRunPlanningTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        guard let command = text.split(separator: "\n").first(where: {
            $0.contains(marker)
        }) else {
            throw NSError(
                domain: "TextToSQLEvalRunPlanningTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Make dry run of \(target) omitted the \(marker) command."]
            )
        }
        return String(command)
    }

    /// One cases.jsonl line in the shape the 0.1.0 OpenRouter release gate wrote.
    private static let cloudResultLine0_1_0 = """
        {"caseID":"commerce.customer-paid-revenue","backend":"cloud","model":"openai/gpt-5.5",\
        "repeatIndex":2,"status":"passed","metrics":{"backendAvailable":true,"transportSuccess":true,\
        "structuredResponseParsed":true,"decisionMatches":true,"safetyValid":true,"schemaValid":true,\
        "requiredTableCoverage":1,"requiredColumnBindingCoverage":1,"forbiddenBindingViolations":[],\
        "latencyMs":18234,"modelCallCount":3,"estimatedInitialPromptCharacters":412,"tokenUsage":9120,\
        "estimatedCloudCostUSD":0.0412,"openRouterStructuredOutputMode":"strictJSONSchema",\
        "openRouterRetryCount":0,"openRouterRequestedModelID":"openai/gpt-5.5",\
        "openRouterReturnedModelID":"openai/gpt-5.5-20260423","openRouterProviderName":"OpenAI",\
        "openRouterAgentSelectionReason":"tools","openRouterAgentLogicalTurnCount":3,\
        "openRouterAgentHTTPAttemptCount":3,"openRouterSchemaToolCallCount":2,\
        "openRouterInspectionToolCallCount":0,"openRouterAgentTerminalOutcome":"sql",\
        "postgresVerificationStatus":"passed","postgresVerificationElapsedMs":14,\
        "postgresVerificationRepairAttempted":false,"semanticExecutionAttempted":true,\
        "semanticEnvironmentAvailable":true,"goldenExecutionSucceeded":true,\
        "candidateExecutionSucceeded":true,"resultEquivalent":true,"endToEndPassed":true,\
        "semanticStatus":"passed","goldenRowCount":4,"candidateRowCount":4,"comparisonMode":"unordered",\
        "executionLatencyMs":9,"goldenResultDigest":"3f1c","candidateResultDigest":"3f1c"},\
        "diagnostics":{"missingTables":[],"missingColumnBindings":[],"missingOperations":[],\
        "safetyErrors":[],"schemaErrors":[],"openRouterAttemptCount":3},\
        "generatedSQL":"SELECT c.id, SUM(o.total) AS paid_revenue FROM public.customers AS c \
        JOIN public.orders AS o ON o.customer_id = c.id WHERE o.status = 'paid' GROUP BY c.id LIMIT 100",\
        "referencedTables":["public.customers","public.orders"],\
        "referencedColumnBindings":["public.customers.id","public.orders.customer_id",\
        "public.orders.status","public.orders.total"]}
        """

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
        endToEndPassed: Bool? = nil,
        modelCallCount: Int? = nil,
        openRouterHTTPAttempts: Int? = nil,
        estimatedCloudCostUSD: Double? = nil
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
                modelCallCount: modelCallCount,
                estimatedCloudCostUSD: estimatedCloudCostUSD,
                openRouterAgentHTTPAttemptCount: openRouterHTTPAttempts,
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
            expectedCanonicalModelID: "openai/gpt-5.5-20260423",
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
