import Foundation

/// The eval's `--schema-agent-grounding-judge` flag, and the judge mode a run
/// manifest records. The mode lives in the manifest's agent configuration,
/// under the key `SchemaToolSQLAgentConfiguration.reportedSettings` uses.
public enum TextToSQLEvalSchemaAgentGroundingJudge {
    /// The agent configuration key that records the judge mode.
    public static let reportedSettingsKey = "groundingJudgeMode"

    /// The mode for a `--schema-agent-grounding-judge` value: `on` or
    /// `enabled`, and `off` or `disabled`. Nil for any other value.
    public static func mode(flagValue: String) -> SchemaToolAgentGroundingJudgeMode? {
        switch flagValue {
        case "on", "enabled":
            .enabled
        case "off", "disabled":
            .disabled
        default:
            nil
        }
    }

    /// The judge mode a run manifest's agent configuration records. Nil for a
    /// run without the schema agent, and for one recorded before the judge
    /// existed, which ran without it.
    public static func recordedMode(in agentConfiguration: [String: String]?) -> String? {
        agentConfiguration?[reportedSettingsKey]
    }

    /// The judge mode a resumed run uses: the flag when it was passed,
    /// otherwise the mode the previous run recorded. A run that recorded no
    /// mode ran without the judge, so it resumes with the judge off whatever
    /// the current default is. A recorded mode this build does not know keeps
    /// `current`. The resume compatibility check then rejects a mode that
    /// changed.
    public static func resumedMode(
        current: SchemaToolAgentGroundingJudgeMode,
        isExplicit: Bool,
        previousAgentConfiguration: [String: String]?
    ) -> SchemaToolAgentGroundingJudgeMode {
        guard !isExplicit else { return current }
        guard let recorded = recordedMode(in: previousAgentConfiguration) else { return .disabled }
        return SchemaToolAgentGroundingJudgeMode(rawValue: recorded) ?? current
    }
}

extension TextToSQLEvalResult {
    /// Records the run's first grounding-judge divergence and the judge-off
    /// arm it implies. With the judge off the run would have ended on the
    /// lexical clarification, so the off arm fails a case that expects SQL
    /// and otherwise passes when that clarification meets the case's
    /// clarification quality check, as the scorer would have scored it.
    func recordingGroundingJudgeDivergence(
        _ divergence: TextToSQLGroundingJudgeDivergence?,
        evalCase: TextToSQLEvalCase
    ) -> TextToSQLEvalResult {
        guard let divergence else { return self }
        let expectsClarification = evalCase.expected.decision == .clarify
        var copy = self
        copy.metrics.groundingJudgeDivergence = divergence.kind.rawValue
        copy.metrics.groundingJudgeOffArmDecisionMatches = expectsClarification
        copy.metrics.groundingJudgeOffArmPassed = expectsClarification
            && TextToSQLEvalScorer.clarificationQuality(
                divergence.lexicalClarificationQuestion,
                mustMentionAny: evalCase.expected.clarificationMustMentionAny
            )
        return copy
    }

    /// Completes the paired judge-off arm of a result from a run with the
    /// judge on, after any semantic annotation. A result that did not diverge
    /// is its own off arm. One that did keeps the decision and status arms
    /// recorded with its divergence and takes its end-to-end arm from them.
    public func withGroundingJudgeOffArm() -> TextToSQLEvalResult {
        var copy = self
        if metrics.groundingJudgeDivergence == nil {
            copy.metrics.groundingJudgeOffArmDecisionMatches = metrics.decisionMatches
            copy.metrics.groundingJudgeOffArmPassed = status == .passed
            copy.metrics.groundingJudgeOffArmEndToEndPassed = metrics.endToEndPassed
        } else {
            copy.metrics.groundingJudgeOffArmEndToEndPassed = metrics.endToEndPassed.map { _ in
                metrics.groundingJudgeOffArmPassed ?? false
            }
        }
        return copy
    }
}

/// One count over the same results for both arms of the paired comparison:
/// the run as it ran, with the judge on, and its judge-off arm.
public struct TextToSQLEvalPairedCount: Codable, Equatable, Sendable {
    public var onArm: Int
    public var offArm: Int
    public var denominator: Int

    public init(onArm: Int, offArm: Int, denominator: Int) {
        self.onArm = onArm
        self.offArm = offArm
        self.denominator = denominator
    }
}

