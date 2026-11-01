import Foundation
import Testing

@testable import WidenKit

/// The eval's critic flag, and the critic and forced-terminal counts behind
/// the extra-calls layer's criterion K12.
@Suite("Text-to-SQL eval extra-calls metrics")
struct TextToSQLEvalExtraCallsMetricsTests {
    @Test func criticFlagAcceptsOnOffAndTheModeNames() {
        #expect(TextToSQLEvalSchemaAgentCritic.mode(flagValue: "on") == .enabled)
        #expect(TextToSQLEvalSchemaAgentCritic.mode(flagValue: "enabled") == .enabled)
        #expect(TextToSQLEvalSchemaAgentCritic.mode(flagValue: "off") == .disabled)
        #expect(TextToSQLEvalSchemaAgentCritic.mode(flagValue: "disabled") == .disabled)
        for value in ["ON", "true", "yes", "diagnostics", ""] {
            #expect(TextToSQLEvalSchemaAgentCritic.mode(flagValue: value) == nil, "\(value)")
        }
    }

    @Test func widenEvalParsesTheCriticFlagAndRunsTheCriticByDefault() throws {
        let main = try Self.source("WidenEval/WidenEvalMain.swift")

        // On by default, as in the app.
        #expect(main.contains("var schemaAgentCriticMode: SchemaToolAgentCriticMode = .enabled"))
        #expect(SchemaToolSQLAgentConfiguration.default.criticMode == .enabled)
        #expect(main.contains("--schema-agent-critic on|off|enabled|disabled (default: on)"))

        let flagStart = try #require(main.range(of: #"case "--schema-agent-critic":"#))
        let flagCase = String(main[flagStart.upperBound...].prefix(500))
        #expect(
            flagCase.contains(
                "guard let mode = TextToSQLEvalSchemaAgentCritic.mode(flagValue: value) else {"
            )
        )
        #expect(flagCase.contains("throw EvalCLIError.invalidValue(argument, value)"))
        #expect(flagCase.contains("options.schemaAgentCriticMode = mode"))
        #expect(flagCase.contains("options.explicitOptions.insert(.schemaAgentCriticMode)"))
        #expect(main.contains("    case schemaAgentCriticMode\n"))
    }

    @Test func evalRunnerRecordsTheCriticModeInTheAgentConfiguration() throws {
        let runner = try Self.source("WidenEval/EvalRunner.swift")

        // One agent configuration feeds the manifest and the resume check.
        #expect(runner.contains("criticMode: options.schemaAgentCriticMode\n            ).reportedSettings"))
        #expect(runner.contains("                agentConfiguration: agentConfiguration,\n"))
        #expect(
            runner.contains(
                "schemaAgentCriticMode: TextToSQLEvalSchemaAgentCritic.recordedMode(in: agentConfiguration),"
            )
        )
        let compatibilityStart = try #require(
            runner.range(of: "var resumeCompatibility: TextToSQLEvalResumeCompatibilityManifest {")
        )
        #expect(
            runner[compatibilityStart.upperBound...].prefix(1_600)
                .contains("schemaAgentCriticMode: schemaAgentCriticMode,")
        )

        // The generator runs the mode the manifest reports.
        #expect(runner.contains("criticMode: options.schemaAgentCriticMode\n                )"))
        let baseStart = try #require(runner.range(of: "static func baseConfiguration("))
        let base = String(runner[baseStart.upperBound...].prefix(800))
        #expect(base.contains("criticMode: SchemaToolAgentCriticMode"))
        #expect(base.contains("configuration.criticMode = criticMode"))
        let agentStart = try #require(
            runner.range(of: "private func agentConfiguration() -> SchemaToolSQLAgentConfiguration {")
        )
        #expect(runner[agentStart.upperBound...].prefix(500).contains("criticMode: criticMode"))

        let reporter = try Self.source("WidenEval/EvalReporter.swift")
        #expect(reporter.contains("TextToSQLEvalSchemaAgentCritic.recordedMode(in: agentConfiguration)"))
    }

    @Test func manifestsFromBeforeTheCriticRecordNoMode() {
        // A Stage 2 manifest has an agent configuration without the critic.
        var beforeCritic = SchemaToolSQLAgentConfiguration.default.reportedSettings
        for key in [
            "criticMode",
            "maximumCriticRevisions",
            "maximumCriticHTTPAttempts",
            "criticMinimumRemainingSeconds",
            "criticRevisionMinimumRemainingSeconds",
        ] {
            beforeCritic.removeValue(forKey: key)
        }
        #expect(TextToSQLEvalSchemaAgentCritic.recordedMode(in: beforeCritic) == nil)
        #expect(TextToSQLEvalSchemaAgentCritic.recordedMode(in: nil) == nil)
        #expect(
            TextToSQLEvalSchemaAgentCritic.recordedMode(
                in: SchemaToolSQLAgentConfiguration.default.reportedSettings
            ) == "enabled"
        )
    }

    @Test func resumeInheritsTheRecordedCriticModeUnlessTheFlagIsPassed() throws {
        let off = ["criticMode": "disabled", "maximumModelTurns": "12"]

        #expect(
            TextToSQLEvalSchemaAgentCritic.resumedMode(
                current: .enabled,
                isExplicit: false,
                previousAgentConfiguration: off
            ) == .disabled
        )
        // An explicit flag wins; the compatibility check then rejects it.
        #expect(
            TextToSQLEvalSchemaAgentCritic.resumedMode(
                current: .enabled,
                isExplicit: true,
                previousAgentConfiguration: off
            ) == .enabled
        )
        // Nothing recorded, or a mode this build does not know, keeps the
        // current mode.
        let unrecorded: [[String: String]?] = [
            nil,
            ["maximumModelTurns": "12"],
            ["criticMode": "future"],
        ]
        for previous in unrecorded {
            #expect(
                TextToSQLEvalSchemaAgentCritic.resumedMode(
                    current: .enabled,
                    isExplicit: false,
                    previousAgentConfiguration: previous
                ) == .enabled
            )
        }

        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let resumeStart = try #require(runner.range(of: "private mutating func applyResumeDefaults("))
        let resume = String(runner[resumeStart.upperBound...].prefix(4_000))
        #expect(resume.contains("options.schemaAgentCriticMode = TextToSQLEvalSchemaAgentCritic.resumedMode("))
        #expect(resume.contains("current: options.schemaAgentCriticMode,"))
        #expect(resume.contains("isExplicit: options.explicitOptions.contains(.schemaAgentCriticMode),"))
        #expect(resume.contains("previousAgentConfiguration: previousRun.manifest.agentConfiguration"))
    }

    @Test func criticSummaryCountsEligibleReviewedAndFailedOpenResults() throws {
        let summary = try #require(TextToSQLEvalCriticSummary(results: Self.scriptedResults()))

        // Repair-mode SQL, forced final answers and answers that never
        // reached the critic step are not eligible; reviews skipped for
        // time or budget are eligible but not reviewed.
        #expect(summary.eligibleSQLTerminals == 5)
        #expect(summary.reviewedResults == 4)
        #expect(summary.criticCalls == 5)
        #expect(summary.verdictCounts == ["accept": 2, "revise": 2, "error": 1])
        #expect(
            summary.finalOutcomeCounts == [
                "accepted": 1,
                "revisedAccepted": 1,
                "failedOpen": 1,
                "skippedDeadline": 1,
                "skippedForcedTerminal": 1,
                "skippedRepairMode": 1,
                "revisionTurnedClarifyReleasedPrevious": 1,
            ]
        )
        #expect(summary.revisedResults == 2)
        #expect(summary.revisions == 2)
        #expect(summary.failedOpenCalls == 1)
        #expect(summary.releasedPreviousResults == 1)
        #expect(TextToSQLEvalCriticSummary.markdownRows(summary) == [
            "| Critic eligible SQL terminals | 5 |",
            "| Critic reviewed results | 4 of 5 (80.0%) |",
            "| Critic calls | 5 |",
            "| Critic failed-open calls | 1 of 5 (20.0%) |",
            "| Critic verdicts | accept 2, error 1, revise 2 |",
            "| Critic final outcomes | accepted 1, failedOpen 1, revisedAccepted 1, revisionTurnedClarifyReleasedPrevious 1, skippedDeadline 1, skippedForcedTerminal 1, skippedRepairMode 1 |",
            "| Critic revised results | 2 |",
            "| Critic revisions | 2 |",
            "| Critic releases of pre-revision SQL | 1 |",
        ])
    }

    @Test func forcedFinalAnswersAreNotEligibleForReview() throws {
        // The critic skips a forced final answer by design, so forced
        // answers leave the reviewed share of eligible SQL unchanged.
        let summary = try #require(
            TextToSQLEvalCriticSummary(results: [
                Self.result(Self.critic(calls: 1, verdicts: ["accept"], outcome: "accepted")),
                Self.result(Self.critic(outcome: "skippedDeadline")),
                Self.result(
                    Self.critic(
                        outcome: "skippedForcedTerminal",
                        forcedReason: "timeReserve",
                        forcedRequests: 1,
                        forcedSucceeded: true
                    )
                ),
                // An answer forced after a revision was never reviewed
                // either, though the SQL before it was.
                Self.result(
                    Self.critic(
                        calls: 1,
                        verdicts: ["revise"],
                        revisions: 1,
                        outcome: "skippedForcedTerminal",
                        forcedReason: "toolBudget",
                        forcedRequests: 1,
                        forcedSucceeded: true
                    )
                ),
            ])
        )

        #expect(summary.eligibleSQLTerminals == 2)
        #expect(summary.reviewedResults == 1)
        #expect(summary.criticCalls == 2)
        #expect(summary.revisedResults == 1)
        #expect(
            TextToSQLEvalCriticSummary.ineligibleOutcomes == ["skippedRepairMode", "skippedForcedTerminal"]
        )
        #expect(
            TextToSQLEvalCriticSummary.markdownRows(summary).prefix(2) == [
                "| Critic eligible SQL terminals | 2 |",
                "| Critic reviewed results | 1 of 2 (50.0%) |",
            ]
        )
    }

    @Test func forcedTerminalSummaryCountsAttemptsReasonsAndProviderRejections() throws {
        let summary = try #require(TextToSQLEvalForcedTerminalSummary(results: Self.scriptedResults()))

        #expect(summary.attempted == 4)
        #expect(summary.succeeded == 1)
        // A run that forced its answer but ran out of time before sending
        // the request still counts its reason.
        #expect(
            summary.reasonCounts == [
                "toolBudget": 2,
                "turnBudget": 1,
                "timeReserve": 1,
                "terminalRequired": 1,
            ]
        )
        // The run that ran out of time before its forced request.
        #expect(summary.timedOut == 1)
        #expect(TextToSQLEvalForcedTerminalSummary.timedOutFailure == "wallClockTimeout")
        // Only invalid-request and unsupported-feature failures are the
        // provider refusing the forced request; a rate limit is not.
        #expect(summary.providerRejected == 2)
        #expect(
            TextToSQLEvalForcedTerminalSummary.providerRejectionFailures == [
                "cloudRequestFailure:invalidRequest",
                "cloudRequestFailure:unsupportedFeature",
            ]
        )
        #expect(TextToSQLEvalForcedTerminalSummary.markdownRows(summary) == [
            "| Forced final answers attempted | 4 |",
            "| Forced final answers succeeded | 1 of 4 (25.0%) |",
            "| Forced final answer reasons | terminalRequired 1, timeReserve 1, toolBudget 2, turnBudget 1 |",
            "| Forced final answers timed out | 1 |",
            "| Forced requests rejected by the provider | 2 |",
        ])
    }

    @Test func runsWithoutTheCriticOrTheAgentReportDashes() throws {
        // A legacy run, or results from before the layer, has no diagnostics.
        let withoutAgent = [Self.result(nil), Self.result(nil)]
        #expect(TextToSQLEvalCriticSummary(results: withoutAgent) == nil)
        #expect(TextToSQLEvalForcedTerminalSummary(results: withoutAgent) == nil)
        #expect(TextToSQLEvalCriticSummary.markdownRows(nil).allSatisfy { $0.hasSuffix("| - |") })
        #expect(TextToSQLEvalForcedTerminalSummary.markdownRows(nil).allSatisfy { $0.hasSuffix("| - |") })

        // With the critic off the agent records no critic mode, but its
        // forced-terminal counts are still reported, as zeros.
        let criticOff = [Self.result(SchemaToolAgentDiagnostics(terminalAction: "sql"))]
        #expect(TextToSQLEvalCriticSummary(results: criticOff) == nil)
        let forced = try #require(TextToSQLEvalForcedTerminalSummary(results: criticOff))
        #expect(forced == TextToSQLEvalForcedTerminalSummary(
            attempted: 0,
            succeeded: 0,
            reasonCounts: [:],
            timedOut: 0,
            providerRejected: 0
        ))
        #expect(TextToSQLEvalForcedTerminalSummary.markdownRows(forced) == [
            "| Forced final answers attempted | 0 |",
            "| Forced final answers succeeded | 0 of 0 |",
            "| Forced final answer reasons | - |",
            "| Forced final answers timed out | 0 |",
            "| Forced requests rejected by the provider | 0 |",
        ])
    }

    @Test func internalAgentTimeoutsCountForcedRequestsThatRanIntoTheWallClock() throws {
        var plainTimeout = SchemaToolAgentDiagnostics(terminalAction: "sql")
        plainTimeout.appSideRejectionReason = .timedOut
        // A forced request that timed out leaves the failure that forced
        // it, here the tool budget's fallback clarification.
        var forcedTimeout = Self.critic(
            forcedReason: "toolBudget",
            forcedRequests: 1,
            forcedSucceeded: false,
            forcedFailure: "wallClockTimeout"
        )
        forcedTimeout.appSideRejectionReason = .clarificationRejected
        // A time-reserve run that timed out records both, and counts once.
        var reserveTimeout = Self.critic(
            forcedReason: "timeReserve",
            forcedRequests: 1,
            forcedSucceeded: false,
            forcedFailure: "wallClockTimeout"
        )
        reserveTimeout.appSideRejectionReason = .timedOut
        var budget = SchemaToolAgentDiagnostics(terminalAction: "sql")
        budget.appSideRejectionReason = .budgetExhausted

        let results = [
            Self.result(plainTimeout),
            Self.result(forcedTimeout),
            Self.result(reserveTimeout),
            Self.result(budget),
            Self.result(nil),
        ] + Self.scriptedResults()

        // The scripted results add the run that timed out before its
        // forced request; their provider failures are not timeouts.
        #expect(TextToSQLEvalInternalAgentTimeouts.count(results) == 4)
        #expect(TextToSQLEvalInternalAgentTimeouts.count(Self.scriptedResults()) == 1)
        #expect(TextToSQLEvalInternalAgentTimeouts.count([Self.result(budget), Self.result(nil)]) == 0)

        // The gate's and the triage's Run tables both use this count.
        let gateReporter = try Self.source("WidenEval/ReleaseGateReporter.swift")
        let countStart = try #require(
            gateReporter.range(of: "static func internalSchemaAgentTimeoutCount(_ results: [TextToSQLEvalResult]) -> Int {")
        )
        #expect(
            gateReporter[countStart.upperBound...].prefix(120)
                .contains("TextToSQLEvalInternalAgentTimeouts.count(results)")
        )
        #expect(gateReporter.components(separatedBy: "| Internal schema-agent timeouts | \\(").count == 3)
    }

    @Test func summariesRoundTripAndOldRunFilesStillDecode() throws {
        let results = Self.scriptedResults()
        let critic = try #require(TextToSQLEvalCriticSummary(results: results))
        let forced = try #require(TextToSQLEvalForcedTerminalSummary(results: results))
        #expect(
            try JSONDecoder().decode(
                TextToSQLEvalCriticSummary.self,
                from: JSONEncoder().encode(critic)
            ) == critic
        )
        #expect(
            try JSONDecoder().decode(
                TextToSQLEvalForcedTerminalSummary.self,
                from: JSONEncoder().encode(forced)
            ) == forced
        )

        // run.json files written before these summaries decode with nil: the
        // fields are optional and EvalRunSummary keeps synthesized decoding.
        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let summaryStart = try #require(runner.range(of: "struct EvalRunSummary: Codable {"))
        let summaryEnd = try #require(
            runner.range(of: "struct LatencySummary: Codable {", range: summaryStart.upperBound..<runner.endIndex)
        )
        let summary = String(runner[summaryStart.upperBound..<summaryEnd.lowerBound])
        #expect(summary.contains("    var schemaAgentCritic: TextToSQLEvalCriticSummary?\n"))
        #expect(summary.contains("    var forcedTerminal: TextToSQLEvalForcedTerminalSummary?\n"))
        #expect(!summary.contains("init(from decoder"))
        #expect(runner.contains("schemaAgentCritic: TextToSQLEvalCriticSummary(results: results),"))
        #expect(runner.contains("forcedTerminal: TextToSQLEvalForcedTerminalSummary(results: results)"))
    }

    @Test func summariesReadTheValuesTheAgentRecords() throws {
        let agent = try Self.source("WidenKit/Services/SchemaToolSQLAgent.swift")

        #expect(agent.contains("\"\(TextToSQLEvalCriticSummary.repairModeOutcome)\""))
        #expect(agent.contains("\"\(TextToSQLEvalCriticSummary.forcedTerminalOutcome)\""))
        #expect(agent.contains("criticVerdicts.append(\"\(TextToSQLEvalCriticSummary.failedOpenVerdict)\")"))
        for outcome in [
            "revisionFailedReleasedPrevious",
            "revisionTurnedClarifyReleasedPrevious",
            "revisionChangedKindReleasedPrevious",
        ] {
            #expect(agent.contains("outcome: \"\(outcome)\""), "\(outcome)")
            #expect(outcome.hasSuffix(TextToSQLEvalCriticSummary.releasedPreviousOutcomeSuffix))
        }
        #expect(agent.contains(#"return "cloudRequestFailure:\(cloudFailure.category.rawValue)""#))
    }

    @Test func reportersShowTheCriticModeAndTheExtraCallCounts() throws {
        let evalReporter = try Self.source("WidenEval/EvalReporter.swift")
        let criticRow = #""| Schema agent critic | \(tableCell(run.manifest.schemaAgentCriticMode ?? "-")) |","#
        #expect(evalReporter.contains(criticRow))
        let summaryStart = try #require(evalReporter.range(of: "private static func summarySection("))
        let summaryEnd = try #require(
            evalReporter.range(
                of: "private static func statusCountSection(",
                range: summaryStart.upperBound..<evalReporter.endIndex
            )
        )
        let summarySection = String(evalReporter[summaryStart.upperBound..<summaryEnd.lowerBound])
        #expect(
            summarySection.contains(
                "lines += TextToSQLEvalForcedTerminalSummary.markdownRows(summary.forcedTerminal)"
            )
        )
        #expect(
            summarySection.contains(
                "lines += TextToSQLEvalCriticSummary.markdownRows(summary.schemaAgentCritic)"
            )
        )

        let gateReporter = try Self.source("WidenEval/ReleaseGateReporter.swift")
        // The gate's and the triage's Run tables both name the critic mode.
        #expect(gateReporter.components(separatedBy: criticRow).count == 3)
        let sectionStart = try #require(gateReporter.range(of: "private static func reportedUsageSection("))
        let sectionEnd = try #require(
            gateReporter.range(
                of: "private static func historicalRegressionSection(",
                range: sectionStart.upperBound..<gateReporter.endIndex
            )
        )
        let section = String(gateReporter[sectionStart.upperBound..<sectionEnd.lowerBound])
        #expect(section.contains("\"## Reported (not gated)\","))
        #expect(section.contains("TextToSQLEvalForcedTerminalSummary(results: results)"))
        #expect(
            section.contains(
                "TextToSQLEvalCriticSummary.markdownRows(TextToSQLEvalCriticSummary(results: results))"
            )
        )
    }

    /// One result per path through the critic and the forced final answer.
    private static func scriptedResults() -> [TextToSQLEvalResult] {
        [
            // Reviewed and accepted.
            result(critic(calls: 1, verdicts: ["accept"], outcome: "accepted")),
            // Revised once, then accepted.
            result(
                critic(calls: 2, verdicts: ["revise", "accept"], revisions: 1, outcome: "revisedAccepted")
            ),
            // The review failed, so the SQL stood.
            result(critic(calls: 1, verdicts: ["error"], outcome: "failedOpen")),
            // Too close to the deadline to review.
            result(critic(outcome: "skippedDeadline")),
            // Repair SQL is never reviewed, so it is not eligible.
            result(critic(outcome: "skippedRepairMode")),
            // A clarification never reaches the critic step.
            result(critic()),
            // A forced final answer that succeeded skips the critic, so it is
            // not eligible.
            result(
                critic(
                    outcome: "skippedForcedTerminal",
                    forcedReason: "toolBudget",
                    forcedRequests: 1,
                    forcedSucceeded: true
                )
            ),
            // The provider rejected the forced request's shape.
            result(
                critic(
                    forcedReason: "turnBudget",
                    forcedRequests: 1,
                    forcedSucceeded: false,
                    forcedFailure: "cloudRequestFailure:invalidRequest"
                )
            ),
            // A rate limit is not a rejection.
            result(
                critic(
                    forcedReason: "timeReserve",
                    forcedRequests: 1,
                    forcedSucceeded: false,
                    forcedFailure: "cloudRequestFailure:rateLimited"
                )
            ),
            // Out of time before the forced request could be sent.
            result(
                critic(
                    forcedReason: "terminalRequired",
                    forcedSucceeded: false,
                    forcedFailure: "wallClockTimeout"
                )
            ),
            // A revision turned into a clarification, so the earlier SQL was
            // released.
            result(
                critic(
                    calls: 1,
                    verdicts: ["revise"],
                    revisions: 1,
                    outcome: "revisionTurnedClarifyReleasedPrevious"
                )
            ),
            // A skipped slot has no diagnostics and changes no count.
            result(nil),
            result(
                critic(
                    forcedReason: "toolBudget",
                    forcedRequests: 2,
                    forcedSucceeded: false,
                    forcedFailure: "cloudRequestFailure:unsupportedFeature"
                )
            ),
        ]
    }

    private static func critic(
        calls: Int? = nil,
        verdicts: [String]? = nil,
        revisions: Int? = nil,
        outcome: String? = nil,
        forcedReason: String? = nil,
        forcedRequests: Int? = nil,
        forcedSucceeded: Bool? = nil,
        forcedFailure: String? = nil
    ) -> SchemaToolAgentDiagnostics {
        SchemaToolAgentDiagnostics(
            forcedTerminalReason: forcedReason,
            forcedTerminalRequestCount: forcedRequests,
            forcedTerminalSucceeded: forcedSucceeded,
            forcedTerminalFailure: forcedFailure,
            criticMode: SchemaToolAgentCriticMode.enabled.rawValue,
            criticCallCount: calls,
            criticVerdicts: verdicts,
            criticRevisionCount: revisions,
            criticFinalOutcome: outcome
        )
    }

    private static func result(_ diagnostics: SchemaToolAgentDiagnostics?) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: "case.\(UUID().uuidString)",
            backend: .cloud,
            model: "particle-1",
            repeatIndex: 1,
            status: diagnostics == nil ? .skippedBudgetLimit : .passed,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: diagnostics != nil,
                structuredResponseParsed: diagnostics != nil,
                decisionMatches: diagnostics != nil,
                latencyMs: 1,
                openRouterAgentDiagnostics: diagnostics
            )
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
