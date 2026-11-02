import Foundation

/// The eval's `--schema-agent-critic` flag, and the critic mode a run
/// manifest records. The mode lives in the manifest's agent configuration,
/// under the key `SchemaToolSQLAgentConfiguration.reportedSettings` uses.
public enum TextToSQLEvalSchemaAgentCritic {
    /// The agent configuration key that records the critic mode.
    public static let reportedSettingsKey = "criticMode"

    /// The mode for a `--schema-agent-critic` value: `on` or `enabled`, and
    /// `off` or `disabled`. Nil for any other value.
    public static func mode(flagValue: String) -> SchemaToolAgentCriticMode? {
        switch flagValue {
        case "on", "enabled":
            .enabled
        case "off", "disabled":
            .disabled
        default:
            nil
        }
    }

    /// The critic mode a run manifest's agent configuration records. Nil for
    /// a run without the schema agent, and for one recorded before the
    /// critic existed, which ran without it.
    public static func recordedMode(in agentConfiguration: [String: String]?) -> String? {
        agentConfiguration?[reportedSettingsKey]
    }

    /// The critic mode a resumed run uses: the flag when it was passed,
    /// otherwise the mode the previous run recorded, otherwise `current`.
    /// The resume compatibility check then rejects a mode that changed.
    public static func resumedMode(
        current: SchemaToolAgentCriticMode,
        isExplicit: Bool,
        previousAgentConfiguration: [String: String]?
    ) -> SchemaToolAgentCriticMode {
        guard !isExplicit,
            let recorded = recordedMode(in: previousAgentConfiguration),
            let mode = SchemaToolAgentCriticMode(rawValue: recorded)
        else { return current }
        return mode
    }
}

/// Critic counts over eval results, taken from each result's schema-agent
/// diagnostics. They show whether the critic actually ran, the extra-calls
/// layer's preregistered criterion K12: the critic reviewed at least 80% of
/// the eligible SQL terminals, and at most 10% of critic calls failed open.
///
/// A result keeps the diagnostics of the last agent run behind its answer.
/// A result that a repair answered therefore reports the repair run, which
/// the critic never reviews, and is not eligible.
public struct TextToSQLEvalCriticSummary: Codable, Equatable, Sendable {
    /// Results whose answer was SQL the critic could review: the critic was
    /// on and the run's SQL reached the critic step (its final outcome is
    /// set), outside repair mode and not from a forced final request, the
    /// two answers the critic skips by design. A forced answer is never
    /// reviewed, even one forced after a revision. A run also skips the
    /// critic near its deadline and at its HTTP or turn budget. Those skips
    /// stay eligible, so they count as SQL the layer left unreviewed.
    /// Clarifications and failed runs have no outcome, unless a revision
    /// released the SQL from before it.
    public var eligibleSQLTerminals: Int
    /// Eligible results with at least one critic request sent.
    public var reviewedResults: Int
    /// Critic requests sent over every result, failed ones included.
    public var criticCalls: Int
    /// Each review's verdict over every result: `accept`, `revise`,
    /// `clarify`, or `error` for a review that failed.
    public var verdictCounts: [String: Int]
    /// How the critic step ended, over every result that reached it.
    public var finalOutcomeCounts: [String: Int]
    /// Results whose SQL the critic sent back for revision at least once.
    public var revisedResults: Int
    /// Revisions sent back over every result.
    public var revisions: Int
    /// Critic requests that failed, so the SQL stood unreviewed: the
    /// `error` verdicts.
    public var failedOpenCalls: Int

    /// The verdict a failed review records.
    public static let failedOpenVerdict = "error"
    /// The final outcome of SQL from a repair run, which is never reviewed.
    public static let repairModeOutcome = "skippedRepairMode"
    /// The final outcome of a forced final answer, which is never reviewed.
    public static let forcedTerminalOutcome = "skippedForcedTerminal"
    /// The final outcomes of SQL the critic skips by design, which is not
    /// eligible for review.
    public static let ineligibleOutcomes: Set<String> = [repairModeOutcome, forcedTerminalOutcome]
    /// The suffix of the outcomes that released the SQL from before a
    /// revision, because the revision turned into a clarification, changed
    /// the statement kind or failed.
    public static let releasedPreviousOutcomeSuffix = "ReleasedPrevious"