/// Grounding judge counts over eval results, and the paired judge-off arm
/// derived inside the same run. The grounding judge experiment's
/// preregistered criteria are computed from these fields, so each one is
/// defined exactly here.
///
/// The judge-step counts read each result's schema-agent diagnostics, which
/// describe the last agent run behind its answer. The divergence counts read
/// the result's `groundingJudgeDivergence`, the run's first `enriched` call
/// that the judgment changed, which is what separates the two arms.
public struct TextToSQLEvalGroundingJudgeSummary: Codable, Equatable, Sendable {
    /// Results whose judgment the postprocessor was asked to use: the
    /// diagnostics carry a judgment with a postprocessor outcome, which
    /// `enriched` writes only when the lexical grounding pass flagged the
    /// agent's accepted SQL and would replace it with a clarification.
    public var eligibleResults: Int
    /// Eligible results whose judgment outcome is `judged`: the judge answered
    /// and its labels were verified.
    public var judgedResults: Int
    /// Judge requests sent over every result, failed ones included: the sum
    /// of the judgments' `callCount`.
    public var judgeCalls: Int
    /// Results whose judgment outcome is `failed`: the request or its reply
    /// failed, so the lexical decision stood. Each sent one request.
    public var failedResults: Int
    /// Judgment outcomes that skipped the request, such as `skippedNoFlags`
    /// or `skippedDeadline`, over every result with a judgment.
    public var skipReasonCounts: [String: Int]
    /// Each judged term's label over every `judged` judgment, `invalid`
    /// included.
    public var labelCounts: [String: Int]
    /// Terms in `judged` judgments.
    public var judgedTerms: Int
    /// Judged terms whose label verified, so they let the SQL stand.
    public var verifiedTerms: Int
    /// The postprocessor outcome over the eligible results: `released`, or
    /// `reAimed:` or `lexical:` and the reason the SQL was not released.
    public var postprocessorOutcomeCounts: [String: Int]
    /// Eligible `judged` results with at least one term, every term verified,
    /// whose postprocessor outcome is still not `released`: a backstop such
    /// as `mustClarify`, `criticClarify` or a sticky rejection overruled the
    /// judge.
    public var vetoedResults: Int
    /// Results whose divergence is `released`: the judgment kept SQL the
    /// lexical pass would have replaced.
    public var releasedResults: Int
    /// Results whose divergence is `reAimed`: the judgment pointed the
    /// clarification at another word.
    public var reAimedResults: Int
    /// Released results whose case expects a clarification.
    public var releasesOnExpectedClarification: Int
    /// Released results whose case expects SQL.
    public var releasedExpectedSQLResults: Int
    /// Released results whose case expects SQL and whose own semantic status
    /// is `passed`: the answer the release led to matched the golden result.
    public var releasedExpectedSQLSemanticPassed: Int
    /// `endToEndPassed` over the results that have it, as the run summary's
    /// end-to-end count: the on arm is the result's own value and the off arm
    /// `groundingJudgeOffArmEndToEndPassed`, or the result's own value when
    /// that is unset. Nil when no result has an end-to-end value, as outside
    /// semantic runs.
    public var endToEnd: TextToSQLEvalPairedCount?
    /// `status == .passed` over the results whose case expects a
    /// clarification, as the run summary's clarification decision count: the
    /// off arm is `groundingJudgeOffArmPassed` when set.
    public var clarificationDecisions: TextToSQLEvalPairedCount
    /// `decisionMatches` over the results whose structured response parsed,
    /// as the run summary's decision count: the off arm is
    /// `groundingJudgeOffArmDecisionMatches` when set.
    public var decisionMatches: TextToSQLEvalPairedCount
    /// Results whose case expects SQL and that answered with a clarification,
    /// as the triage's Expected `sql`, Actual `clarify` rows: no generated SQL
    /// and a clarification question. In the off arm every diverged result
    /// answered with the lexical clarification.
    public var expectedSQLClarified: TextToSQLEvalPairedCount

    /// The outcome of a judgment the judge answered.
    public static let judgedOutcome = SchemaToolAgentGroundingJudgeOutcome.judged.rawValue
    /// The outcome of a judgment whose request or reply failed.
    public static let failedOutcome = SchemaToolAgentGroundingJudgeOutcome.failed.rawValue
    /// The prefix of the outcomes that skipped the request.
    public static let skippedOutcomePrefix = "skipped"
    /// The postprocessor outcome that kept the SQL.
    public static let releasedPostprocessorOutcome = "released"

