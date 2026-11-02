import Foundation

public enum TextToSQLReleaseArtifactVersionPolicy {
    public struct Violation: LocalizedError, Equatable, Sendable {
        public var errorDescription: String? {
            "Release artifact versions must be 1-64 ASCII letters, digits, periods, hyphens, or underscores and start with a letter or digit."
        }
    }

    public static func validate(_ version: String) throws {
        let scalars = version.unicodeScalars
        guard (1...64).contains(version.utf8.count),
            let first = scalars.first,
            isASCIIAlphanumeric(first),
            scalars.allSatisfy(isAllowed)
        else {
            throw Violation()
        }
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        default:
            false
        }
    }
}

/// Runs that publish committed release-gate or triage docs must evaluate the
/// pinned production model, Particle-1: requested as `particle-1` and
/// verified as `particle-ai/particle-1`, through the schema agent modes the
/// app ships. Enforced at the eval CLI so a future Makefile target or direct
/// binary invocation cannot bypass the Makefile guard.
public enum TextToSQLReleaseGateModelPolicy {
    /// The schema agent's switchable modes as raw values: what a run manifest
    /// recorded, or what an eval is about to run. Nil is a mode the run did
    /// not record, as in a manifest from before the critic or the judge.
    public struct AgentModes: Equatable, Sendable {
        public var clarificationCorrection: String?
        public var intentCoverage: String?
        public var planConsistency: String?
        public var critic: String?
        public var groundingJudge: String?

        public init(
            clarificationCorrection: String?,
            intentCoverage: String?,
            planConsistency: String?,
            critic: String?,
            groundingJudge: String?
        ) {
            self.clarificationCorrection = clarificationCorrection
            self.intentCoverage = intentCoverage
            self.planConsistency = planConsistency
            self.critic = critic
            self.groundingJudge = groundingJudge
        }

        /// The modes the app's agent runs with.
        public static var production: AgentModes {
            let configuration = SchemaToolSQLAgentConfiguration.default
            return AgentModes(
                clarificationCorrection: configuration.clarificationCorrectionMode.rawValue,
                intentCoverage: configuration.intentCoverageMode.rawValue,
                planConsistency: configuration.planConsistencyMode.rawValue,
                critic: configuration.criticMode.rawValue,
                groundingJudge: configuration.groundingJudgeMode.rawValue
            )
        }

        /// The first mode that is not the app's, in the order gate reports
        /// list them. Nil when every mode is.
        public var firstNonProductionMode: AgentModeDifference? {
            let production = Self.production
            let modes: [(setting: String, actual: String?, expected: String?)] = [
                ("clarification correction", clarificationCorrection, production.clarificationCorrection),
                ("intent coverage", intentCoverage, production.intentCoverage),
                ("plan consistency", planConsistency, production.planConsistency),
                ("critic", critic, production.critic),
                ("grounding judge", groundingJudge, production.groundingJudge),
            ]
            return modes.first { $0.actual != $0.expected }.map {
                AgentModeDifference(setting: $0.setting, actual: $0.actual, expected: $0.expected)
            }
        }
    }

    /// A schema agent mode a run used instead of the app's, as an eval-only
    /// `--schema-agent-*` flag or a resumed run's recorded mode sets.
    public struct AgentModeDifference: Equatable, Sendable {
        /// The mode as gate reports label it, such as `grounding judge`.
        public var setting: String
        /// Nil means the run recorded no mode.
        public var actual: String?
        public var expected: String?

        public init(setting: String, actual: String?, expected: String?) {
            self.setting = setting
            self.actual = actual
            self.expected = expected
        }
    }

    public enum CommittedDocIneligibility: Equatable, Sendable, CustomStringConvertible {
        case pinnedModelRequired(actual: String?)
        case expectedReturnedModelRequired(actual: String?)
        /// The run sent a reasoning effort other than the production
        /// profile's, as an eval-only `--reasoning-effort` does. Nil means
        /// no effort was sent.
        case productionReasoningEffortRequired(actual: String?, expected: String?)
        /// The schema agent ran a mode other than the app's, as an eval-only
        /// `--schema-agent-*` flag sets.
        case productionAgentModeRequired(AgentModeDifference)
        case cloudEvaluationRequired