    public init(
        eligibleSQLTerminals: Int,
        reviewedResults: Int,
        criticCalls: Int,
        verdictCounts: [String: Int],
        finalOutcomeCounts: [String: Int],
        revisedResults: Int,
        revisions: Int,
        failedOpenCalls: Int
    ) {
        self.eligibleSQLTerminals = eligibleSQLTerminals
        self.reviewedResults = reviewedResults
        self.criticCalls = criticCalls
        self.verdictCounts = verdictCounts
        self.finalOutcomeCounts = finalOutcomeCounts
        self.revisedResults = revisedResults
        self.revisions = revisions
        self.failedOpenCalls = failedOpenCalls
    }

    /// Nil when no result ran with the critic on: a run with
    /// `--schema-agent-critic off` or the legacy agent, or results written
    /// before the critic existed.
    public init?(results: [TextToSQLEvalResult]) {
        let diagnostics = results.compactMap(\.metrics.openRouterAgentDiagnostics)
            .filter { $0.criticMode != nil }
        guard !diagnostics.isEmpty else { return nil }
        let eligible = diagnostics.filter {
            guard let outcome = $0.criticFinalOutcome else { return false }
            return !Self.ineligibleOutcomes.contains(outcome)
        }
        let verdicts = diagnostics.flatMap { $0.criticVerdicts ?? [] }
        self.init(
            eligibleSQLTerminals: eligible.count,
            reviewedResults: eligible.filter { ($0.criticCallCount ?? 0) > 0 }.count,
            criticCalls: diagnostics.reduce(0) { $0 + ($1.criticCallCount ?? 0) },
            verdictCounts: TextToSQLEvalExtraCallsRows.counts(verdicts),
            finalOutcomeCounts: TextToSQLEvalExtraCallsRows.counts(
                diagnostics.compactMap(\.criticFinalOutcome)
            ),
            revisedResults: diagnostics.filter { ($0.criticRevisionCount ?? 0) > 0 }.count,
            revisions: diagnostics.reduce(0) { $0 + ($1.criticRevisionCount ?? 0) },
            failedOpenCalls: verdicts.filter { $0 == Self.failedOpenVerdict }.count
        )
    }

    /// Results that kept the SQL from before a revision.
    public var releasedPreviousResults: Int {
        finalOutcomeCounts
            .filter { $0.key.hasSuffix(Self.releasedPreviousOutcomeSuffix) }
            .values
            .reduce(0, +)
    }

    /// `| Metric | Value |` rows, with dashes for a run without the critic.
    public static func markdownRows(_ summary: Self?) -> [String] {
        typealias Rows = TextToSQLEvalExtraCallsRows
        return [
            "| Critic eligible SQL terminals | \(Rows.value(summary?.eligibleSQLTerminals)) |",
            "| Critic reviewed results | \(Rows.share(summary?.reviewedResults, of: summary?.eligibleSQLTerminals)) |",
            "| Critic calls | \(Rows.value(summary?.criticCalls)) |",
            "| Critic failed-open calls | \(Rows.share(summary?.failedOpenCalls, of: summary?.criticCalls)) |",
            "| Critic verdicts | \(Rows.countList(summary?.verdictCounts)) |",
            "| Critic final outcomes | \(Rows.countList(summary?.finalOutcomeCounts)) |",
            "| Critic revised results | \(Rows.value(summary?.revisedResults)) |",
            "| Critic revisions | \(Rows.value(summary?.revisions)) |",
            "| Critic releases of pre-revision SQL | \(Rows.value(summary?.releasedPreviousResults)) |",
        ]
    }
}