    public init(
        eligibleResults: Int,
        judgedResults: Int,
        judgeCalls: Int,
        failedResults: Int,
        skipReasonCounts: [String: Int],
        labelCounts: [String: Int],
        judgedTerms: Int,
        verifiedTerms: Int,
        postprocessorOutcomeCounts: [String: Int],
        vetoedResults: Int,
        releasedResults: Int,
        reAimedResults: Int,
        releasesOnExpectedClarification: Int,
        releasedExpectedSQLResults: Int,
        releasedExpectedSQLSemanticPassed: Int,
        endToEnd: TextToSQLEvalPairedCount?,
        clarificationDecisions: TextToSQLEvalPairedCount,
        decisionMatches: TextToSQLEvalPairedCount,
        expectedSQLClarified: TextToSQLEvalPairedCount
    ) {
        self.eligibleResults = eligibleResults
        self.judgedResults = judgedResults
        self.judgeCalls = judgeCalls
        self.failedResults = failedResults
        self.skipReasonCounts = skipReasonCounts
        self.labelCounts = labelCounts
        self.judgedTerms = judgedTerms
        self.verifiedTerms = verifiedTerms
        self.postprocessorOutcomeCounts = postprocessorOutcomeCounts
        self.vetoedResults = vetoedResults
        self.releasedResults = releasedResults
        self.reAimedResults = reAimedResults
        self.releasesOnExpectedClarification = releasesOnExpectedClarification
        self.releasedExpectedSQLResults = releasedExpectedSQLResults
        self.releasedExpectedSQLSemanticPassed = releasedExpectedSQLSemanticPassed
        self.endToEnd = endToEnd
        self.clarificationDecisions = clarificationDecisions
        self.decisionMatches = decisionMatches
        self.expectedSQLClarified = expectedSQLClarified
    }

    /// Nil when no result ran with the judge on: a run with
    /// `--schema-agent-grounding-judge off` or the legacy agent, or results
    /// written before the judge existed. `expectedDecisions` maps case IDs
    /// to the decision each case expects; a result whose case is missing
    /// counts only where the expected decision does not matter.
    public init?(
        results: [TextToSQLEvalResult],
        expectedDecisions: [String: TextToSQLEvalDecision]
    ) {
        guard results.contains(where: Self.ranWithTheJudge) else { return nil }
        let judgments = results.compactMap(\.metrics.openRouterAgentDiagnostics?.groundingJudgment)
        let eligible = judgments.filter { $0.postprocessorOutcome != nil }
        let judged = judgments.filter { $0.outcome == Self.judgedOutcome }
        let judgedTerms = judged.flatMap(\.terms)
        let released = results.filter {
            $0.metrics.groundingJudgeDivergence == TextToSQLGroundingJudgeDivergence.Kind.released.rawValue
        }
        let releasedExpectedSQL = released.filter { expectedDecisions[$0.caseID] == .sql }
        let endToEndResults = results.filter { $0.metrics.endToEndPassed != nil }
        let clarifyResults = results.filter { expectedDecisions[$0.caseID] == .clarify }
        let sqlResults = results.filter { expectedDecisions[$0.caseID] == .sql }
        let parsedResults = results.filter(\.metrics.structuredResponseParsed)
        self.init(
            eligibleResults: eligible.count,
            judgedResults: eligible.filter { $0.outcome == Self.judgedOutcome }.count,
            judgeCalls: judgments.reduce(0) { $0 + $1.callCount },
            failedResults: judgments.filter { $0.outcome == Self.failedOutcome }.count,
            skipReasonCounts: TextToSQLEvalExtraCallsRows.counts(
                judgments.map(\.outcome).filter { $0.hasPrefix(Self.skippedOutcomePrefix) }
            ),
            labelCounts: TextToSQLEvalExtraCallsRows.counts(judgedTerms.map(\.label)),
            judgedTerms: judgedTerms.count,
            verifiedTerms: judgedTerms.filter(\.verified).count,
            postprocessorOutcomeCounts: TextToSQLEvalExtraCallsRows.counts(
                eligible.compactMap(\.postprocessorOutcome)
            ),
            vetoedResults: eligible.filter {
                $0.outcome == Self.judgedOutcome
                    && !$0.terms.isEmpty
                    && $0.terms.allSatisfy(\.verified)
                    && $0.postprocessorOutcome != Self.releasedPostprocessorOutcome
            }.count,
            releasedResults: released.count,
            reAimedResults: results.filter {
                $0.metrics.groundingJudgeDivergence == TextToSQLGroundingJudgeDivergence.Kind.reAimed.rawValue
            }.count,
            releasesOnExpectedClarification: released.filter {
                expectedDecisions[$0.caseID] == .clarify
            }.count,
            releasedExpectedSQLResults: releasedExpectedSQL.count,
            releasedExpectedSQLSemanticPassed: releasedExpectedSQL.filter {
                $0.metrics.semanticStatus == .passed
            }.count,
            endToEnd: endToEndResults.isEmpty
                ? nil
                : Self.paired(endToEndResults) {
                    ($0.metrics.endToEndPassed == true, $0.metrics.groundingJudgeOffArmEndToEndPassed)
                },
            clarificationDecisions: Self.paired(clarifyResults) {
                ($0.status == .passed, $0.metrics.groundingJudgeOffArmPassed)
            },
            decisionMatches: Self.paired(parsedResults) {
                ($0.metrics.decisionMatches, $0.metrics.groundingJudgeOffArmDecisionMatches)
            },
            expectedSQLClarified: Self.paired(sqlResults) { result in
                let clarified = Self.answeredWithClarification(result)
                return (clarified, result.metrics.groundingJudgeDivergence == nil ? clarified : true)
            }
        )
    }

