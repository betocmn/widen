import Foundation

public struct TextToSQLEvalResultKey: Codable, Hashable, Sendable {
    public var caseID: String
    public var backend: TextToSQLEvalBackend
    public var repeatIndex: Int

    public init(caseID: String, backend: TextToSQLEvalBackend, repeatIndex: Int) {
        self.caseID = caseID
        self.backend = backend
        self.repeatIndex = repeatIndex
    }

    public init(result: TextToSQLEvalResult) {
        self.init(
            caseID: result.caseID,
            backend: result.backend,
            repeatIndex: result.repeatIndex
        )
    }
}

public enum TextToSQLEvalNotEvaluatedReason: String, Codable, Equatable, Sendable {
    case missing
    case skippedBudgetLimit
    case providerBudgetUnavailable
    case backendUnavailable
}

public struct TextToSQLEvalNotEvaluatedSlot: Codable, Equatable, Sendable {
    public var key: TextToSQLEvalResultKey
    public var reason: TextToSQLEvalNotEvaluatedReason

    public init(
        key: TextToSQLEvalResultKey,
        reason: TextToSQLEvalNotEvaluatedReason
    ) {
        self.key = key
        self.reason = reason
    }
}

public struct TextToSQLEvalRunCompleteness: Codable, Equatable, Sendable {
    public var expectedResultCount: Int
    public var completedResultCount: Int
    public var missingResultCount: Int
    public var skippedBudgetCount: Int
    public var providerBudgetUnavailableCount: Int
    public var backendUnavailableCount: Int
    public var notEvaluated: [TextToSQLEvalNotEvaluatedSlot]

    public var isComplete: Bool {
        completedResultCount == expectedResultCount
    }

    public var incompleteMessage: String? {
        guard !isComplete else { return nil }
        return "Release gate incomplete: only \(completedResultCount)/\(expectedResultCount) expected results were evaluated."
    }

