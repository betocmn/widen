import Foundation

public enum SchemaToolAgentSQLIntentCoverageDecision: String, Codable, Equatable, Sendable {
    case covered
    case needsCorrection
    case mustClarify
}

public struct SchemaToolAgentSQLIntentCoverageResult: Equatable, Sendable {
    public var decision: SchemaToolAgentSQLIntentCoverageDecision
    public var reason: String
    public var missingSignals: [String]
    public var unresolvedDecisionKinds: [SchemaToolAgentUnresolvedDecisionKind]
    public var clarificationQuestion: String?
    public var semanticMismatchCategory: String

    public init(
        decision: SchemaToolAgentSQLIntentCoverageDecision,
        reason: String,
        missingSignals: [String] = [],
        unresolvedDecisionKinds: [SchemaToolAgentUnresolvedDecisionKind] = [],
        clarificationQuestion: String? = nil,
        semanticMismatchCategory: String = "unknown mismatch"
    ) {
        self.decision = decision
        self.reason = reason
        self.missingSignals = missingSignals
        self.unresolvedDecisionKinds = unresolvedDecisionKinds
        self.clarificationQuestion = clarificationQuestion
        self.semanticMismatchCategory = semanticMismatchCategory
    }
}

public enum SchemaToolAgentSQLIntentCoveragePolicy {
    public static func evaluate(
        question: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        sql: String
    ) -> SchemaToolAgentSQLIntentCoverageResult {
        let signals = IntentSignals(
            question: question,
            databaseContext: databaseContext,
            evidence: evidence,
            sql: sql
        )

        if signals.hasProtectedMetricAmbiguity {
            return SchemaToolAgentSQLIntentCoverageResult(
                decision: .mustClarify,
                reason: "question contains a metric term that database context does not define",
                unresolvedDecisionKinds: [.metric],
                clarificationQuestion: signals.metricClarificationQuestion,
                semanticMismatchCategory: "missing required filter"
            )
        }

        var missing: [String] = []
        var categories: [String] = []

        for status in signals.statusTokens.sorted() {
            guard signals.evidenceSupportsStatus(status) else { continue }
            if !signals.sqlIncludesStatusPredicate(for: status) {
                missing.append("predicate for \(status)")
                categories.append(status == "active" || status == "verified"
                    ? "wrong status/boolean predicate"
                    : "missing required filter")
            }
        }

        if signals.requiresActiveMembershipFromContext,
            !signals.sqlIncludesActiveMembershipPredicate()
        {
            missing.append("active membership predicate from database context")
            categories.append("wrong status/boolean predicate")
        }

        if let lastSeenDate = signals.activeUserLastSeenAnchor,
            !signals.sqlIncludesColumn("last_seen_at") || !signals.sqlContainsDateLiteral(lastSeenDate)
        {
            missing.append("last_seen_at predicate from database context")
            categories.append("missing anchored date window")
        }

        if signals.requiresSeatUsageActiveMembership {
            if !signals.sqlIncludesAggregateCount {
                missing.append("membership count for seat usage")
                categories.append("missing aggregate")
            }
            if !signals.sqlIncludesActiveMembershipPredicate() {
                missing.append("active membership predicate for seat usage")
                categories.append("wrong status/boolean predicate")
            }
        }

        if signals.requiresAntiJoin, !signals.sqlIncludesAntiJoin {
            missing.append("anti-join or NOT EXISTS for missing rows")
            categories.append("missing anti-join/null filter")
        }

        if signals.requiresAverage {
            if !signals.sqlIncludesAverage {
                missing.append("AVG aggregate")
                categories.append("missing aggregate")
            }
            if signals.requiresFirstResponseDifference,
                !signals.sqlIncludesColumn("created_at") || !signals.sqlIncludesColumn("first_response_at")
            {
                missing.append("created_at and first_response_at for response time")
                categories.append("wrong aggregate")
            }
        }

        if signals.requiresGroupBy, !signals.sqlIncludesGroupBy {
            missing.append("GROUP BY for requested grouping")
            categories.append("missing group by")
        }

        if signals.requiresTopCount {
            if !signals.sqlIncludesAggregateCount {
                missing.append("aggregate count for top/frequent request")
                categories.append("missing aggregate")
            }
            if !signals.sqlIncludesGroupBy {
                missing.append("GROUP BY for top/frequent request")
                categories.append("missing group by")
            }
            if !signals.sqlIncludesDescendingOrder {
                missing.append("descending ORDER BY for top/frequent request")
                categories.append("missing order/limit")
            }
            if !signals.topRequestAllowsAllRows, !signals.sqlIncludesLimit {
                missing.append("LIMIT for top/frequent request")
                categories.append("missing order/limit")
            }
        }

        if let anchor = signals.explicitAnchor {
            if signals.sqlUsesMovingCurrentTime {
                missing.append("explicit date/time anchor instead of moving current time")
                categories.append("moving current-time used for anchored question")
            } else if !signals.sqlContainsAnchor(anchor) {
                missing.append("explicit date/time anchor \(anchor.display)")
                categories.append("missing anchored date window")
            }
        }

        if missing.isEmpty {
            return SchemaToolAgentSQLIntentCoverageResult(
                decision: .covered,
                reason: "terminal SQL covers deterministic intent signals",
                semanticMismatchCategory: "unknown mismatch"
            )
        }

        return SchemaToolAgentSQLIntentCoverageResult(
            decision: .needsCorrection,
            reason: "terminal SQL missed deterministic intent signals",
            missingSignals: Array(Set(missing)).sorted(),
            semanticMismatchCategory: dominantCategory(categories)
        )
    }