    /// `| Metric | Value |` rows, with dashes for a run without the judge.
    public static func markdownRows(_ summary: Self?) -> [String] {
        typealias Rows = TextToSQLEvalExtraCallsRows
        return [
            "| Grounding judge eligible results | \(Rows.value(summary?.eligibleResults)) |",
            "| Grounding judge judged results | \(Rows.share(summary?.judgedResults, of: summary?.eligibleResults)) |",
            "| Grounding judge calls | \(Rows.value(summary?.judgeCalls)) |",
            "| Grounding judge failed results | \(Rows.share(summary?.failedResults, of: summary?.judgeCalls)) |",
            "| Grounding judge skips | \(Rows.countList(summary?.skipReasonCounts)) |",
            "| Grounding judge labels | \(Rows.countList(summary?.labelCounts)) |",
            "| Grounding judge verified terms | \(Rows.share(summary?.verifiedTerms, of: summary?.judgedTerms)) |",
            "| Grounding judge postprocessor outcomes | \(Rows.countList(summary?.postprocessorOutcomeCounts)) |",
            "| Grounding judge vetoed releases | \(Rows.value(summary?.vetoedResults)) |",
            "| Grounding judge released results | \(Rows.value(summary?.releasedResults)) |",
            "| Grounding judge re-aimed results | \(Rows.value(summary?.reAimedResults)) |",
            "| Grounding judge releases on expected-clarify results | \(Rows.value(summary?.releasesOnExpectedClarification)) |",
            "| Grounding judge released expected-SQL semantic passes | \(Rows.share(summary?.releasedExpectedSQLSemanticPassed, of: summary?.releasedExpectedSQLResults)) |",
            "| Paired end-to-end passes (judge on, off) | \(pairedCell(summary?.endToEnd)) |",
            "| Paired clarification decision passes (judge on, off) | \(pairedCell(summary?.clarificationDecisions)) |",
            "| Paired decision matches (judge on, off) | \(pairedCell(summary?.decisionMatches)) |",
            "| Paired expected-SQL clarifications (judge on, off) | \(pairedCell(summary?.expectedSQLClarified)) |",
        ]
    }

    /// Whether a result ran with the judge on: its agent recorded the mode,
    /// or the eval completed its judge-off arm.
    private static func ranWithTheJudge(_ result: TextToSQLEvalResult) -> Bool {
        result.metrics.openRouterAgentDiagnostics?.groundingJudgeMode != nil
            || result.metrics.groundingJudgeOffArmDecisionMatches != nil
    }

    /// Counts both arms; an unset off arm equals the on arm.
    private static func paired(
        _ results: [TextToSQLEvalResult],
        arms: (TextToSQLEvalResult) -> (on: Bool, off: Bool?)
    ) -> TextToSQLEvalPairedCount {
        let values = results.map(arms)
        return TextToSQLEvalPairedCount(
            onArm: values.filter { $0.on }.count,
            offArm: values.filter { $0.off ?? $0.on }.count,
            denominator: values.count
        )
    }

    /// The triage's Actual `clarify`: no generated SQL, and a clarification.
    private static func answeredWithClarification(_ result: TextToSQLEvalResult) -> Bool {
        result.generatedSQL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && result.clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// `on 31, off 26 of 60`, or a dash without a count.
    private static func pairedCell(_ count: TextToSQLEvalPairedCount?) -> String {
        guard let count else { return "-" }
        return "on \(count.onArm), off \(count.offArm) of \(count.denominator)"
    }
}
