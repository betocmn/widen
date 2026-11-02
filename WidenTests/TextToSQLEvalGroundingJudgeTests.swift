import Foundation
import Testing

@testable import WidenKit

/// The eval's grounding judge flag, the judge-off arm it derives inside the
/// same run, and the counts the grounding judge experiment's preregistered
/// criteria read.
@Suite("Text-to-SQL eval grounding judge")
struct TextToSQLEvalGroundingJudgeTests {
    @Test func flagAcceptsOnOffAndTheModeNames() {
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: "on") == .enabled)
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: "enabled") == .enabled)
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: "off") == .disabled)
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: "disabled") == .disabled)
        for value in ["ON", "true", "yes", "diagnostics", ""] {
            #expect(TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: value) == nil, "\(value)")
        }
        #expect(
            TextToSQLEvalSchemaAgentGroundingJudge.recordedMode(
                in: SchemaToolSQLAgentConfiguration.default.reportedSettings
            ) == SchemaToolSQLAgentConfiguration.default.groundingJudgeMode.rawValue
        )
    }

    @Test func widenEvalParsesTheFlagAndFollowsTheAppDefault() throws {
        let main = try Self.source("WidenEval/WidenEvalMain.swift")

        #expect(
            main.contains(
                "var schemaAgentGroundingJudgeMode: SchemaToolAgentGroundingJudgeMode =\n"
                    + "        SchemaToolSQLAgentConfiguration.default.groundingJudgeMode\n"
            )
        )
        #expect(main.contains("--schema-agent-grounding-judge on|off|enabled|disabled (default: the app's, now "))

        let flagStart = try #require(main.range(of: #"case "--schema-agent-grounding-judge":"#))
        let flagCase = String(main[flagStart.upperBound...].prefix(500))
        #expect(
            flagCase.contains(
                "guard let mode = TextToSQLEvalSchemaAgentGroundingJudge.mode(flagValue: value) else {"
            )
        )
        #expect(flagCase.contains("throw EvalCLIError.invalidValue(argument, value)"))
        #expect(flagCase.contains("options.schemaAgentGroundingJudgeMode = mode"))
        #expect(flagCase.contains("options.explicitOptions.insert(.schemaAgentGroundingJudgeMode)"))
        #expect(main.contains("    case schemaAgentGroundingJudgeMode\n"))
    }

    @Test func evalRunnerRecordsTheJudgeModeInTheAgentConfiguration() throws {
        let runner = try Self.source("WidenEval/EvalRunner.swift")

        // One agent configuration feeds the manifest and the resume check.
        #expect(
            runner.contains(
                "groundingJudgeMode: options.schemaAgentGroundingJudgeMode,\n"
                    + "                criticMode: options.schemaAgentCriticMode\n"
                    + "            ).reportedSettings"
            )
        )
        #expect(
            runner.contains(
                "schemaAgentGroundingJudgeMode: TextToSQLEvalSchemaAgentGroundingJudge.recordedMode(\n"
                    + "                in: agentConfiguration\n"
                    + "            ),"
            )
        )
        let compatibilityStart = try #require(
            runner.range(of: "var resumeCompatibility: TextToSQLEvalResumeCompatibilityManifest {")
        )
        #expect(
            runner[compatibilityStart.upperBound...].prefix(1_700)
                .contains("schemaAgentGroundingJudgeMode: schemaAgentGroundingJudgeMode,")
        )

        // The generator runs the mode the manifest reports.
        #expect(runner.contains("groundingJudgeMode: options.schemaAgentGroundingJudgeMode,\n                    criticMode:"))
        let baseStart = try #require(runner.range(of: "static func baseConfiguration("))
        let base = String(runner[baseStart.upperBound...].prefix(900))
        #expect(base.contains("groundingJudgeMode: SchemaToolAgentGroundingJudgeMode,"))
        #expect(base.contains("configuration.groundingJudgeMode = groundingJudgeMode"))
        let agentStart = try #require(
            runner.range(of: "private func agentConfiguration() -> SchemaToolSQLAgentConfiguration {")
        )
        #expect(runner[agentStart.upperBound...].prefix(500).contains("groundingJudgeMode: groundingJudgeMode,"))

        let reporter = try Self.source("WidenEval/EvalReporter.swift")
        #expect(reporter.contains("TextToSQLEvalSchemaAgentGroundingJudge.recordedMode(in: agentConfiguration)"))
    }

    @Test func manifestsFromBeforeTheJudgeReadAsOff() throws {
        // A manifest written before the judge has no mode in its agent
        // configuration, and the run it records ran without the judge.
        var beforeJudge = SchemaToolSQLAgentConfiguration.default.reportedSettings
        for key in [
            "groundingJudgeMode",
            "maximumGroundingJudgeHTTPAttempts",
            "groundingJudgeMinimumRemainingSeconds",
        ] {
            #expect(beforeJudge.removeValue(forKey: key) != nil, "\(key)")
        }
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.recordedMode(in: beforeJudge) == nil)
        #expect(TextToSQLEvalSchemaAgentGroundingJudge.recordedMode(in: nil) == nil)

        for previous in [beforeJudge, nil] {
            #expect(
                TextToSQLEvalSchemaAgentGroundingJudge.resumedMode(
                    current: .enabled,
                    isExplicit: false,
                    previousAgentConfiguration: previous
                ) == .disabled
            )
        }

        // Resuming it with the judge off is compatible; turning the judge
        // on is not.
        let previous = Self.compatibility(groundingJudgeMode: nil)
        try TextToSQLEvalResumeCompatibility.validate(
            previous: previous,
            current: Self.compatibility(groundingJudgeMode: "disabled")
        )
        #expect(
            throws: TextToSQLEvalResumeCompatibilityError(
                issues: [
                    TextToSQLEvalResumeCompatibilityIssue(
                        field: "schema agent grounding judge mode",
                        previous: "disabled",
                        current: "enabled"
                    )
                ]
            )
        ) {
            try TextToSQLEvalResumeCompatibility.validate(
                previous: previous,
                current: Self.compatibility(groundingJudgeMode: "enabled")
            )
        }
    }

    @Test func resumeInheritsTheRecordedJudgeModeUnlessTheFlagIsPassed() throws {
        let on = ["groundingJudgeMode": "enabled", "maximumModelTurns": "12"]

        #expect(
            TextToSQLEvalSchemaAgentGroundingJudge.resumedMode(
                current: .disabled,
                isExplicit: false,
                previousAgentConfiguration: on
            ) == .enabled
        )
        // An explicit flag wins; the compatibility check then rejects it.
        #expect(
            TextToSQLEvalSchemaAgentGroundingJudge.resumedMode(
                current: .disabled,
                isExplicit: true,
                previousAgentConfiguration: on
            ) == .disabled
        )
        #expect(
            throws: TextToSQLEvalResumeCompatibilityError.self
        ) {
            try TextToSQLEvalResumeCompatibility.validate(
                previous: Self.compatibility(groundingJudgeMode: "enabled"),
                current: Self.compatibility(groundingJudgeMode: "disabled")
            )
        }
        // A mode this build does not know keeps the current mode.
        #expect(
            TextToSQLEvalSchemaAgentGroundingJudge.resumedMode(
                current: .enabled,
                isExplicit: false,
                previousAgentConfiguration: ["groundingJudgeMode": "future"]
            ) == .enabled
        )

        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let resumeStart = try #require(runner.range(of: "private mutating func applyResumeDefaults("))
        let resume = String(runner[resumeStart.upperBound...].prefix(4_500))
        #expect(
            resume.contains(
                "options.schemaAgentGroundingJudgeMode = TextToSQLEvalSchemaAgentGroundingJudge.resumedMode("
            )
        )
        #expect(resume.contains("current: options.schemaAgentGroundingJudgeMode,"))
        #expect(resume.contains("isExplicit: options.explicitOptions.contains(.schemaAgentGroundingJudgeMode),"))
    }

    @Test func aReleaseFailsTheOffArmOfACaseThatExpectsSQL() {
        let divergence = TextToSQLGroundingJudgeDivergence(
            kind: .released,
            lexicalClarificationQuestion: "Which column should define \"loyal\"?"
        )
        var result = Self.result(status: .passed, sql: "SELECT id FROM public.customers")
            .recordingGroundingJudgeDivergence(divergence, evalCase: Self.evalCase(.sql))

        #expect(result.metrics.groundingJudgeDivergence == "released")
        #expect(result.metrics.groundingJudgeReleaseViolations == [])
        #expect(result.metrics.groundingJudgeOffArmDecisionMatches == false)
        #expect(result.metrics.groundingJudgeOffArmPassed == false)
        #expect(result.metrics.groundingJudgeOffArmEndToEndPassed == nil)

        // A semantic run adds the end-to-end arm; the result's own values
        // are never touched.
        result.metrics.endToEndPassed = true
        let paired = result.withGroundingJudgeOffArm()
        #expect(paired.metrics.groundingJudgeOffArmEndToEndPassed == false)
        #expect(paired.status == .passed)
        #expect(paired.metrics.decisionMatches)
        #expect(paired.metrics.endToEndPassed == true)
        // Completing it twice changes nothing.
        #expect(paired.withGroundingJudgeOffArm() == paired)
    }

    @Test func anExpectedClarificationScoresTheLexicalQuestionInTheOffArm() {
        let good = TextToSQLGroundingJudgeDivergence(
            kind: .released,
            lexicalClarificationQuestion: "Which column should define \"loyal\"?"
        )
        let released = Self.result(status: .wrongDecision, decisionMatches: false, sql: "SELECT id FROM public.customers")
            .recordingGroundingJudgeDivergence(good, evalCase: Self.evalCase(.clarify))
        #expect(released.metrics.groundingJudgeOffArmDecisionMatches == true)
        #expect(released.metrics.groundingJudgeOffArmPassed == true)
        var semantic = released
        semantic.metrics.endToEndPassed = false
        #expect(semantic.withGroundingJudgeOffArm().metrics.groundingJudgeOffArmEndToEndPassed == true)

        // A re-aim that improved the question: the lexical one fails the
        // case's quality check, so the off arm fails where the run passed.
        let poor = TextToSQLGroundingJudgeDivergence(
            kind: .reAimed,
            lexicalClarificationQuestion: "Which column should define \"accounts\"?"
        )
        let reAimed = Self.result(clarification: "Which column should define \"loyal\"?")
            .recordingGroundingJudgeDivergence(poor, evalCase: Self.evalCase(.clarify))
        #expect(reAimed.metrics.groundingJudgeDivergence == "reAimed")
        #expect(reAimed.metrics.groundingJudgeReleaseViolations == nil)
        #expect(reAimed.metrics.groundingJudgeOffArmDecisionMatches == true)
        #expect(reAimed.metrics.groundingJudgeOffArmPassed == false)
        #expect(reAimed.status == .passed)
    }

    @Test func resultsWithoutADivergenceAreTheirOwnOffArm() {
        var result = Self.result(status: .wrongDecision, decisionMatches: false, clarification: "Which one?")
            .recordingGroundingJudgeDivergence(nil, evalCase: Self.evalCase(.sql))
        #expect(result.metrics.groundingJudgeDivergence == nil)
        #expect(result.metrics.groundingJudgeOffArmDecisionMatches == nil)

        result.metrics.endToEndPassed = false
        let paired = result.withGroundingJudgeOffArm()
        #expect(paired.metrics.groundingJudgeOffArmDecisionMatches == false)
        #expect(paired.metrics.groundingJudgeOffArmPassed == false)
        #expect(paired.metrics.groundingJudgeOffArmEndToEndPassed == false)

        let passed = Self.result(status: .passed, sql: "SELECT 1").withGroundingJudgeOffArm()
        #expect(passed.metrics.groundingJudgeOffArmDecisionMatches == true)
        #expect(passed.metrics.groundingJudgeOffArmPassed == true)
        // Outside semantic runs there is no end-to-end arm.
        #expect(passed.metrics.groundingJudgeOffArmEndToEndPassed == nil)
    }

    @Test func caseRunnerRecordsTheDivergenceTheJudgeCaused() async throws {
        let question = "Write a query that lists users"
        let sql = "SELECT id FROM public.users LIMIT 100"
        let schema = Self.usersSchema()
        let expectsSQL = TextToSQLEvalCase(
            id: "probe.write-query",
            schemaFixture: "saas",
            question: question,
            expected: TextToSQLEvalExpectation(decision: .sql, requiredTables: ["public.users"])
        )
        let expectsClarification = TextToSQLEvalCase(
            id: "probe.write-query",
            schemaFixture: "saas",
            question: question,
            expected: TextToSQLEvalExpectation(decision: .clarify, clarificationMustMentionAny: ["write"])
        )
        let judged = FixedGenerator(
            result: Self.generation(sql: sql, metadata: Self.judgedMetadata(sql: sql, question: question, schema: schema))
        )

        let releasedSQL = await TextToSQLEvalCaseRunner.run(
            evalCase: expectsSQL,
            schema: schema,
            generator: judged,
            options: TextToSQLEvalRunOptions(backend: .cloud)
        )
        #expect(releasedSQL.status == .passed)
        #expect(releasedSQL.generatedSQL == sql)
        #expect(releasedSQL.metrics.groundingJudgeDivergence == "released")
        #expect(releasedSQL.metrics.groundingJudgeOffArmDecisionMatches == false)
        #expect(releasedSQL.metrics.groundingJudgeOffArmPassed == false)

        // The same release on a case that expects a clarification fails the
        // run but passes the off arm, whose lexical question names "write".
        let releasedOnClarify = await TextToSQLEvalCaseRunner.run(
            evalCase: expectsClarification,
            schema: schema,
            generator: judged,
            options: TextToSQLEvalRunOptions(backend: .cloud)
        )
        #expect(releasedOnClarify.status == .wrongDecision)
        #expect(releasedOnClarify.metrics.groundingJudgeOffArmDecisionMatches == true)
        #expect(releasedOnClarify.metrics.groundingJudgeOffArmPassed == true)

        // Without a judgment the lexical clarification is both arms.
        let lexical = await TextToSQLEvalCaseRunner.run(
            evalCase: expectsClarification,
            schema: schema,
            generator: FixedGenerator(result: Self.generation(sql: sql, metadata: nil)),
            options: TextToSQLEvalRunOptions(backend: .cloud)
        )
        #expect(lexical.status == .passed)
        #expect(lexical.metrics.groundingJudgeDivergence == nil)
        #expect(lexical.withGroundingJudgeOffArm().metrics.groundingJudgeOffArmPassed == true)

        // A released SQL that fails validation and then its repairs still
        // diverged: with the judge off the run ends on the clarification.
        let unsafeSQL = "SELECT id FROM public.users WHERE pg_sleep(1) IS NOT NULL LIMIT 100"
        let failed = await TextToSQLEvalCaseRunner.run(
            evalCase: expectsClarification,
            schema: schema,
            generator: FixedGenerator(
                result: Self.generation(
                    sql: unsafeSQL,
                    metadata: Self.judgedMetadata(sql: unsafeSQL, question: question, schema: schema)
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud)
        )
        #expect(failed.status != .passed)
        #expect(failed.generatedSQL == nil)
        #expect(failed.metrics.groundingJudgeDivergence == "released")
        #expect(failed.metrics.groundingJudgeOffArmPassed == true)
    }

    @Test func summaryCountsTheJudgeStepAndBothArms() throws {
        let summary = try #require(
            TextToSQLEvalGroundingJudgeSummary(
                results: Self.scriptedResults(),
                expectedDecisions: Self.expectedDecisions
            )
        )

        #expect(summary.eligibleResults == 7)
        #expect(summary.judgeableResults == 7)
        #expect(summary.judgedResults == 5)
        #expect(summary.judgeCalls == 6)
        #expect(summary.failedResults == 1)
        #expect(summary.skipReasonCounts == ["skippedNoFlags": 1, "skippedDeadline": 1])
        #expect(
            summary.labelCounts == [
                "request_wording": 1,
                "query_operation": 2,
                "schema_match": 3,
                "needs_definition": 1,
            ]
        )
        #expect(summary.judgedTerms == 7)
        #expect(summary.verifiedTerms == 6)
        #expect(
            summary.postprocessorOutcomeCounts == [
                "released": 3,
                "reAimed:unreleasableTerm": 1,
                "lexical:mustClarify": 1,
                "lexical:notJudged": 2,
            ]
        )
        // Only the mustClarify backstop overruled a judge that let every
        // word stand; the re-aim had a word that needs a definition.
        #expect(summary.vetoedResults == 1)
        #expect(summary.releasedResults == 3)
        #expect(summary.reAimedResults == 1)
        #expect(
            summary.releaseViolationCounts
                == Dictionary(uniqueKeysWithValues: GroundingJudgeReleaseViolation.allCases.map { ($0.rawValue, 0) })
        )
        #expect(summary.releasesOnExpectedClarification == 1)
        #expect(summary.releasedExpectedSQLResults == 2)
        #expect(summary.releasedExpectedSQLSemanticPassed == 1)
        #expect(summary.endToEnd == TextToSQLEvalPairedCount(onArm: 4, offArm: 3, denominator: 9))
        #expect(summary.clarificationDecisions == TextToSQLEvalPairedCount(onArm: 2, offArm: 2, denominator: 3))
        #expect(summary.decisionMatches == TextToSQLEvalPairedCount(onArm: 5, offArm: 4, denominator: 8))
        #expect(summary.expectedSQLClarified == TextToSQLEvalPairedCount(onArm: 2, offArm: 4, denominator: 6))

        #expect(TextToSQLEvalGroundingJudgeSummary.markdownRows(summary) == [
            "| Grounding judge eligible results | 7 |",
            "| Grounding judge judgeable results | 7 |",
            "| Grounding judge judged results | 5 of 7 (71.4%) |",
            "| Grounding judge calls | 6 |",
            "| Grounding judge failed results | 1 of 6 (16.7%) |",
            "| Grounding judge skips | skippedDeadline 1, skippedNoFlags 1 |",
            "| Grounding judge labels | needs_definition 1, query_operation 2, request_wording 1, schema_match 3 |",
            "| Grounding judge verified terms | 6 of 7 (85.7%) |",
            "| Grounding judge postprocessor outcomes | lexical:mustClarify 1, lexical:notJudged 2, reAimed:unreleasableTerm 1, released 3 |",
            "| Grounding judge vetoed releases | 1 |",
            "| Grounding judge released results | 3 |",
            "| Grounding judge re-aimed results | 1 |",
            "| Grounding judge release rule violations | anchoredWindow 0, digestMismatch 0, literalRejected 0, mustClarify 0, undescribedTables 0, write 0 |",
            "| Grounding judge releases on expected-clarify results | 1 |",
            "| Grounding judge released expected-SQL semantic passes | 1 of 2 (50.0%) |",
            "| Paired end-to-end passes (judge on, off) | on 4, off 3 of 9 |",
            "| Paired clarification decision passes (judge on, off) | on 2, off 2 of 3 |",
            "| Paired decision matches (judge on, off) | on 5, off 4 of 8 |",
            "| Paired expected-SQL clarifications (judge on, off) | on 2, off 4 of 6 |",
        ])
        #expect(
            try JSONDecoder().decode(
                TextToSQLEvalGroundingJudgeSummary.self,
                from: JSONEncoder().encode(summary)
            ) == summary
        )

        // Without semantic results there is no end-to-end pair.
        let staticResults = Self.scriptedResults().map { result in
            var copy = result
            copy.metrics.endToEndPassed = nil
            copy.metrics.groundingJudgeOffArmEndToEndPassed = nil
            return copy
        }
        let staticSummary = try #require(
            TextToSQLEvalGroundingJudgeSummary(results: staticResults, expectedDecisions: Self.expectedDecisions)
        )
        #expect(staticSummary.endToEnd == nil)
        #expect(
            TextToSQLEvalGroundingJudgeSummary.markdownRows(staticSummary).contains(
                "| Paired end-to-end passes (judge on, off) | - |"
            )
        )
    }

    @Test func summaryCountsEveryReleaseThatBreaksARule() throws {
        func released(_ violations: [GroundingJudgeReleaseViolation]) -> TextToSQLEvalResult {
            Self.result(status: .passed, sql: "SELECT id FROM public.customers")
                .recordingGroundingJudgeDivergence(
                    TextToSQLGroundingJudgeDivergence(
                        kind: .released,
                        lexicalClarificationQuestion: "Which column should define \"loyal\"?",
                        releaseViolations: violations
                    ),
                    evalCase: Self.evalCase(.sql)
                )
                .withGroundingJudgeOffArm()
        }
        let results = [released([]), released([.write, .mustClarify]), released([.mustClarify])]
        #expect(results[1].metrics.groundingJudgeReleaseViolations == ["write", "mustClarify"])

        let summary = try #require(
            TextToSQLEvalGroundingJudgeSummary(results: results, expectedDecisions: [Self.caseID: .sql])
        )

        #expect(summary.releasedResults == 3)
        #expect(summary.releaseViolationCounts == [
            "digestMismatch": 0,
            "write": 1,
            "literalRejected": 0,
            "anchoredWindow": 0,
            "undescribedTables": 0,
            "mustClarify": 2,
        ])
        #expect(
            TextToSQLEvalGroundingJudgeSummary.markdownRows(summary).contains(
                "| Grounding judge release rule violations | anchoredWindow 0, digestMismatch 0, literalRejected 0, mustClarify 2, undescribedTables 0, write 1 |"
            )
        )
        #expect(
            try JSONDecoder().decode(TextToSQLEvalResult.self, from: JSONEncoder().encode(results[1])) == results[1]
        )
    }

    @Test func judgeRunRateLeavesOutTheSkipsTheAgentsRulesMake() throws {
        let notJudged = "lexical:notJudged"
        let results = [
            Self.result(judgment: Self.judgment(postprocessorOutcome: "released")),
            Self.result(judgment: Self.judgment(outcome: "failed", postprocessorOutcome: notJudged)),
            Self.result(judgment: Self.judgment(outcome: "skippedDeadline", calls: 0, postprocessorOutcome: notJudged)),
            Self.result(judgment: Self.judgment(outcome: "skippedHTTPBudget", calls: 0, postprocessorOutcome: notJudged)),
        ] + ["skippedLiteralRejected", "skippedWrite", "skippedUndescribedTables", "skippedTooManyTerms"].map {
            Self.result(judgment: Self.judgment(outcome: $0, calls: 0, postprocessorOutcome: notJudged))
        }
        let summary = try #require(
            TextToSQLEvalGroundingJudgeSummary(results: results, expectedDecisions: [Self.caseID: .sql])
        )

        // The judge is never asked about a write, a rejected literal, an
        // undescribed table or too many words, so only the deadline, the
        // HTTP budget and failures count against its run rate.
        #expect(summary.eligibleResults == 8)
        #expect(summary.judgeableResults == 4)
        #expect(summary.judgedResults == 1)
        #expect(summary.failedResults == 1)
        #expect(
            TextToSQLEvalGroundingJudgeSummary.markdownRows(summary).contains(
                "| Grounding judge judged results | 1 of 4 (25.0%) |"
            )
        )
        #expect(
            TextToSQLEvalGroundingJudgeSummary.ruleSkipOutcomes
                == Set(SchemaToolAgentGroundingJudgeOutcome.allCases.map(\.rawValue)).subtracting([
                    "judged", "failed", "skippedDeadline", "skippedHTTPBudget",
                ])
        )
    }

    @Test func runsWithoutTheJudgeHaveNoSummary() {
        let off = [
            Self.result(status: .passed, sql: "SELECT 1"),
            Self.result(status: .passed, sql: "SELECT 1", diagnostics: SchemaToolAgentDiagnostics(terminalAction: "sql")),
        ]
        #expect(TextToSQLEvalGroundingJudgeSummary(results: off, expectedDecisions: [:]) == nil)
        #expect(TextToSQLEvalGroundingJudgeSummary(results: [], expectedDecisions: [:]) == nil)
        #expect(TextToSQLEvalGroundingJudgeSummary.markdownRows(nil).allSatisfy { $0.hasSuffix("| - |") })

        // With the judge on, a run that never got a judgment still pairs
        // its results, whose off arm equals the on arm.
        let onWithoutJudgments = off.map { $0.withGroundingJudgeOffArm() }
        let summary = TextToSQLEvalGroundingJudgeSummary(
            results: onWithoutJudgments,
            expectedDecisions: [Self.caseID: .sql]
        )
        #expect(summary?.eligibleResults == 0)
        #expect(summary?.judgeableResults == 0)
        #expect(summary?.decisionMatches == TextToSQLEvalPairedCount(onArm: 2, offArm: 2, denominator: 2))
    }

    @Test func resultsWrittenBeforeTheJudgeDecodeWithoutIt() throws {
        let line = """
            {"caseID":"commerce.customer-paid-revenue","backend":"cloud","model":"particle-1",\
            "repeatIndex":1,"status":"wrongDecision","metrics":{"backendAvailable":true,\
            "transportSuccess":true,"structuredResponseParsed":true,"decisionMatches":false,\
            "forbiddenBindingViolations":[],"latencyMs":18234,"semanticExecutionAttempted":false,\
            "endToEndPassed":false,"semanticStatus":"notApplicable"},\
            "diagnostics":{"missingTables":[],"missingColumnBindings":[],"missingOperations":[],\
            "safetyErrors":[],"schemaErrors":[]},\
            "clarificationQuestion":"What column, condition, or table defines \\"revenue\\" for this question?",\
            "referencedTables":["public.customers","public.orders"],"referencedColumnBindings":[]}
            """
        let result = try JSONDecoder().decode(TextToSQLEvalResult.self, from: Data(line.utf8))

        #expect(result.metrics.groundingJudgeDivergence == nil)
        #expect(result.metrics.groundingJudgeOffArmDecisionMatches == nil)
        #expect(result.metrics.groundingJudgeOffArmPassed == nil)
        #expect(result.metrics.groundingJudgeOffArmEndToEndPassed == nil)
        #expect(
            TextToSQLEvalGroundingJudgeSummary(
                results: [result],
                expectedDecisions: ["commerce.customer-paid-revenue": .sql]
            ) == nil
        )

        // The off-arm fields round-trip like any other metric.
        let paired = Self.scriptedResults()[2]
        #expect(
            try JSONDecoder().decode(TextToSQLEvalResult.self, from: JSONEncoder().encode(paired)) == paired
        )

        // run.json files written before the summary decode with nil: the
        // field is optional and EvalRunSummary keeps synthesized decoding.
        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let summaryStart = try #require(runner.range(of: "struct EvalRunSummary: Codable {"))
        let summaryEnd = try #require(
            runner.range(of: "struct LatencySummary: Codable {", range: summaryStart.upperBound..<runner.endIndex)
        )
        let summary = String(runner[summaryStart.upperBound..<summaryEnd.lowerBound])
        #expect(summary.contains("    var groundingJudge: TextToSQLEvalGroundingJudgeSummary?\n"))
        #expect(!summary.contains("init(from decoder"))
        #expect(
            runner.contains(
                """
                            groundingJudge: TextToSQLEvalGroundingJudgeSummary(
                                results: results,
                                expectedDecisions: casesByID.mapValues(\\.expected.decision)
                            )
                """
            )
        )
    }

    @Test func evalRunnerCompletesTheOffArmAfterTheSemanticAnnotation() throws {
        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let annotation = try #require(runner.range(of: "result = await semanticPreparation.annotate("))
        let offArm = try #require(
            runner.range(
                of: """
                                if options.usesGroundingJudge {
                                    result = result.withGroundingJudgeOffArm()
                                }

                                results.append(result)
                """
            )
        )
        #expect(annotation.upperBound < offArm.lowerBound)
        #expect(runner.contains("usesCloudSchemaAgent && schemaAgentGroundingJudgeMode == .enabled"))

        let scorer = try Self.source("WidenKit/Evals/TextToSQLEvalScorer.swift")
        #expect(
            scorer.components(
                separatedBy: ".recordingGroundingJudgeDivergence(run.groundingJudgeDivergence, evalCase: evalCase)"
            ).count == 3
        )

        // The derivation is part of the scorer's hashed sources.
        for includesAgent in [false, true] {
            #expect(
                TextToSQLEvalSourceManifest.scorerSourcePaths(includesSchemaToolAgent: includesAgent)
                    .contains("WidenKit/Evals/TextToSQLEvalGroundingJudge.swift")
            )
        }
    }

    @Test func reportersShowTheJudgeModeAndCountsUngated() throws {
        let evalReporter = try Self.source("WidenEval/EvalReporter.swift")
        let modeRow = #""| Schema agent grounding judge | \(tableCell(run.manifest.schemaAgentGroundingJudgeMode ?? "-")) |","#
        #expect(evalReporter.contains(modeRow))
        let summaryStart = try #require(evalReporter.range(of: "private static func summarySection("))
        let summaryEnd = try #require(
            evalReporter.range(
                of: "private static func statusCountSection(",
                range: summaryStart.upperBound..<evalReporter.endIndex
            )
        )
        #expect(
            evalReporter[summaryStart.upperBound..<summaryEnd.lowerBound].contains(
                "lines += TextToSQLEvalGroundingJudgeSummary.markdownRows(summary.groundingJudge)"
            )
        )

        let gateReporter = try Self.source("WidenEval/ReleaseGateReporter.swift")
        // The gate's and the triage's Run tables both name the judge mode.
        #expect(gateReporter.components(separatedBy: modeRow).count == 3)
        let sectionStart = try #require(gateReporter.range(of: "private static func reportedUsageSection("))
        let sectionEnd = try #require(
            gateReporter.range(
                of: "private static func historicalRegressionSection(",
                range: sectionStart.upperBound..<gateReporter.endIndex
            )
        )
        let section = String(gateReporter[sectionStart.upperBound..<sectionEnd.lowerBound])
        #expect(section.contains("\"## Reported (not gated)\","))
        #expect(section.contains("lines += TextToSQLEvalGroundingJudgeSummary.markdownRows(groundingJudge)"))

        // The gate itself never reads the judge's counts; only the committed
        // doc policy before it checks the judge's mode.
        let gate = try Self.source("WidenKit/Evals/TextToSQLReleaseGate.swift")
        let criteriaStart = try #require(gate.range(of: "public struct TextToSQLReleaseGateCount"))
        #expect(!gate[criteriaStart.lowerBound...].contains("groundingJudge"))

        // The triage's Policy column names the judge step and what the
        // postprocessor did with it.
        let policyStart = try #require(gateReporter.range(of: "private static func policySummary("))
        let policy = String(gateReporter[policyStart.upperBound...].prefix(3_000))
        #expect(policy.contains("|| diagnostics.groundingJudgment != nil"))
        #expect(policy.contains("if let judgment = diagnostics.groundingJudgment {"))
        #expect(
            policy.contains(
                "\"judge: \" + ([judgment.outcome] + [judgment.postprocessorOutcome].compactMap { $0 })"
            )
        )
    }

    // MARK: - Fixtures

    private static let caseID = "probe.case"

    private static let expectedDecisions: [String: TextToSQLEvalDecision] = [
        "sql.released-pass": .sql,
        "sql.released-mismatch": .sql,
        "clarify.released": .clarify,
        "clarify.reaimed": .clarify,
        "clarify.vetoed": .clarify,
        "sql.judge-failed": .sql,
        "sql.no-flags": .sql,
        "sql.deadline": .sql,
        "sql.timeout": .sql,
    ]

    /// One result per path through the judge, completed as a judge-on run
    /// completes them.
    private static func scriptedResults() -> [TextToSQLEvalResult] {
        let sql = "SELECT id FROM public.customers"
        func lexical(_ term: String) -> String {
            "Which column should define \"\(term)\"?"
        }
        let results: [(TextToSQLEvalResult, TextToSQLGroundingJudgeDivergence?, TextToSQLEvalCase)] = [
            // Released, and the SQL matched the golden result.
            (
                result(
                    "sql.released-pass",
                    status: .passed,
                    sql: sql,
                    endToEnd: true,
                    semanticStatus: .passed,
                    judgment: judgment(
                        terms: [term("write", "request_wording"), term("query", "query_operation")],
                        postprocessorOutcome: "released"
                    )
                ),
                TextToSQLGroundingJudgeDivergence(kind: .released, lexicalClarificationQuestion: lexical("write")),
                evalCase(.sql)
            ),
            // Released, and the SQL did not match.
            (
                result(
                    "sql.released-mismatch",
                    status: .passed,
                    sql: sql,
                    endToEnd: false,
                    semanticStatus: .resultMismatch,
                    judgment: judgment(terms: [term("revenue", "schema_match")], postprocessorOutcome: "released")
                ),
                TextToSQLGroundingJudgeDivergence(kind: .released, lexicalClarificationQuestion: lexical("revenue")),
                evalCase(.sql)
            ),
            // Released on a case that expects a clarification.
            (
                result(
                    "clarify.released",
                    status: .wrongDecision,
                    decisionMatches: false,
                    sql: sql,
                    endToEnd: false,
                    judgment: judgment(terms: [term("loyal", "schema_match")], postprocessorOutcome: "released")
                ),
                TextToSQLGroundingJudgeDivergence(kind: .released, lexicalClarificationQuestion: lexical("loyal")),
                evalCase(.clarify, mentioning: "loyal")
            ),
            // Re-aimed from "accounts" to "healthy".
            (
                result(
                    "clarify.reaimed",
                    clarification: lexical("healthy"),
                    endToEnd: true,
                    judgment: judgment(
                        terms: [
                            term("healthy", "needs_definition", verified: false),
                            term("accounts", "schema_match"),
                        ],
                        postprocessorOutcome: "reAimed:unreleasableTerm"
                    )
                ),
                TextToSQLGroundingJudgeDivergence(kind: .reAimed, lexicalClarificationQuestion: lexical("accounts")),
                evalCase(.clarify, mentioning: "healthy")
            ),
            // Every word verified, but intent coverage vetoed the release.
            (
                result(
                    "clarify.vetoed",
                    clarification: lexical("best"),
                    endToEnd: true,
                    judgment: judgment(
                        terms: [term("best", "query_operation")],
                        postprocessorOutcome: "lexical:mustClarify"
                    )
                ),
                nil,
                evalCase(.clarify, mentioning: "best")
            ),
            // The judge request failed, so the lexical question stood.
            (
                result(
                    "sql.judge-failed",
                    status: .wrongDecision,
                    decisionMatches: false,
                    clarification: lexical("write"),
                    endToEnd: false,
                    judgment: judgment(outcome: "failed", postprocessorOutcome: "lexical:notJudged")
                ),
                nil,
                evalCase(.sql)
            ),
            // Nothing flagged: the SQL stood without a request.
            (
                result(
                    "sql.no-flags",
                    status: .passed,
                    sql: sql,
                    endToEnd: true,
                    judgment: judgment(outcome: "skippedNoFlags", calls: 0)
                ),
                nil,
                evalCase(.sql)
            ),
            // Too close to the deadline to ask.
            (
                result(
                    "sql.deadline",
                    status: .wrongDecision,
                    decisionMatches: false,
                    clarification: lexical("write"),
                    endToEnd: false,
                    judgment: judgment(
                        outcome: "skippedDeadline",
                        calls: 0,
                        postprocessorOutcome: "lexical:notJudged"
                    )
                ),
                nil,
                evalCase(.sql)
            ),
            // The eval timed out before the agent answered.
            (
                result("sql.timeout", status: .evalTimeout, decisionMatches: false, parsed: false, endToEnd: false),
                nil,
                evalCase(.sql)
            ),
        ]
        return results.map { result, divergence, evalCase in
            result.recordingGroundingJudgeDivergence(divergence, evalCase: evalCase).withGroundingJudgeOffArm()
        }
    }

    private static func result(
        _ caseID: String = caseID,
        status: TextToSQLEvalCaseStatus = .passed,
        decisionMatches: Bool = true,
        parsed: Bool = true,
        sql: String? = nil,
        clarification: String? = nil,
        endToEnd: Bool? = nil,
        semanticStatus: TextToSQLSemanticStatus? = nil,
        judgment: SchemaToolAgentGroundingJudgment? = nil,
        diagnostics: SchemaToolAgentDiagnostics? = nil
    ) -> TextToSQLEvalResult {
        var agentDiagnostics = diagnostics
        if let judgment {
            agentDiagnostics = SchemaToolAgentDiagnostics(
                terminalToolSeen: true,
                terminalAction: "sql",
                groundingJudgeMode: SchemaToolAgentGroundingJudgeMode.enabled.rawValue,
                groundingJudgment: judgment
            )
        }
        return TextToSQLEvalResult(
            caseID: caseID,
            backend: .cloud,
            model: "particle-1",
            repeatIndex: 1,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: parsed,
                structuredResponseParsed: parsed,
                decisionMatches: decisionMatches,
                latencyMs: 1,
                openRouterAgentDiagnostics: agentDiagnostics,
                endToEndPassed: endToEnd,
                semanticStatus: semanticStatus
            ),
            generatedSQL: sql,
            clarificationQuestion: clarification
        )
    }

    private static func judgment(
        outcome: String = "judged",
        calls: Int = 1,
        terms: [SchemaToolAgentGroundingJudgedTerm] = [],
        postprocessorOutcome: String? = nil
    ) -> SchemaToolAgentGroundingJudgment {
        SchemaToolAgentGroundingJudgment(
            outcome: outcome,
            inputDigest: "digest",
            terms: terms,
            callCount: calls,
            postprocessorOutcome: postprocessorOutcome
        )
    }

    private static func term(
        _ term: String,
        _ label: String,
        verified: Bool = true
    ) -> SchemaToolAgentGroundingJudgedTerm {
        SchemaToolAgentGroundingJudgedTerm(term: term, label: label, verified: verified, evidence: "")
    }

    private static func evalCase(
        _ decision: TextToSQLEvalDecision,
        mentioning concept: String = "loyal"
    ) -> TextToSQLEvalCase {
        TextToSQLEvalCase(
            id: caseID,
            schemaFixture: "commerce",
            question: "Show loyal customers",
            expected: TextToSQLEvalExpectation(
                decision: decision,
                clarificationMustMentionAny: decision == .clarify ? [concept] : []
            )
        )
    }

    private struct FixedGenerator: SQLGenerator {
        var result: SQLGenerationResult

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            result
        }
    }

    private static func generation(sql: String, metadata: CloudGenerationMetadata?) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: sql,
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            backendMetadata: metadata
        )
    }

    /// Schema-tool metadata whose judgment lets every flagged word stand,
    /// bound to this SQL and question.
    private static func judgedMetadata(
        sql: String,
        question: String,
        schema: DatabaseSchema
    ) -> CloudGenerationMetadata {
        let flagged = GeneratedSQLPostprocessor.groundingReview(
            sql: sql,
            question: question,
            schema: schema,
            databaseContext: "",
            confirmedSemanticBindings: []
        )?.unresolvedTerms ?? []
        var metadata = CloudGenerationMetadata(
            requestedModelID: "particle-1",
            structuredOutputMode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        metadata.agentSelectionReason = "tools"
        metadata.agentTerminalOutcome = "sql"
        metadata.agentDiagnostics = SchemaToolAgentDiagnostics(
            terminalToolSeen: true,
            terminalAction: "sql",
            schemaEvidence: SchemaToolEvidenceSummary(
                searched: true,
                describedTableIDs: ["public.users"],
                exposedColumnIDs: ["public.users.id"]
            ),
            intentCoverageMode: SchemaToolAgentIntentCoverageMode.diagnosticsOnly.rawValue,
            groundingJudgeMode: SchemaToolAgentGroundingJudgeMode.enabled.rawValue,
            groundingJudgment: SchemaToolAgentGroundingJudgment(
                outcome: SchemaToolAgentGroundingJudgeOutcome.judged.rawValue,
                inputDigest: SchemaToolAgentGroundingJudgment.inputDigest(
                    sql: sql,
                    question: question,
                    databaseContext: "",
                    confirmedSemanticBindings: [],
                    terms: flagged
                ),
                terms: flagged.map { term($0, "request_wording") },
                callCount: 1
            )
        )
        return metadata
    }

    private static func usersSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private static func compatibility(groundingJudgeMode: String?) -> TextToSQLEvalResumeCompatibilityManifest {
        TextToSQLEvalResumeCompatibilityManifest(
            suiteName: "text-to-sql",
            suiteVersion: "1",
            suiteFileHash: "suite",
            schemaFixtureHashes: [:],
            provider: "particle",
            model: "particle-1",
            backendMode: "cloud",
            cloudAgentMode: "tools",
            schemaAgentGroundingJudgeMode: groundingJudgeMode,
            semanticDatabaseEnabled: true,
            scorerSourceHash: "scorer",
            semanticComparatorSourceHash: nil,
            setupFixtureHashes: nil,
            releaseGateVersion: nil
        )
    }

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