    public static func semanticMismatchCategory(
        question: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        sql: String,
        comparatorMismatchCategory: String?
    ) -> String {
        let coverage = evaluate(
            question: question,
            databaseContext: databaseContext,
            evidence: evidence,
            sql: sql
        )
        if coverage.decision == .needsCorrection {
            return coverage.semanticMismatchCategory
        }
        switch comparatorMismatchCategory {
        case "missingCandidateColumn", "unexpectedExtraColumns", "ambiguousCandidateColumn":
            return "wrong projected columns"
        case "orderedRowMismatch":
            return "row order mismatch"
        default:
            return "unknown mismatch"
        }
    }

    private static func dominantCategory(_ categories: [String]) -> String {
        guard !categories.isEmpty else { return "unknown mismatch" }
        let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.first?.key ?? "unknown mismatch"
    }

    private struct IntentSignals {
        var question: String
        var databaseContext: String
        var evidence: OpenRouterSchemaToolEvidenceSummary
        var sql: String

        private var questionTokens: Set<String> { Set(Self.tokens(in: question)) }
        private var contextTokens: Set<String> { Set(Self.tokens(in: databaseContext)) }
        private var combinedTokens: Set<String> { questionTokens.union(contextTokens) }
        private var lowerQuestion: String { question.lowercased() }
        private var lowerContext: String { databaseContext.lowercased() }
        private var lowerSQL: String { sql.lowercased() }
        private var columnNames: Set<String> {
            Set(evidence.exposedColumnIDs.compactMap(Self.lastSQLPathComponent).map { $0.lowercased() })
        }

        var statusTokens: Set<String> {
            combinedTokens.intersection(Self.statusPhraseTokens)
        }

        var hasProtectedMetricAmbiguity: Bool {
            questionTokens.intersection(Self.protectedMetricTerms).isEmpty == false
                && !contextDefinesMetric
        }

        var metricClarificationQuestion: String {
            if questionTokens.contains("healthy") {
                return "Which metric should define healthy accounts?"
            }
            if questionTokens.contains("important") {
                return "Which metric should define important feedback clusters?"
            }
            if questionTokens.contains("win") || questionTokens.contains("wins") {
                return "Which metric should define wins?"
            }
            return "Which metric should define this request?"
        }

        var contextDefinesMetric: Bool {
            let tokens = contextTokens
            return !tokens.intersection(Self.metricDefinitionTokens).isEmpty
                || lowerContext.contains(" means ")
                || lowerContext.contains(" is ")
                || lowerContext.contains(" records ")
                || lowerContext.contains(" count ")
        }