        public var description: String {
            let profile = TextToSQLReleaseGateModelPolicy.pinnedProfile
            let pinned = TextToSQLReleaseGateModelPolicy.pinnedModelArgument
            switch self {
            case .pinnedModelRequired(let actual):
                return "the requested model is \(actual ?? "missing"), not the pinned \(pinned)"
            case .expectedReturnedModelRequired(let actual):
                return "the manifest expected returned model is \(actual ?? "missing"), not \(profile.expectedReturnedModelID ?? "missing") for \(pinned)"
            case .productionReasoningEffortRequired(let actual, let expected):
                return "the run's reasoning effort is \(actual ?? "unset"), not the production \(expected ?? "unset") for \(pinned)"
            case .productionAgentModeRequired(let difference):
                return "the run's schema agent \(difference.setting) mode is \(difference.actual ?? "unset"), not the production \(difference.expected ?? "unset") for \(pinned)"
            case .cloudEvaluationRequired:
                return "the run has no backend-available cloud results"
            }
        }
    }

    public struct Violation: LocalizedError, CustomStringConvertible, Equatable, Sendable {
        public var model: String?
        /// Set when the pinned model ran with an eval-only `--reasoning-effort`.
        public var reasoningEffortOverride: ReasoningEffort? = nil
        /// Set when the pinned model ran a schema agent mode the app does not.
        public var agentModeOverride: AgentModeDifference? = nil
        public var pinnedModel: String {
            TextToSQLReleaseGateModelPolicy.pinnedProfile.requestedModelID
        }

        public var description: String {
            let pinned = TextToSQLReleaseGateModelPolicy.pinnedModelArgument
            if let reasoningEffortOverride {
                return "Release-gate and triage docs require \(pinned) at its production reasoning effort, but --reasoning-effort \(reasoningEffortOverride.rawValue) overrides it; pass --allow-model-override to run an engineering comparison."
            }
            if let agentModeOverride {
                return "Release-gate and triage docs require \(pinned) with the app's schema agent modes, but the run's \(agentModeOverride.setting) mode is \(agentModeOverride.actual ?? "unset"), not \(agentModeOverride.expected ?? "unset"); pass --allow-model-override to run an engineering comparison."
            }
            guard let model else {
                return "Release-gate and triage docs require \(pinned), but the run recorded no model; pass --allow-model-override to run an engineering comparison."
            }
            return "Release-gate and triage docs require \(pinned) but got MODEL=\(model); pass --allow-model-override to run an engineering comparison."
        }

        public var errorDescription: String? { description }
    }

    /// The profile committed release-gate and triage docs must evaluate.
    static var pinnedProfile: CloudModelProfile {
        CloudModelCatalog.productionProfile
    }

    /// How messages name the pinned model: the Makefile variable that selects
    /// it, plus its display name.
    static var pinnedModelArgument: String {
        "MODEL=\(pinnedProfile.requestedModelID) (\(pinnedProfile.displayName))"
    }

    /// `reasoningEffortOverride` is the eval-only `--reasoning-effort`. It
    /// changes what the pinned model is asked to do, so a doc-publishing run
    /// that passes it needs the same override flag as another model. So does
    /// a run whose `agentModes`, the schema agent modes it will use, are not
    /// the app's; nil means it runs no schema agent.
    public static func validate(
        model: String?,
        reasoningEffortOverride: ReasoningEffort? = nil,
        agentModes: AgentModes? = nil,
        releaseGateVersion: String?,
        releaseTriageVersion: String?,
        allowModelOverride: Bool
    ) throws {
        if let releaseGateVersion {
            try TextToSQLReleaseArtifactVersionPolicy.validate(releaseGateVersion)
        }
        if let releaseTriageVersion {
            try TextToSQLReleaseArtifactVersionPolicy.validate(releaseTriageVersion)
        }
        guard releaseGateVersion != nil || releaseTriageVersion != nil,
            !allowModelOverride
        else { return }
        guard model == pinnedProfile.requestedModelID else {
            throw Violation(model: model)
        }
        if let reasoningEffortOverride {
            throw Violation(model: model, reasoningEffortOverride: reasoningEffortOverride)
        }
        if let difference = agentModes?.firstNonProductionMode {
            throw Violation(model: model, agentModeOverride: difference)
        }
    }

    /// Sink-time eligibility is deliberately stricter than the override used
    /// to run engineering comparisons: overrides never publish committed docs.
    public static func canPublishCommittedDocs(
        model: String?,
        expectedReturnedModelID: String?,
        reasoningEffort: String?,
        callSite: CloudCallSite,
        agentModes: AgentModes?,
        cloudEvaluatedResultCount: Int
    ) -> Bool {
        committedDocIneligibility(
            model: model,
            expectedReturnedModelID: expectedReturnedModelID,
            reasoningEffort: reasoningEffort,
            callSite: callSite,
            agentModes: agentModes,
            cloudEvaluatedResultCount: cloudEvaluatedResultCount
        ) == nil
    }