/// Forced final-answer counts over eval results, taken from each result's
/// schema-agent diagnostics. Criterion K12 requires that the provider
/// rejected no forced request.
///
/// A result keeps the diagnostics of the last agent run behind its answer,
/// so a forced request from a first generation that a repair later replaced
/// is not counted. A rejected forced request fails its run, and a failed
/// run is never repaired, so every rejection is counted.
public struct TextToSQLEvalForcedTerminalSummary: Codable, Equatable, Sendable {
    /// Results whose run sent at least one forced final request.
    public var attempted: Int
    /// Results whose forced request ended in an accepted terminal answer.
    public var succeeded: Int
    /// Why runs forced their final answer: `toolBudget`, `turnBudget`,
    /// `terminalRequired` or `timeReserve`. Counts every run that turned to
    /// a forced answer, including one that ran out of time or HTTP attempts
    /// before it could send the request.
    public var reasonCounts: [String: Int]
    /// Results whose forced request the provider refused as a request it
    /// does not accept (`invalidRequest` or `unsupportedFeature`), which
    /// means it did not honor the forced request's shape: the named
    /// `tool_choice`, `parallel_tool_calls: false` or the terminal tool sent
    /// alone. Rate limits, timeouts, server errors and invalid model output
    /// are not rejections.
    public var providerRejected: Int

    /// The `forcedTerminalFailure` values of a provider rejection.
    public static let providerRejectionFailures = Set(
        [CloudRequestFailure.Category.invalidRequest, .unsupportedFeature].map {
            "cloudRequestFailure:\($0.rawValue)"
        }
    )

    public init(
        attempted: Int,
        succeeded: Int,
        reasonCounts: [String: Int],
        providerRejected: Int
    ) {
        self.attempted = attempted
        self.succeeded = succeeded
        self.reasonCounts = reasonCounts
        self.providerRejected = providerRejected
    }

    /// Nil when no result has schema-agent diagnostics, as in a legacy
    /// agent run.
    public init?(results: [TextToSQLEvalResult]) {
        let diagnostics = results.compactMap(\.metrics.openRouterAgentDiagnostics)
        guard !diagnostics.isEmpty else { return nil }
        self.init(
            attempted: diagnostics.filter { ($0.forcedTerminalRequestCount ?? 0) > 0 }.count,
            succeeded: diagnostics.filter { $0.forcedTerminalSucceeded == true }.count,
            reasonCounts: TextToSQLEvalExtraCallsRows.counts(
                diagnostics.compactMap(\.forcedTerminalReason)
            ),
            providerRejected: diagnostics.filter {
                $0.forcedTerminalFailure.map(Self.providerRejectionFailures.contains) == true
            }.count
        )
    }

    /// `| Metric | Value |` rows, with dashes for a run without the agent.
    public static func markdownRows(_ summary: Self?) -> [String] {
        typealias Rows = TextToSQLEvalExtraCallsRows
        return [
            "| Forced final answers attempted | \(Rows.value(summary?.attempted)) |",
            "| Forced final answers succeeded | \(Rows.share(summary?.succeeded, of: summary?.attempted)) |",
            "| Forced final answer reasons | \(Rows.countList(summary?.reasonCounts)) |",
            "| Forced requests rejected by the provider | \(Rows.value(summary?.providerRejected)) |",
        ]
    }
}

/// Counting and cell formatting shared by the critic and forced-terminal
/// summaries.
enum TextToSQLEvalExtraCallsRows {
    static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    static func value(_ count: Int?) -> String {
        count.map(String.init) ?? "-"
    }

    /// `3 of 4 (75.0%)`, or just `0 of 0` when there is nothing to divide.
    static func share(_ count: Int?, of denominator: Int?) -> String {
        guard let count, let denominator else { return "-" }
        guard denominator > 0 else { return "\(count) of \(denominator)" }
        let percent = String(format: "%.1f%%", Double(count) / Double(denominator) * 100)
        return "\(count) of \(denominator) (\(percent))"
    }

    /// `accept 3, revise 1` in key order, or a dash when there are none.
    static func countList(_ counts: [String: Int]?) -> String {
        guard let counts, !counts.isEmpty else { return "-" }
        return counts.keys.sorted()
            .map { "\(tableCell($0)) \(counts[$0] ?? 0)" }
            .joined(separator: ", ")
    }

    private static func tableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
