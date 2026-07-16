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
/// pinned production model. Enforced at the eval CLI so a future Makefile
/// target or direct binary invocation cannot bypass the Makefile guard.
public enum TextToSQLReleaseGateModelPolicy {
    public enum CommittedDocIneligibility: Equatable, Sendable, CustomStringConvertible {
        case cloudBackendRequired
        case pinnedModelRequired(actual: String?)
        case expectedCanonicalModelRequired(actual: String?)
        case cloudEvaluationRequired

        public var description: String {
            let profile = OpenRouterCatalog.productionProfile
            switch self {
            case .cloudBackendRequired:
                return "the run does not include the cloud backend"
            case .pinnedModelRequired(let actual):
                return "the requested model is \(actual ?? "missing"), not the pinned model \(profile.requestedModelID)"
            case .expectedCanonicalModelRequired(let actual):
                return "the manifest expected canonical model is \(actual ?? "missing"), not \(profile.expectedCanonicalModelID)"
            case .cloudEvaluationRequired:
                return "the run has no backend-available cloud results"
            }
        }
    }

    public struct Violation: LocalizedError, CustomStringConvertible, Equatable, Sendable {
        public var model: String?
        public var pinnedModel: String {
            OpenRouterCatalog.productionProfile.requestedModelID
        }

        public var description: String {
            guard let model else {
                return "Release-gate and triage docs require a cloud run using the pinned production model \(pinnedModel); pass --allow-model-override to run an engineering comparison."
            }
            return "Release-gate and triage docs require the pinned production model \(pinnedModel) but got \(model); pass --allow-model-override to run an engineering comparison."
        }

        public var errorDescription: String? { description }
    }

    public static func validate(
        model: String?,
        backendIncludesCloud: Bool,
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
        guard !isPinnedCloudRun(model: model, backendIncludesCloud: backendIncludesCloud)
        else { return }
        throw Violation(model: backendIncludesCloud ? model : nil)
    }

    /// Sink-time eligibility is deliberately stricter than the override used
    /// to run engineering comparisons: overrides never publish committed docs.
    public static func canPublishCommittedDocs(
        model: String?,
        expectedCanonicalModelID: String?,
        backendIncludesCloud: Bool,
        cloudEvaluatedResultCount: Int
    ) -> Bool {
        committedDocIneligibility(
            model: model,
            expectedCanonicalModelID: expectedCanonicalModelID,
            backendIncludesCloud: backendIncludesCloud,
            cloudEvaluatedResultCount: cloudEvaluatedResultCount
        ) == nil
    }

    public static func committedDocIneligibility(
        model: String?,
        expectedCanonicalModelID: String?,
        backendIncludesCloud: Bool,
        cloudEvaluatedResultCount: Int
    ) -> CommittedDocIneligibility? {
        let profile = OpenRouterCatalog.productionProfile
        guard backendIncludesCloud else { return .cloudBackendRequired }
        guard model == profile.requestedModelID else {
            return .pinnedModelRequired(actual: model)
        }
        guard expectedCanonicalModelID == profile.expectedCanonicalModelID else {
            return .expectedCanonicalModelRequired(actual: expectedCanonicalModelID)
        }
        guard cloudEvaluatedResultCount > 0 else {
            return .cloudEvaluationRequired
        }
        return nil
    }

    private static func isPinnedCloudRun(
        model: String?,
        backendIncludesCloud: Bool
    ) -> Bool {
        backendIncludesCloud
            && model == OpenRouterCatalog.productionProfile.requestedModelID
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