    /// `reasoningEffort` is the effort the run manifest recorded for
    /// `callSite`. Only the production profile's own effort for that call
    /// site publishes, so a `--reasoning-effort` run never does. Likewise
    /// `agentModes`, the schema agent modes the manifest recorded, publish
    /// only as the app's; nil means the run had no schema agent.
    public static func committedDocIneligibility(
        model: String?,
        expectedReturnedModelID: String?,
        reasoningEffort: String?,
        callSite: CloudCallSite,
        agentModes: AgentModes?,
        cloudEvaluatedResultCount: Int
    ) -> CommittedDocIneligibility? {
        let profile = pinnedProfile
        guard model == profile.requestedModelID else {
            return .pinnedModelRequired(actual: model)
        }
        guard let pinnedReturnedModelID = profile.expectedReturnedModelID,
            expectedReturnedModelID == pinnedReturnedModelID
        else {
            return .expectedReturnedModelRequired(actual: expectedReturnedModelID)
        }
        let productionReasoningEffort = profile.policy(for: callSite).reasoningEffort?.rawValue
        guard reasoningEffort == productionReasoningEffort else {
            return .productionReasoningEffortRequired(
                actual: reasoningEffort,
                expected: productionReasoningEffort
            )
        }
        if let difference = agentModes?.firstNonProductionMode {
            return .productionAgentModeRequired(difference)
        }
        guard cloudEvaluatedResultCount > 0 else {
            return .cloudEvaluationRequired
        }
        return nil
    }
}

public struct TextToSQLReleaseGateCount: Codable, Equatable, Sendable {
    public var count: Int
    public var denominator: Int

    public init(count: Int, denominator: Int) {
        self.count = count
        self.denominator = denominator
    }

    public var rate: Double? {
        guard denominator > 0 else { return nil }
        return Double(count) / Double(denominator)
    }
}

public struct TextToSQLReleaseGateInput: Codable, Equatable, Sendable {
    public var totalResults: Int {
        didSet {
            if completedResults == oldValue {
                completedResults = totalResults
            }
        }
    }
    public var expectedResults: Int
    public var completedResults: Int
    public var missingResults: Int
    public var skippedBudgetResults: Int
    public var providerBudgetUnavailableResults: Int
    public var endToEndPass: TextToSQLReleaseGateCount?
    public var safetyValid: TextToSQLReleaseGateCount
    public var schemaValid: TextToSQLReleaseGateCount
    public var clarificationDecisionPass: TextToSQLReleaseGateCount?
    public var transportSuccess: TextToSQLReleaseGateCount
    public var repeatedNoProgressRepairCount: Int

    public init(
        totalResults: Int,
        expectedResults: Int = TextToSQLReleaseGate.expectedResultCount,
        completedResults: Int? = nil,
        missingResults: Int = 0,
        skippedBudgetResults: Int = 0,
        providerBudgetUnavailableResults: Int = 0,
        endToEndPass: TextToSQLReleaseGateCount?,
        safetyValid: TextToSQLReleaseGateCount,
        schemaValid: TextToSQLReleaseGateCount,
        clarificationDecisionPass: TextToSQLReleaseGateCount?,
        transportSuccess: TextToSQLReleaseGateCount,
        repeatedNoProgressRepairCount: Int
    ) {
        self.totalResults = totalResults
        self.expectedResults = expectedResults
        self.completedResults = completedResults ?? totalResults
        self.missingResults = missingResults
        self.skippedBudgetResults = skippedBudgetResults
        self.providerBudgetUnavailableResults = providerBudgetUnavailableResults
        self.endToEndPass = endToEndPass
        self.safetyValid = safetyValid
        self.schemaValid = schemaValid
        self.clarificationDecisionPass = clarificationDecisionPass
        self.transportSuccess = transportSuccess
        self.repeatedNoProgressRepairCount = repeatedNoProgressRepairCount
    }
}

public struct TextToSQLReleaseGateCriterion: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var observed: String
    public var required: String
    public var passed: Bool

    public init(
        id: String,
        label: String,
        observed: String,
        required: String,
        passed: Bool
    ) {
        self.id = id
        self.label = label
        self.observed = observed
        self.required = required
        self.passed = passed
    }
}

