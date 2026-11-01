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

    @Test func compatibilityRejectsChangedProviderOrReasoningEffort() {
        var previous = Self.compatibility()
        previous.provider = "particle"
        previous.model = "particle-1"
        previous.expectedCanonicalModelID = "particle-ai/particle-1"
        previous.reasoningEffort = "high"
        var lowerEffort = previous
        lowerEffort.reasoningEffort = "low"
        var noEffort = previous
        noEffort.reasoningEffort = nil
        var otherProvider = previous
        otherProvider.provider = "openrouter"

        for (current, field) in [
            (lowerEffort, "reasoning effort"),
            (noEffort, "reasoning effort"),
            (otherProvider, "provider"),
        ] {
            do {
                try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
                Issue.record("Expected compatibility rejection for \(field).")
            } catch let error as TextToSQLEvalResumeCompatibilityError {
                #expect(error.issues.map(\.field) == [field])
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func compatibilityResolvesLegacyCloudManifestsToOpenRouter() throws {
        let legacy = Self.compatibility()
        #expect(legacy.provider == nil)
        var openRouter = legacy
        openRouter.provider = "openrouter"
        try TextToSQLEvalResumeCompatibility.validate(previous: legacy, current: openRouter)

        var particle = openRouter
        particle.provider = "particle"
        particle.model = "particle-1"
        particle.expectedCanonicalModelID = "particle-ai/particle-1"
        particle.reasoningEffort = "high"
        do {
            try TextToSQLEvalResumeCompatibility.validate(previous: legacy, current: particle)
            Issue.record("Expected compatibility rejection.")
        } catch let error as TextToSQLEvalResumeCompatibilityError {
            #expect(
                error.issues.map(\.field)
                    == ["provider", "model", "expected canonical model", "reasoning effort"]
            )
            #expect(
                error.issues.first
                    == TextToSQLEvalResumeCompatibilityIssue(
                        field: "provider",
                        previous: "openrouter",
                        current: "particle"
                    )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
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

    @Test func compatibilityTreatsAMissingCriticModeAsDisabled() throws {
        // A manifest from before the critic recorded no mode and ran without it.
        let previous = Self.compatibility()
        var current = Self.compatibility()
        current.schemaAgentCriticMode = SchemaToolAgentCriticMode.disabled.rawValue
        try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)

        current.schemaAgentCriticMode = SchemaToolAgentCriticMode.enabled.rawValue
        #expect(
            throws: TextToSQLEvalResumeCompatibilityError(issues: [
                TextToSQLEvalResumeCompatibilityIssue(
                    field: "schema agent critic mode",
                    previous: "disabled",
                    current: "enabled"
                ),
            ])
        ) {
            try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
        }
    }

    @Test func compatibilityRejectsAChangedCriticMode() throws {
        var previous = Self.compatibility()
        previous.schemaAgentCriticMode = SchemaToolAgentCriticMode.enabled.rawValue
        var current = previous
        try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)

        current.schemaAgentCriticMode = SchemaToolAgentCriticMode.disabled.rawValue
        #expect(
            throws: TextToSQLEvalResumeCompatibilityError(issues: [
                TextToSQLEvalResumeCompatibilityIssue(
                    field: "schema agent critic mode",
                    previous: "enabled",
                    current: "disabled"
                ),
            ])
        ) {
            try TextToSQLEvalResumeCompatibility.validate(previous: previous, current: current)
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

    @Test func cloudCostBudgetStopsWhenAResultUsesTokensWithoutACost() {
        var state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(
                maxCloudCostUSD: Decimal(string: "1.00"),
                maxCompletedResults: 1
            )
        )
        state.record(
            Self.result(
                caseID: "case.priced",
                repeatIndex: 1,
                status: .wrongDecision,
                tokenUsage: 80,
                estimatedCloudCostUSD: 0.01
            )
        )
        #expect(state.costAccountingFailure == nil)

        state.record(
            Self.result(caseID: "case.unpriced", repeatIndex: 2, status: .passed, tokenUsage: 120)
        )
        state.record(
            Self.result(caseID: "case.later", repeatIndex: 1, status: .passed, tokenUsage: 40)
        )

        let expected = "Eval cloud-cost budget cannot be enforced: case.unpriced (repeat 2) used 120 tokens but recorded no cost."
        #expect(state.costAccountingFailure == expected)
        #expect(state.cloudCostUSD == Decimal(string: "0.01"))
        // It is reported ahead of the completed-result budget that is also spent.
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == expected)
    }

    @Test func resumedResultWithTokensButNoCostStopsTheRunBeforeItsFirstRequest() {
        let state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxCloudCostUSD: Decimal(string: "1.00")),
            seedResults: [
                Self.result(caseID: "case.a", repeatIndex: 1, status: .passed, tokenUsage: 9),
            ]
        )

        #expect(
            state.stopReasonBeforeNextResult(backend: .cloud)
                == "Eval cloud-cost budget cannot be enforced: case.a (repeat 1) used 9 tokens but recorded no cost."
        )
    }

    @Test func tokensWithoutACostDoNotStopARunWithoutACostBudget() {
        var state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxHTTPAttempts: 10, maxCompletedResults: 10)
        )
        state.record(
            Self.result(caseID: "case.a", repeatIndex: 1, status: .passed, tokenUsage: 120)
        )

        #expect(state.costAccountingFailure == nil)
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == nil)
    }

    @Test func resultsWithoutTokensNeverFailCostAccounting() {
        var state = TextToSQLEvalBudgetState(
            limits: TextToSQLEvalBudgetLimits(maxCloudCostUSD: Decimal(string: "1.00"))
        )
        // Skipped, unavailable and token-less results record neither tokens nor cost.
        state.record(Self.result(caseID: "case.skipped", repeatIndex: 1, status: .skippedBudgetLimit))
        state.record(Self.result(caseID: "case.down", repeatIndex: 1, status: .backendUnavailable))
        state.record(Self.result(caseID: "case.zero", repeatIndex: 1, status: .passed, tokenUsage: 0))

        #expect(state.costAccountingFailure == nil)
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == nil)
    }

    @Test func cloudCostBudgetIsRefusedUpFrontForAProfileWithNoCostAccounting() throws {
        let capped = TextToSQLEvalBudgetLimits(maxCloudCostUSD: Decimal(string: "0.25"))
        // Particle is priced from tokens; OpenRouter reports usage.cost.
        try capped.validateCostAccounting(for: .particleTest)
        try capped.validateCostAccounting(for: .openRouterTest)

        var unpriced = CloudModelProfile.openRouterTest.requestingModel("vendor/unpriced")
        unpriced.displayName = "vendor/unpriced"
        unpriced.pricing = nil
        unpriced.reportsUsageCost = false
        #expect(throws: TextToSQLEvalCostAccountingError.unpricedProfile(displayName: "vendor/unpriced")) {
            try capped.validateCostAccounting(for: unpriced)
        }
        let message = TextToSQLEvalCostAccountingError.unpricedProfile(displayName: "vendor/unpriced")
            .localizedDescription
        #expect(message.hasPrefix("--max-cloud-cost-usd cannot be enforced for vendor/unpriced:"))

        // Without a cost budget there is nothing to enforce.
        try TextToSQLEvalBudgetLimits(maxHTTPAttempts: 4).validateCostAccounting(for: unpriced)
    }

    @Test func evalRunnerRefusesUnpricedCostBudgetsAndFailsAfterWritingArtifacts() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runnerText = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/EvalRunner.swift"),
            encoding: .utf8
        )

        // The precheck runs once the profile is known and before any request.
        let settings = try #require(runnerText.range(of: "try TextToSQLEvalCloudSettings("))
        let precheck = try #require(
            runnerText.range(
                of: "try runner.options.budgetLimits.validateCostAccounting(for: cloud.profile)"
            )
        )
        let runResolved = try #require(
            runnerText.range(of: "return try await runner.runResolved(resumeRun: resumeRun, cloud: cloud)")
        )
        #expect(settings.lowerBound < precheck.lowerBound)
        #expect(precheck.lowerBound < runResolved.lowerBound)

        // A blind cost cap stops the loop like any budget, then fails the run
        // once every remaining slot is written as skipped.
        let loopStop = try #require(
            runnerText.range(of: "budgetStopReason = costAccountingFailure")
        )
        let failure = try #require(
            runnerText.range(of: "throw EvalRunnerError.costAccountingUnavailable(")
        )
        let finalRun = try #require(
            runnerText.range(
                of: "return makeRun(finishedAt: ISO8601DateFormatter().string(from: Date()))"
            )
        )
        #expect(loopStop.lowerBound < failure.lowerBound)
        #expect(failure.lowerBound < finalRun.lowerBound)
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
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == "Eval provider HTTP-attempt budget reached (2/2).")
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
        #expect(state.stopReasonBeforeNextResult(backend: .cloud) == "Eval provider HTTP-attempt budget reached (3/3).")
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
        #expect(pinned.contains(#"--model "particle-1""#))
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

    @Test func releaseResumeWritesTheCommittedTriageWithTheGateReport() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Resume never inherits the triage version from the manifest, so the
        // target passes it; otherwise docs/evals/ would pair a resumed gate
        // report with a triage from an earlier run, or with none.
        let command = try Self.releaseResumeDryRunCommand(repoRoot: repoRoot)
        #expect(command.contains(#"--release-gate-version "fixture""#))
        #expect(command.contains(#"--write-release-triage --release-triage-version "fixture""#))
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

    @Test func makefileProbeTargetLoadsTheEvalKeysAndSendsOnlyTheProbeFlag() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )

        let phony = try #require(text.split(separator: "\n").first { $0.hasPrefix(".PHONY:") })
        #expect(phony.split(separator: " ").contains("eval-provider-probe"))
        let recipe = try #require(Self.makefileRecipe(named: "eval-provider-probe", in: text))
        #expect(recipe.contains("set -a; if [ -f .env.eval.local ]; then . ./.env.eval.local; fi; set +a;"))

        let command = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-provider-probe",
            commandContaining: "--provider-probe"
        )
        #expect(command.trimmingCharacters(in: .whitespaces) == "build/Build/Products/Debug/WidenEval --provider-probe")
        let withOutput = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-provider-probe",
            assignments: ["OUTPUT=fixture-results", "CASE=commerce.fixture", "REPEAT=3"],
            commandContaining: "--provider-probe"
        )
        #expect(withOutput.contains(#"--provider-probe --output "fixture-results""#))
        for unrelated in ["--case", "--repeat", "--model", "--suite", "--backend"] {
            #expect(!withOutput.contains(unrelated), "probe command must not pass \(unrelated)")
        }

        // WidenEval reads the probe key through the probe's Particle-only
        // lookup and refuses to write a report that contains it.
        let main = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/WidenEvalMain.swift"),
            encoding: .utf8
        )
        #expect(main.contains(#"case "--provider-probe":"#))
        #expect(main.contains("ProviderAPIProbe.apiKey(in: ProcessInfo.processInfo.environment)"))
        #expect(main.contains("let paths = try report.write("))
        #expect(main.contains(#""provider-probe-" + DateFormatter.evalTimestamp"#))
    }

    @Test func makefileHasNoOnDeviceEvalTargets() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )

        // The CLI default backend is cloud, so no recipe passes --backend.
        for removed in [
            "test-fm", "eval-local", "eval-all", "eval-db-local", "--backend", "BACKEND ?=",
        ] {
            #expect(!text.contains(removed), "Makefile still mentions \(removed)")
        }

        let caseCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-case",
            assignments: ["CASE=commerce.fixture"],
            commandContaining: "--case commerce.fixture"
        )
        #expect(caseCommand.contains(#"WidenEval --model "particle-1" --suite"#))

        // A leftover BACKEND=cloud is still accepted and still adds no flag.
        let databaseCaseCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-db-case",
            assignments: ["CASE=commerce.fixture", "BACKEND=cloud"],
            commandContaining: "--case commerce.fixture"
        )
        #expect(databaseCaseCommand.contains(#"WidenEval --model "particle-1" --semantic-db"#))
        #expect(!databaseCaseCommand.contains("--backend"))
    }

    @Test func makefileRunsParticle1ByDefaultOnEveryModelTarget() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for (target, assignments) in Self.modelEvalTargets {
            let (status, output) = try Self.makeDryRun(
                repoRoot: repoRoot,
                target: target,
                assignments: assignments
            )
            #expect(status == 0, "make -n \(target): \(output)")
            let command = try #require(
                output.split(separator: "\n").first { $0.contains(Self.evalCommandMarker) },
                "make -n \(target) omitted the WidenEval command"
            )
            #expect(command.contains(#"--model "particle-1""#), "make -n \(target): \(command)")
            #expect(!output.contains("--backend"), "make -n \(target): \(output)")
        }

        // OpenRouter comparisons stay available on the non-gate targets.
        for target in ["eval-cloud", "eval-db-cloud-agent", "eval-smoke"] {
            let command = try Self.makeDryRunCommand(
                repoRoot: repoRoot,
                target: target,
                assignments: ["MODEL=openai/gpt-5.5"],
                commandContaining: Self.evalCommandMarker
            )
            #expect(command.contains(#"--model "openai/gpt-5.5""#), "make -n \(target): \(command)")
        }
    }

    @Test func makefileSmokeTargetRunsTheProviderSmokeSuiteThroughTheAgent() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )

        let phony = try #require(text.split(separator: "\n").first { $0.hasPrefix(".PHONY:") })
        #expect(phony.split(separator: " ").contains("eval-smoke"))
        #expect(!text.contains("eval-openrouter-smoke"))
        #expect(Self.makefileRecipe(named: "eval-smoke", in: text) != nil)

        let command = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-smoke",
            commandContaining: Self.evalCommandMarker
        )
        #expect(
            command.contains(
                #"WidenEval --model "particle-1" --cloud-agent "tools" --suite Evals/suites/provider-smoke-v1.json"#
            )
        )
        #expect(!command.contains("text-to-sql-v1.json"))

        let legacy = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-smoke",
            assignments: ["CLOUD_AGENT=legacy", "MODEL=openai/gpt-5.5", "REPEAT=3"],
            commandContaining: Self.evalCommandMarker
        )
        #expect(legacy.contains(#"--model "openai/gpt-5.5" --cloud-agent "legacy""#))
        #expect(legacy.contains("--repeat 3"))

        let (status, output) = try Self.makeDryRun(repoRoot: repoRoot, target: "eval-openrouter-smoke")
        #expect(status != 0, "eval-openrouter-smoke should no longer exist: \(output)")
    }

    @Test func makefilePassesReasoningEffortAndCasesToNonGateTargetsOnly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )
        let overrides = [
            "REASONING_EFFORT=medium",
            "CASES=commerce.customer-paid-revenue saas.overallocated-seats",
        ]
        let passedCases = "--case commerce.customer-paid-revenue --case saas.overallocated-seats"

        for target in ["eval-cloud", "eval-cloud-agent", "eval-smoke", "eval-db-cloud", "eval-db-cloud-agent"] {
            let command = try Self.makeDryRunCommand(
                repoRoot: repoRoot,
                target: target,
                assignments: overrides,
                commandContaining: Self.evalCommandMarker
            )
            #expect(command.contains("--reasoning-effort medium"), "make -n \(target): \(command)")
            #expect(command.contains(passedCases), "make -n \(target): \(command)")
        }
        let caseCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-db-case",
            assignments: ["CASE=commerce.fixture"] + overrides,
            commandContaining: Self.evalCommandMarker
        )
        #expect(caseCommand.contains("--case commerce.fixture \(passedCases)"))
        #expect(caseCommand.contains("--reasoning-effort medium"))

        let withoutOverrides = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "eval-cloud",
            commandContaining: Self.evalCommandMarker
        )
        #expect(!withoutOverrides.contains("--reasoning-effort"))
        #expect(!withoutOverrides.contains("--case"))

        // The release gate always runs the full suite at the production
        // effort, so its recipes never see either variable.
        for target in Self.releaseGateTargets {
            let recipe = try #require(Self.makefileRecipe(named: target, in: text), "\(target)")
            for forbidden in ["--reasoning-effort", "REASONING_EFFORT", "CASES", "EVAL_ARGS"] {
                #expect(!recipe.contains(forbidden), "\(target) recipe mentions \(forbidden)")
            }
            let assignments = Self.modelEvalTargets.first { $0.target == target }?.assignments ?? []
            let command = try Self.makeDryRunCommand(
                repoRoot: repoRoot,
                target: target,
                assignments: assignments + overrides,
                commandContaining: Self.evalCommandMarker
            )
            #expect(!command.contains("--reasoning-effort"), "make -n \(target): \(command)")
            #expect(!command.contains("commerce.customer-paid-revenue"), "make -n \(target): \(command)")
        }
    }

    @Test func makefileRejectsRemovedBackendInsteadOfRunningPaidCloudEval() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for (target, backend) in [
            ("eval-case", "local"), ("eval-db-case", "local"), ("eval-case", "both"),
        ] {
            let (status, output) = try Self.makeDryRun(
                repoRoot: repoRoot,
                target: target,
                assignments: ["CASE=commerce.fixture", "BACKEND=\(backend)"]
            )
            #expect(status != 0, "make -n \(target) BACKEND=\(backend) should fail")
            #expect(
                output.contains("BACKEND=\(backend) is no longer supported"),
                "make -n \(target) BACKEND=\(backend): \(output)"
            )
            #expect(!output.contains("--model"), "make -n \(target) BACKEND=\(backend): \(output)")
        }

        // An unrelated BACKEND variable must not break non-eval targets.
        let projectCommand = try Self.makeDryRunCommand(
            repoRoot: repoRoot,
            target: "project",
            assignments: ["BACKEND=local"],
            commandContaining: "xcodegen generate"
        )
        #expect(projectCommand == "xcodegen generate")
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

    @Test func widenEvalRejectsRemovedBackendsWithClearMessages() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainText = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/WidenEvalMain.swift"),
            encoding: .utf8
        )

        #expect(mainText.contains(#"static let removedRawValues: Set<String> = ["local", "both"]"#))
        let backendStart = try #require(mainText.range(of: #"case "--backend":"#))
        let backendText = String(mainText[backendStart.upperBound...])
        let removedCheck = try #require(
            backendText.range(of: "if EvalBackendMode.removedRawValues.contains(value) {")
        )
        let removedThrow = try #require(
            backendText.range(of: "throw EvalCLIError.removedBackend(value)")
        )
        let rawValueParse = try #require(
            backendText.range(of: "EvalBackendMode(rawValue: value)")
        )
        #expect(removedCheck.lowerBound < removedThrow.lowerBound)
        #expect(removedThrow.lowerBound < rawValueParse.lowerBound)
        #expect(
            mainText.contains(
                #""--backend \(backendMode) is no longer supported because the on-device backend was removed; use --backend cloud.""#
            )
        )

        // A DecodingError's localized description is generic, so the CLI prints
        // its context instead; that is where the removed-backend message lives.
        let decodingCatch = try #require(mainText.range(of: "} catch let error as DecodingError {"))
        let genericCatch = try #require(
            mainText.range(of: "} catch {", range: decodingCatch.upperBound..<mainText.endIndex)
        )
        let decodingHandler = String(mainText[decodingCatch.upperBound..<genericCatch.lowerBound])
        #expect(decodingHandler.contains(#"fputs("WidenEval failed: \(error.contextDescription)\n", stderr)"#))
        #expect(decodingHandler.contains("exit(1)"))
        let contextStart = try #require(mainText.range(of: "var contextDescription: String {"))
        #expect(mainText[contextStart.upperBound...].contains("context.debugDescription"))

        let runnerText = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/EvalRunner.swift"),
            encoding: .utf8
        )
        let resumeStart = try #require(
            runnerText.range(of: "private mutating func applyResumeDefaults(")
        )
        let resumeText = String(runnerText[resumeStart.upperBound...])
        let resumeBackendParse = try #require(
            resumeText.range(of: "EvalBackendMode(rawValue: previousRun.manifest.backendMode)")
        )
        let resumeRemovedCheck = try #require(
            resumeText.range(
                of: "EvalBackendMode.removedRawValues.contains(previousRun.manifest.backendMode)"
                    + "\n                        ? TextToSQLEvalBackend.removedOnDeviceBackendMessage"
            )
        )
        #expect(resumeBackendParse.lowerBound < resumeRemovedCheck.lowerBound)
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

    @Test func deterministicEvalScopeCopyIsProviderNeutral() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for path in [
            "WidenEval/DatabaseInspectionEvalReporter.swift",
            "WidenEval/SchemaRetrievalEvalReporter.swift",
            "WidenEval/SchemaToolContractEvalRunner.swift",
        ] {
            let text = try String(
                contentsOf: repoRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            let scopeLines = text.split(separator: "\n").filter {
                $0.contains("**Evaluation scope:**")
            }
            #expect(scopeLines.count == 1, "\(path) should have one evaluation scope line")
            for line in scopeLines {
                #expect(line.contains("LLM provider"), "\(path): \(line)")
                #expect(!line.contains("OpenRouter"), "\(path): \(line)")
                #expect(!line.contains("Foundation Models"), "\(path): \(line)")
            }
        }
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
        #expect(oneShotPaths.contains("WidenKit/Models/CloudModelProfile.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/CloudSQLGenerator.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/ChatCompletionsCore.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/SchemaToolAgentDiagnostics.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/OpenRouterEvalSupport.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/HTTPTransport.swift"))
        // The scorer's safety, schema and reference metrics, and the pipeline's
        // GeneratedSQLPostprocessor grounding, come from these validators.
        #expect(oneShotPaths.contains("WidenKit/Services/SQLSafetyValidator.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/SQLSchemaValidator.swift"))
        #expect(oneShotPaths.contains("WidenKit/Services/SQLReferenceAnalyzer.swift"))
        #expect(agentPaths.contains("WidenKit/Services/SchemaToolSQLAgent.swift"))
        #expect(agentPaths.contains("WidenKit/Services/SchemaToolRuntime.swift"))
        #expect(agentPaths.contains("WidenKit/Services/SchemaToolAgentCritic.swift"))
        #expect(!oneShotPaths.contains("WidenKit/Services/SchemaToolAgentCritic.swift"))

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

    /// Marks the WidenEval command in `make -n` output, as opposed to the
    /// eval-build xcodebuild line that names the WidenEval scheme.
    private static let evalCommandMarker = "Debug/WidenEval "

    /// The gate targets that publish committed docs.
    private static let releaseGateTargets = ["eval-release", "eval-release-triage", "eval-release-resume"]

    /// Every target that runs a text-to-SQL model, with the variables its
    /// recipe requires.
    private static let modelEvalTargets: [(target: String, assignments: [String])] = [
        ("eval-cloud", []),
        ("eval-cloud-agent", []),
        ("eval-smoke", []),
        ("eval-case", ["CASE=commerce.fixture"]),
        ("eval-cloud-agent-case", ["CASE=commerce.fixture"]),
        ("eval-db-cloud", []),
        ("eval-db-cloud-agent", []),
        ("eval-db-cloud-agent-case", ["CASE=commerce.fixture"]),
        ("eval-db-case", ["CASE=commerce.fixture"]),
        ("eval-release", ["RELEASE_VERSION=fixture"]),
        ("eval-release-triage", ["RELEASE_VERSION=fixture"]),
        ("eval-release-preseason", []),
        ("eval-release-overclarification", []),
        ("eval-release-sql-shape", []),
        ("eval-release-resume", ["RELEASE_VERSION=fixture", "RESUME=fixture-run"]),
    ]

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
        let (status, text) = try makeDryRun(
            repoRoot: repoRoot,
            target: target,
            assignments: assignments,
            environmentModel: environmentModel
        )
        guard status == 0 else {
            throw NSError(
                domain: "TextToSQLEvalRunPlanningTests",
                code: Int(status),
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

    /// Runs `make -n` and returns its exit status with the combined output.
    private static func makeDryRun(
        repoRoot: URL,
        target: String,
        assignments: [String] = [],
        environmentModel: String? = nil
    ) throws -> (status: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        for name in [
            "ALLOW_MODEL_OVERRIDE", "BACKEND", "CASE", "CASES", "CLOUD_AGENT", "MAKEFLAGS", "MAKELEVEL",
            "MFLAGS", "MODEL", "REASONING_EFFORT",
        ] {
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
        return (process.terminationStatus, text)
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
        tokenUsage: Int? = nil,
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
                tokenUsage: tokenUsage,
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