    public static func evaluate(
        expectedKeys: [TextToSQLEvalResultKey],
        results: [TextToSQLEvalResult]
    ) -> TextToSQLEvalRunCompleteness {
        let resultsByKey = Dictionary(
            results.map { (TextToSQLEvalResultKey(result: $0), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var completed = 0
        var missing = 0
        var skippedBudget = 0
        var providerBudgetUnavailable = 0
        var backendUnavailable = 0
        var notEvaluated: [TextToSQLEvalNotEvaluatedSlot] = []

        for key in expectedKeys {
            guard let result = resultsByKey[key] else {
                missing += 1
                notEvaluated.append(TextToSQLEvalNotEvaluatedSlot(key: key, reason: .missing))
                continue
            }

            guard let reason = result.status.notEvaluatedReason else {
                completed += 1
                continue
            }

            switch reason {
            case .skippedBudgetLimit:
                skippedBudget += 1
                notEvaluated.append(TextToSQLEvalNotEvaluatedSlot(key: key, reason: .skippedBudgetLimit))
            case .providerBudgetUnavailable:
                providerBudgetUnavailable += 1
                notEvaluated.append(TextToSQLEvalNotEvaluatedSlot(key: key, reason: .providerBudgetUnavailable))
            case .backendUnavailable:
                backendUnavailable += 1
                notEvaluated.append(TextToSQLEvalNotEvaluatedSlot(key: key, reason: .backendUnavailable))
            case .missing:
                missing += 1
                notEvaluated.append(TextToSQLEvalNotEvaluatedSlot(key: key, reason: .missing))
            }
        }

        return TextToSQLEvalRunCompleteness(
            expectedResultCount: expectedKeys.count,
            completedResultCount: completed,
            missingResultCount: missing,
            skippedBudgetCount: skippedBudget,
            providerBudgetUnavailableCount: providerBudgetUnavailable,
            backendUnavailableCount: backendUnavailable,
            notEvaluated: notEvaluated
        )
    }
}

public struct TextToSQLEvalResumeSelection: Equatable, Sendable {
    public var resumeMissing: Bool
    public var resumeFailed: Bool
    public var statuses: Set<TextToSQLEvalCaseStatus>

    public init(
        resumeMissing: Bool = false,
        resumeFailed: Bool = false,
        statuses: Set<TextToSQLEvalCaseStatus> = []
    ) {
        self.resumeMissing = resumeMissing
        self.resumeFailed = resumeFailed
        self.statuses = statuses
    }
}

public struct TextToSQLEvalResumePlan: Equatable, Sendable {
    public var reusableResults: [TextToSQLEvalResult]
    public var keysToRun: [TextToSQLEvalResultKey]

    public init(
        reusableResults: [TextToSQLEvalResult],
        keysToRun: [TextToSQLEvalResultKey]
    ) {
        self.reusableResults = reusableResults
        self.keysToRun = keysToRun
    }
}

public enum TextToSQLEvalResumePlanner {
    public static func plan(
        expectedKeys: [TextToSQLEvalResultKey],
        previousResults: [TextToSQLEvalResult],
        selection: TextToSQLEvalResumeSelection
    ) -> TextToSQLEvalResumePlan {
        let previousByKey = Dictionary(
            previousResults.map { (TextToSQLEvalResultKey(result: $0), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let expectedSet = Set(expectedKeys)
        let keysToRun = expectedKeys.filter { key in
            guard let previous = previousByKey[key] else {
                return selection.resumeMissing
            }
            if selection.resumeMissing, !previous.status.isCompletedEvaluation {
                return true
            }
            if selection.resumeFailed, previous.isFailedForResume {
                return true
            }
            if selection.statuses.contains(previous.status) {
                return true
            }
            return false
        }
        let rerunSet = Set(keysToRun)
        let reusable = expectedKeys.compactMap { key -> TextToSQLEvalResult? in
            guard expectedSet.contains(key), !rerunSet.contains(key) else { return nil }
            return previousByKey[key]
        }
        return TextToSQLEvalResumePlan(reusableResults: reusable, keysToRun: keysToRun)
    }
}

public struct TextToSQLEvalBudgetLimits: Equatable, Sendable {
    public var maxCloudCostUSD: Decimal?
    public var maxHTTPAttempts: Int?
    public var maxCompletedResults: Int?

    public init(
        maxCloudCostUSD: Decimal? = nil,
        maxHTTPAttempts: Int? = nil,
        maxCompletedResults: Int? = nil
    ) {
        self.maxCloudCostUSD = maxCloudCostUSD
        self.maxHTTPAttempts = maxHTTPAttempts
        self.maxCompletedResults = maxCompletedResults
    }
}

public struct TextToSQLEvalBudgetState: Equatable, Sendable {
    public var limits: TextToSQLEvalBudgetLimits
    public private(set) var cloudCostUSD: Decimal
    public private(set) var httpAttempts: Int
    public private(set) var completedResults: Int

    public init(
        limits: TextToSQLEvalBudgetLimits,
        seedResults: [TextToSQLEvalResult] = []
    ) {
        self.limits = limits
        self.cloudCostUSD = 0
        self.httpAttempts = 0
        self.completedResults = 0
        for result in seedResults {
            record(result)
        }
    }

    public func stopReasonBeforeNextResult(backend: TextToSQLEvalBackend) -> String? {
        if let maxCompletedResults = limits.maxCompletedResults,
            completedResults >= maxCompletedResults
        {
            return "Eval completed-result budget reached (\(completedResults)/\(maxCompletedResults))."
        }
        guard backend == .cloud else { return nil }
        if let maxHTTPAttempts = limits.maxHTTPAttempts,
            httpAttempts >= maxHTTPAttempts
        {
            return "Eval OpenRouter HTTP-attempt budget reached (\(httpAttempts)/\(maxHTTPAttempts))."
        }
        if let maxCloudCostUSD = limits.maxCloudCostUSD,
            cloudCostUSD >= maxCloudCostUSD
        {
            return "Eval estimated cloud-cost budget reached ($\(Self.format(cloudCostUSD))/$\(Self.format(maxCloudCostUSD)))."
        }
        return nil
    }

    public func remainingHTTPAttempts(for backend: TextToSQLEvalBackend) -> Int? {
        guard backend == .cloud, let maxHTTPAttempts = limits.maxHTTPAttempts else {
            return nil
        }
        return Swift.max(0, maxHTTPAttempts - httpAttempts)
    }

    public mutating func record(_ result: TextToSQLEvalResult) {
        if result.status.isCompletedEvaluation {
            completedResults += 1
        }
        guard result.backend == .cloud else { return }
        if let cost = result.metrics.estimatedCloudCostUSD {
            cloudCostUSD += Decimal(cost)
        }
        let attemptCounts = [
            result.metrics.modelCallCount,
            result.metrics.openRouterAgentHTTPAttemptCount,
            result.diagnostics.openRouterAttemptCount,
        ].compactMap { $0 }
        if let attempts = attemptCounts.max() {
            httpAttempts += attempts
        }
    }

    private static func format(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

public struct TextToSQLEvalResumeCompatibilityManifest: Equatable, Sendable {
    public var suiteName: String
    public var suiteVersion: String
    public var suiteFileHash: String
    public var schemaFixtureHashes: [String: String]
    public var model: String?
    public var expectedCanonicalModelID: String?
    public var backendMode: String
    public var cloudAgentMode: String?
    public var schemaAgentClarificationCorrectionMode: String?
    public var schemaAgentIntentCoverageMode: String?
    public var semanticDatabaseEnabled: Bool
    public var scorerSourceHash: String
    public var semanticComparatorSourceHash: String?
    public var setupFixtureHashes: [String: String]?
    public var releaseGateVersion: String?

    public init(
        suiteName: String,
        suiteVersion: String,
        suiteFileHash: String,
        schemaFixtureHashes: [String: String],
        model: String?,
        expectedCanonicalModelID: String? = nil,
        backendMode: String,
        cloudAgentMode: String?,
        schemaAgentClarificationCorrectionMode: String? = nil,
        schemaAgentIntentCoverageMode: String? = nil,
        semanticDatabaseEnabled: Bool,
        scorerSourceHash: String,
        semanticComparatorSourceHash: String?,
        setupFixtureHashes: [String: String]?,
        releaseGateVersion: String?
    ) {
        self.suiteName = suiteName
        self.suiteVersion = suiteVersion
        self.suiteFileHash = suiteFileHash
        self.schemaFixtureHashes = schemaFixtureHashes
        self.model = model
        self.expectedCanonicalModelID = expectedCanonicalModelID
        self.backendMode = backendMode
        self.cloudAgentMode = cloudAgentMode
        self.schemaAgentClarificationCorrectionMode = schemaAgentClarificationCorrectionMode
        self.schemaAgentIntentCoverageMode = schemaAgentIntentCoverageMode
        self.semanticDatabaseEnabled = semanticDatabaseEnabled
        self.scorerSourceHash = scorerSourceHash
        self.semanticComparatorSourceHash = semanticComparatorSourceHash
        self.setupFixtureHashes = setupFixtureHashes
        self.releaseGateVersion = releaseGateVersion
    }
}

public struct TextToSQLEvalResumeCompatibilityIssue: Equatable, Sendable {
    public var field: String
    public var previous: String
    public var current: String

    public init(field: String, previous: String, current: String) {
        self.field = field
        self.previous = previous
        self.current = current
    }
}

public struct TextToSQLEvalResumeCompatibilityError: Error, LocalizedError, Equatable, Sendable {
    public var issues: [TextToSQLEvalResumeCompatibilityIssue]

    public init(issues: [TextToSQLEvalResumeCompatibilityIssue]) {
        self.issues = issues
    }

    public var errorDescription: String? {
        let details = issues.map {
            "\($0.field) changed from \($0.previous) to \($0.current)"
        }
        .joined(separator: "; ")
        return "Cannot resume eval run: \(details)."
    }
}

public enum TextToSQLEvalResumeCompatibility {
    public static func validate(
        previous: TextToSQLEvalResumeCompatibilityManifest,
        current: TextToSQLEvalResumeCompatibilityManifest
    ) throws {
        var issues: [TextToSQLEvalResumeCompatibilityIssue] = []

        compare("suite name", previous.suiteName, current.suiteName, issues: &issues)
        compare("suite version", previous.suiteVersion, current.suiteVersion, issues: &issues)
        compare("suite file hash", previous.suiteFileHash, current.suiteFileHash, issues: &issues)
        compareMatchingHashes(
            "schema fixture hashes",
            previous.schemaFixtureHashes,
            current.schemaFixtureHashes,
            issues: &issues
        )
        compare("model", previous.model ?? "-", current.model ?? "-", issues: &issues)
        compare(
            "expected canonical model",
            previous.expectedCanonicalModelID ?? "-",
            current.expectedCanonicalModelID ?? "-",
            issues: &issues
        )
        compare("backend", previous.backendMode, current.backendMode, issues: &issues)
        compare(
            "cloud agent",
            previous.cloudAgentMode ?? "-",
            current.cloudAgentMode ?? "-",
            issues: &issues
        )
        compare(
            "schema agent clarification correction mode",
            normalizedSchemaAgentClarificationCorrectionMode(previous.schemaAgentClarificationCorrectionMode),
            normalizedSchemaAgentClarificationCorrectionMode(current.schemaAgentClarificationCorrectionMode),
            issues: &issues
        )
        compare(
            "schema agent intent coverage mode",
            normalizedSchemaAgentIntentCoverageMode(previous.schemaAgentIntentCoverageMode),
            normalizedSchemaAgentIntentCoverageMode(current.schemaAgentIntentCoverageMode),
            issues: &issues
        )
        compare(
            "semantic DB",
            String(previous.semanticDatabaseEnabled),
            String(current.semanticDatabaseEnabled),
            issues: &issues
        )
        compare(
            "scorer source hash",
            previous.scorerSourceHash,
            current.scorerSourceHash,
            issues: &issues
        )
        compare(
            "semantic comparator source hash",
            previous.semanticComparatorSourceHash ?? "-",
            current.semanticComparatorSourceHash ?? "-",
            issues: &issues
        )
        compareMatchingHashes(
            "semantic setup fixture hashes",
            previous.setupFixtureHashes ?? [:],
            current.setupFixtureHashes ?? [:],
            issues: &issues
        )

        if previous.releaseGateVersion != nil || current.releaseGateVersion != nil {
            compare(
                "release gate version",
                previous.releaseGateVersion ?? "-",
                current.releaseGateVersion ?? "-",
                issues: &issues
            )
        }

        guard issues.isEmpty else {
            throw TextToSQLEvalResumeCompatibilityError(issues: issues)
        }
    }

    private static func compare(
        _ field: String,
        _ previous: String,
        _ current: String,
        issues: inout [TextToSQLEvalResumeCompatibilityIssue]
    ) {
        guard previous != current else { return }
        issues.append(
            TextToSQLEvalResumeCompatibilityIssue(
                field: field,
                previous: previous,
                current: current
            )
        )
    }

    private static func compareMatchingHashes(
        _ field: String,
        _ previous: [String: String],
        _ current: [String: String],
        issues: inout [TextToSQLEvalResumeCompatibilityIssue]
    ) {
        for key in Set(previous.keys).intersection(current.keys).sorted() {
            compare("\(field)[\(key)]", previous[key] ?? "", current[key] ?? "", issues: &issues)
        }
    }

    private static func normalizedSchemaAgentClarificationCorrectionMode(_ value: String?) -> String {
        value ?? SchemaToolAgentClarificationCorrectionMode.diagnosticsOnly.rawValue
    }

    private static func normalizedSchemaAgentIntentCoverageMode(_ value: String?) -> String {
        value ?? SchemaToolAgentIntentCoverageMode.diagnosticsOnly.rawValue
    }
}

public extension TextToSQLEvalCaseStatus {
    var isProviderBudgetUnavailable: Bool {
        self == .paymentRequired || self == .providerLimit
    }

    var isCompletedEvaluation: Bool {
        notEvaluatedReason == nil
    }

    var notEvaluatedReason: TextToSQLEvalNotEvaluatedReason? {
        switch self {
        case .skippedBudgetLimit:
            return .skippedBudgetLimit
        case .paymentRequired, .providerLimit:
            return .providerBudgetUnavailable
        case .backendUnavailable:
            return .backendUnavailable
        case .passed, .semanticReviewRequired, .semanticEnvironmentUnavailable, .fixtureInvalid,
            .wrongDecision, .invalidSQL, .wrongSchemaObjects, .contextWindowFailure,
            .generationFailure, .evalTimeout, .transportFailure, .parseFailure:
            return nil
        }
    }
}

public extension TextToSQLEvalResult {
    var isFailedForResume: Bool {
        if !status.isCompletedEvaluation { return true }
        if status != .passed { return true }
        if metrics.endToEndPassed == false { return true }
        switch metrics.semanticStatus {
        case .resultMismatch, .candidateExecutionFailure, .goldenFixtureFailure,
            .resultLimitExceeded, .semanticEnvironmentUnavailable, .fixtureInvalid:
            return true
        case .passed, .notApplicable, nil:
            return false
        }
    }
}