        var requiresActiveMembershipFromContext: Bool {
            lowerContext.contains("active membership")
                || lowerContext.contains("active organization membership")
                || lowerContext.contains("active organization memberships")
        }

        var requiresSeatUsageActiveMembership: Bool {
            lowerContext.contains("seat usage")
                && lowerContext.contains("active")
                && lowerContext.contains("membership")
        }

        var activeUserLastSeenAnchor: String? {
            guard lowerContext.contains("active user") || lowerQuestion.contains("active user") else {
                return nil
            }
            guard lowerContext.contains("last_seen_at") else { return nil }
            return Self.firstDateLiteral(in: databaseContext)
        }

        var requiresAntiJoin: Bool {
            questionTokens.contains("without")
                || questionTokens.contains("never")
                || lowerQuestion.range(of: #"\bno\s+[a-z0-9_]+"#, options: .regularExpression) != nil
        }

        var sqlIncludesAntiJoin: Bool {
            lowerSQL.contains("not exists")
                || (lowerSQL.contains("left join") && lowerSQL.contains(" is null"))
        }

        var requiresAverage: Bool {
            !questionTokens.intersection(["average", "avg", "mean"]).isEmpty
                || !contextTokens.intersection(["average", "avg", "mean"]).isEmpty
        }

        var sqlIncludesAverage: Bool {
            lowerSQL.range(of: #"\bavg\s*\("#, options: .regularExpression) != nil
        }

        var requiresFirstResponseDifference: Bool {
            (lowerQuestion.contains("first-response") || lowerQuestion.contains("first response"))
                && lowerQuestion.contains("time")
                && columnNames.contains("created_at")
                && columnNames.contains("first_response_at")
        }

        var requiresGroupBy: Bool {
            lowerQuestion.contains(" grouped by ")
                || questionTokens.contains("per")
                || (questionTokens.contains("by") && !requiresTopCount)
        }

        var sqlIncludesGroupBy: Bool {
            lowerSQL.contains("group by")
        }

        var requiresTopCount: Bool {
            questionTokens.contains("frequent")
                || questionTokens.contains("top")
                || (questionTokens.contains("most") && !isRecencyRequest)
        }

        var isRecencyRequest: Bool {
            lowerQuestion.contains("most recent")
                || lowerQuestion.contains("latest")
        }

        var topRequestAllowsAllRows: Bool {
            lowerQuestion.contains("all ")
                || lowerQuestion.contains("every ")
        }

        var sqlIncludesAggregateCount: Bool {
            lowerSQL.range(of: #"\b(count|sum|avg|min|max)\s*\("#, options: .regularExpression) != nil
        }

        var sqlIncludesDescendingOrder: Bool {
            lowerSQL.contains("order by") && lowerSQL.contains(" desc")
        }

        var sqlIncludesLimit: Bool {
            lowerSQL.range(of: #"\blimit\s+\d+\b"#, options: .regularExpression) != nil
        }

        var explicitAnchor: ExplicitAnchor? {
            [question, databaseContext]
                .compactMap(Self.firstExplicitAnchor)
                .first
        }

        var sqlUsesMovingCurrentTime: Bool {
            lowerSQL.contains("now()")
                || lowerSQL.contains("current_date")
                || lowerSQL.contains("current_timestamp")
                || lowerSQL.contains("localtimestamp")
        }

        func evidenceSupportsStatus(_ status: String) -> Bool {
            columnNames.contains("status")
                || columnNames.contains("state")
                || columnNames.contains(status)
                || columnNames.contains("is_\(status)")
                || columnNames.contains("\(status)_at")
                || columnNames.contains("\(status)_date")
                || columnNames.contains("\(status)_on")
                || (status == "unresolved" && columnNames.contains("resolved_at"))
                || (status == "active" && columnNames.contains("last_seen_at"))
        }

        func sqlIncludesStatusPredicate(for status: String) -> Bool {
            if columnNames.contains("status") || columnNames.contains("state") {
                if lowerSQL.range(
                    of: #"\b(status|state)\b\s*(=|<>|!=|in|not\s+in|like|is)\b"#,
                    options: .regularExpression
                ) != nil {
                    if status == "unresolved" {
                        return lowerSQL.contains("unresolved")
                            || lowerSQL.contains("resolved")
                            || lowerSQL.contains("open")
                    }
                    return lowerSQL.contains(status)
                }
            }
            if sqlIncludesBooleanPredicate(column: "is_\(status)") { return true }
            if sqlIncludesBooleanPredicate(column: status) { return true }
            if status == "unresolved" {
                return lowerSQL.range(
                    of: #"\bresolved_at\b\s+is\s+null\b"#,
                    options: .regularExpression
                ) != nil
            }
            if sqlIncludesColumn("\(status)_at") || sqlIncludesColumn("\(status)_date") {
                return lowerSQL.range(
                    of: #"\b"# + NSRegularExpression.escapedPattern(for: status) + #"(?:_at|_date|_on)\b\s+is\s+not\s+null\b"#,
                    options: .regularExpression
                ) != nil
            }
            return false
        }

        func sqlIncludesActiveMembershipPredicate() -> Bool {
            sqlIncludesStatusPredicate(for: "active")
                || sqlIncludesBooleanPredicate(column: "is_active")
                || sqlIncludesBooleanPredicate(column: "active")
        }

        func sqlIncludesBooleanPredicate(column: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: column)
            let patterns = [
                #"\b"# + escaped + #"\b\s*=\s*(true|1)\b"#,
                #"\b"# + escaped + #"\b\s+is\s+true\b"#,
                #"\b"# + escaped + #"\b\s+is\s+not\s+false\b"#,
                #"\bwhere\b[\s\S]*\b"# + escaped + #"\b(?!\s*,)"#,
                #"\band\b[\s\S]*\b"# + escaped + #"\b(?!\s*,)"#,
            ]
            return patterns.contains { pattern in
                lowerSQL.range(of: pattern, options: .regularExpression) != nil
            }
        }

        func sqlIncludesColumn(_ column: String) -> Bool {
            lowerSQL.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: column.lowercased()) + #"\b"#,
                options: .regularExpression
            ) != nil
        }

        func sqlContainsDateLiteral(_ date: String) -> Bool {
            lowerSQL.contains(date.lowercased())
        }

        func sqlContainsAnchor(_ anchor: ExplicitAnchor) -> Bool {
            guard lowerSQL.contains(anchor.date) else { return false }
            guard let time = anchor.time else { return true }
            return lowerSQL.contains(time)
                || lowerSQL.contains(time.dropLastSecondsIfZero)
        }

        private static func firstExplicitAnchor(in value: String) -> ExplicitAnchor? {
            guard let match = value.range(
                of: #"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:\s*UTC|Z|[+-]\d{2}:?\d{2})?)?\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            let display = String(value[match])
            let date = String(display.prefix(10)).lowercased()
            let timeMatch = display.range(
                of: #"\d{2}:\d{2}(?::\d{2})?"#,
                options: .regularExpression
            )
            return ExplicitAnchor(
                display: display,
                date: date,
                time: timeMatch.map { String(display[$0]).lowercased() }
            )
        }

        private static func firstDateLiteral(in value: String) -> String? {
            value.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression)
                .map { String(value[$0]).lowercased() }
        }

        private static func tokens(in value: String) -> [String] {
            value
                .replacingOccurrences(
                    of: #"([a-z0-9])([A-Z])"#,
                    with: "$1 $2",
                    options: .regularExpression
                )
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        }

        private static func lastSQLPathComponent(_ value: String) -> String? {
            value.split(separator: ".").last.map(String.init)
        }

        private static let statusPhraseTokens: Set<String> = [
            "active", "failed", "paid", "resolved", "unresolved", "verified",
        ]

        private static let protectedMetricTerms: Set<String> = [
            "best", "healthy", "important", "win", "winner", "wins",
        ]

        private static let metricDefinitionTokens: Set<String> = [
            "count", "counts", "define", "defines", "mean", "means", "metric",
            "record", "records", "revenue", "usage", "win", "wins",
        ]
    }

    private struct ExplicitAnchor: Equatable {
        var display: String
        var date: String
        var time: String?
    }
}

private extension String {
    var dropLastSecondsIfZero: String {
        hasSuffix(":00") ? String(dropLast(3)) : self
    }
}