public struct TextToSQLReleaseGateEvaluation: Codable, Equatable, Sendable {
    public var passed: Bool
    public var criteria: [TextToSQLReleaseGateCriterion]

    public init(criteria: [TextToSQLReleaseGateCriterion]) {
        self.criteria = criteria
        self.passed = criteria.allSatisfy(\.passed)
    }

    public var failureMessages: [String] {
        criteria
            .filter { !$0.passed }
            .map { criterion in
                if criterion.id == "result-count" {
                    return criterion.label
                }
                return "\(criterion.label): observed \(criterion.observed), required \(criterion.required)"
            }
    }

    public var incompleteFailureMessages: [String] {
        criteria
            .filter { !$0.passed && $0.id == "result-count" }
            .map(\.label)
    }

    public var thresholdFailureMessages: [String] {
        criteria
            .filter { !$0.passed && $0.id != "result-count" }
            .map { "\($0.label): observed \($0.observed), required \($0.required)" }
    }
}

public enum TextToSQLReleaseGate {
    public static let expectedResultCount = 60
    public static let minimumEndToEndRate = 0.90
    public static let minimumTransportReliability = 0.95

    public static func evaluate(_ input: TextToSQLReleaseGateInput) -> TextToSQLReleaseGateEvaluation {
        let criteria = [
            completenessCriterion(
                id: "result-count",
                completed: input.completedResults,
                expected: input.expectedResults
            ),
            rateCriterion(
                id: "end-to-end",
                label: "End-to-end semantic pass rate",
                count: input.endToEndPass,
                minimumRate: minimumEndToEndRate
            ),
            allPassedCriterion(
                id: "safety",
                label: "Safety validity",
                count: input.safetyValid
            ),
            allPassedCriterion(
                id: "schema",
                label: "Schema validity",
                count: input.schemaValid
            ),
            allPassedCriterion(
                id: "clarification",
                label: "Clarification decision accuracy",
                count: input.clarificationDecisionPass
            ),
            rateCriterion(
                id: "transport",
                label: "Transport reliability",
                count: input.transportSuccess,
                minimumRate: minimumTransportReliability
            ),
            exactIntCriterion(
                id: "no-progress-repair",
                label: "Repeated repair fingerprint/no-progress repair count",
                observed: input.repeatedNoProgressRepairCount,
                required: 0
            ),
        ]
        return TextToSQLReleaseGateEvaluation(criteria: criteria)
    }

    private static func exactIntCriterion(
        id: String,
        label: String,
        observed: Int,
        required: Int
    ) -> TextToSQLReleaseGateCriterion {
        TextToSQLReleaseGateCriterion(
            id: id,
            label: label,
            observed: String(observed),
            required: String(required),
            passed: observed == required
        )
    }

    private static func completenessCriterion(
        id: String,
        completed: Int,
        expected: Int
    ) -> TextToSQLReleaseGateCriterion {
        TextToSQLReleaseGateCriterion(
            id: id,
            label: completed == expected
                ? "Complete release-gate evaluation"
                : "Release gate incomplete: only \(completed)/\(expected) expected results were evaluated.",
            observed: "\(completed)/\(expected)",
            required: "\(expected)/\(expected)",
            passed: completed == expected
        )
    }

    private static func allPassedCriterion(
        id: String,
        label: String,
        count: TextToSQLReleaseGateCount?
    ) -> TextToSQLReleaseGateCriterion {
        let observed = count.map(formatCount) ?? "-"
        return TextToSQLReleaseGateCriterion(
            id: id,
            label: label,
            observed: observed,
            required: "100% of evaluated results",
            passed: count.map { $0.denominator > 0 && $0.count == $0.denominator } ?? false
        )
    }

    private static func rateCriterion(
        id: String,
        label: String,
        count: TextToSQLReleaseGateCount?,
        minimumRate: Double
    ) -> TextToSQLReleaseGateCriterion {
        let observed = count.map(formatCount) ?? "-"
        let passed = count?.rate.map { $0 >= minimumRate } ?? false
        return TextToSQLReleaseGateCriterion(
            id: id,
            label: label,
            observed: observed,
            required: ">= \(formatPercent(minimumRate))",
            passed: passed
        )
    }

    private static func formatCount(_ count: TextToSQLReleaseGateCount) -> String {
        guard let rate = count.rate else { return "\(count.count)/\(count.denominator)" }
        return "\(count.count)/\(count.denominator) (\(formatPercent(rate)))"
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
