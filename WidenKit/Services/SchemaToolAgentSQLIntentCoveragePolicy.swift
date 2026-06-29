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

        if signals.requiresPersonEmailProjection,
            !signals.sqlIncludesColumn("email")
        {
            missing.append("email projection for person/customer entity")
            categories.append("wrong projected columns")
        }

        if signals.requiresGroupedPersonMetricEmailLabel,
            signals.sqlIncludesColumn("name"),
            !signals.questionAsksForName
        {
            missing.append("use email instead of name for grouped person/customer metric")
            categories.append("wrong projected columns")
        }

        if signals.requiresCentsUnitPreservation {
            if signals.sqlScalesCentsToCurrency {
                missing.append("preserve cents unit instead of dividing by 100")
                categories.append("wrong aggregate")
            }
            if !signals.sqlHasCentsAggregateAlias {
                missing.append("cents-valued aggregate alias")
                categories.append("wrong projected columns")
            }
        }

        if signals.requiresActiveExpiringStatusPredicate,
            !signals.sqlIncludesStatusPredicate(for: "active")
        {
            missing.append("active status predicate for expiring rows")
            categories.append("missing required filter")
        }

        if signals.requiresCountAlias, !signals.sqlHasCountAlias {
            missing.append("count aggregate alias containing count")
            categories.append("wrong projected columns")
        }

        if signals.requiresFeedbackCountAlias, !signals.sqlHasFeedbackCountAlias {
            missing.append("feedback count alias")
            categories.append("wrong projected columns")
        }

        if signals.requiresSeatCountAlias, !signals.sqlHasSeatCountAlias {
            missing.append("seat count alias such as used_seats or seat_count")
            categories.append("wrong projected columns")
        }

        for projection in signals.unrequestedProjectionColumns {
            missing.append("remove unrequested projection \(projection)")
            categories.append("wrong projected columns")
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
        private var selectExpressions: [String] {
            Self.topLevelSelectExpressions(in: lowerSQL)
        }

        var statusTokens: Set<String> {
            combinedTokens.intersection(Self.statusPhraseTokens)
        }

        var questionAsksForName: Bool {
            questionTokens.contains("name") || questionTokens.contains("named")
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
            containsProtectedMetricDefinition || containsScopedMetricDefinition
        }

        var containsProtectedMetricDefinition: Bool {
            guard !contextTokens.intersection(Self.protectedMetricTerms).isEmpty else {
                return false
            }
            return Self.protectedMetricTerms.contains { term in
                let escaped = NSRegularExpression.escapedPattern(for: term)
                let termBeforeDefinition = lowerContext.range(
                    of: #"\b"#
                        + escaped
                        + #"\b[^.!?;\n]{0,40}\b(?:means|is|are)\b[^.!?;\n]{0,80}\b(?:when|if|where|with|using|status|active|paid|verified|=)\b"#,
                    options: .regularExpression
                ) != nil
                let definitionBeforeTerm = lowerContext.range(
                    of: #"\b(?:means|is|are)\b[^.!?;\n]{0,40}\b"#
                        + escaped
                        + #"\b[^.!?;\n]{0,60}\b(?:when|if|where|with|using|status|=)\b"#,
                    options: .regularExpression
                ) != nil
                return termBeforeDefinition || definitionBeforeTerm
            }
        }

        var containsScopedMetricDefinition: Bool {
            guard contextTokens.intersection(Self.protectedMetricTerms).isEmpty else {
                return false
            }
            let hasMetricCue = lowerContext.range(
                of: #"\b(?:metric|ranking|rank|ranked|define|defines|defined)\b"#,
                options: .regularExpression
            ) != nil
            return hasMetricCue
                && !contextTokens.intersection(Self.metricDefinitionTokens).isEmpty
                && questionAndContextShareMetricSubject
        }

        var questionAndContextShareMetricSubject: Bool {
            if !questionTokens.intersection(Self.personEntityTokens).isEmpty,
                !contextTokens.intersection(Self.personEntityTokens).isEmpty
            {
                return true
            }
            return Self.metricSubjectTokenGroups.contains { group in
                !questionTokens.intersection(group).isEmpty
                    && !contextTokens.intersection(group).isEmpty
            } || !Self.normalizedMetricSubjectTokens(questionTokens)
                .intersection(Self.normalizedMetricSubjectTokens(contextTokens))
                .isEmpty
        }

        var questionRequestsPersonEntityList: Bool {
            !questionTokens.intersection(Self.personEntityTokens).isEmpty
                && lowerQuestion.range(
                    of: #"\b(?:find|list|which|who)\b"#,
                    options: .regularExpression
                ) != nil
                || lowerQuestion.range(
                    of: #"\bshow\s+(?:all\s+|every\s+|the\s+)?(?:account|accounts|customer|customers|person|people|user|users)\b"#,
                    options: .regularExpression
                ) != nil
        }

        var requiresPersonEmailProjection: Bool {
            columnNames.contains("email")
                && !questionTokens.intersection(Self.personEntityTokens).isEmpty
                && questionRequestsPersonEntityResult
        }

        var requiresGroupedPersonMetricEmailLabel: Bool {
            requiresPersonEmailProjection
                && sqlIncludesAggregateCountOrSum
                && sqlIncludesGroupBy
        }

        var questionRequestsPersonEntityResult: Bool {
            if questionRequestsScalarPersonAggregate { return false }
            if lowerQuestion.range(
                of: #"\bby\s+(?:country|org|organization|organizations)\b"#,
                options: .regularExpression
            ) != nil {
                return false
            }
            if lowerQuestion.range(
                of: #"\b(?:per|by)\s+(?:account|accounts|customer|customers|person|people|user|users)\b"#,
                options: .regularExpression
            ) != nil {
                return true
            }
            return lowerQuestion.range(
                of: #"\b(?:find|list|show|which|who)\b"#,
                options: .regularExpression
            ) != nil || requiresAntiJoin
        }

        var questionRequestsScalarPersonAggregate: Bool {
            let groupsByPersonEntity = lowerQuestion.range(
                of: #"\b(?:per|by)\s+(?:account|accounts|customer|customers|person|people|user|users)\b"#,
                options: .regularExpression
            ) != nil
            let countIsEntityAttribute = lowerQuestion.range(
                of: #"\b(?:with|including|and)\s+(?:their\s+)?[a-z0-9_\s-]{0,40}\b(?:count|counts)\b"#,
                options: .regularExpression
            ) != nil
            return (lowerQuestion.contains("how many") && !groupsByPersonEntity)
                || (questionTokens.contains("count")
                    && !questionTokens.contains("by")
                    && !questionTokens.contains("per")
                    && !countIsEntityAttribute
                    && !questionRequestsPersonEntityList)
        }

        var requiresCentsUnitPreservation: Bool {
            let mentionsMoneyMetric = !questionTokens.intersection(Self.moneyMetricTokens).isEmpty
                || !contextTokens.intersection(Self.moneyMetricTokens).isEmpty
            return mentionsMoneyMetric
                && columnNames.contains { $0.hasSuffix("_cents") }
                && sqlAggregatesCentsColumn
                && !combinedTokens.contains("dollars")
                && !combinedTokens.contains("usd")
        }

        var sqlAggregatesCentsColumn: Bool {
            lowerSQL.range(
                of: #"\b(sum|avg)\s*\([^)]*_cents\b"#,
                options: .regularExpression
            ) != nil
        }

        var sqlScalesCentsToCurrency: Bool {
            lowerSQL.range(of: #"/\s*100(?:\.0)?\b"#, options: .regularExpression) != nil
        }

        var sqlHasCentsAggregateAlias: Bool {
            lowerSQL.range(
                of: #"\b(sum|avg)\s*\([^)]*_cents[^)]*\)[^,]*\bas\s+\"?[a-z0-9_]*cents\"?\b"#,
                options: .regularExpression
            ) != nil
        }

        var requiresCountAlias: Bool {
            questionTokens.contains("count")
                || questionTokens.contains("frequent")
        }

        var sqlHasCountAlias: Bool {
            lowerSQL.range(
                of: #"\bcount\s*\([^)]*\)\s+as\s+\"?[a-z0-9_]*count[a-z0-9_]*\"?\b"#,
                options: .regularExpression
            ) != nil
        }

        var requiresFeedbackCountAlias: Bool {
            questionTokens.contains("feedback")
                && questionTokens.contains("frequent")
                && lowerSQL.range(of: #"\bcount\s*\("#, options: .regularExpression) != nil
        }

        var sqlHasFeedbackCountAlias: Bool {
            lowerSQL.range(
                of: #"\bcount\s*\([^)]*\)\s+as\s+\"?(?:feedback_count|count)\"?\b"#,
                options: .regularExpression
            ) != nil
        }

        var requiresSeatCountAlias: Bool {
            questionTokens.contains("seats")
                && sqlIncludesAggregateCount
        }

        var sqlHasSeatCountAlias: Bool {
            lowerSQL.range(
                of: #"\bcount\s*\([^)]*\)\s+as\s+\"?(?:used_seats|[a-z0-9_]*seat_count[a-z0-9_]*)\"?\b"#,
                options: .regularExpression
            ) != nil
        }

        var unrequestedProjectionColumns: [String] {
            var unrequested: [String] = []
            if isAnchoredExpiringEntityList,
                selectListIncludesColumn("created_at"),
                !questionTokens.contains("created")
            {
                unrequested.append("created_at")
            }
            if isAnchoredExpiringEntityList,
                selectListIncludesColumn("name"),
                !questionAsksForName
            {
                unrequested.append("name")
            }
            if isAverageByCountryOnly {
                for column in ["id", "name", "email"] where selectListIncludesColumn(column) {
                    unrequested.append(column)
                }
            }
            if isNullableMissingRelationshipList,
                selectListIncludesColumn("cluster_id"),
                !lowerQuestion.contains("cluster id")
            {
                unrequested.append("cluster_id")
            }
            return unrequested
        }

        var isAnchoredExpiringEntityList: Bool {
            questionTokens.contains("expiring")
                && explicitAnchor != nil
                && columnNames.contains("expires_at")
        }

        var requiresActiveExpiringStatusPredicate: Bool {
            isAnchoredExpiringEntityList && columnNames.contains("status")
        }

        var isAverageByCountryOnly: Bool {
            requiresAverage
                && questionTokens.contains("country")
                && columnNames.contains("country")
                && selectListIncludesColumn("country")
        }

        var isNullableMissingRelationshipList: Bool {
            requiresAntiJoin
                && questionTokens.contains("cluster")
                && columnNames.contains("cluster_id")
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
                || lowerSQL.range(
                    of: #"\b[a-z0-9_]*_id\b\s+is\s+null\b"#,
                    options: .regularExpression
                ) != nil
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

        var questionRequestsExplicitTopN: Bool {
            lowerQuestion.range(
                of: #"\btop\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
                options: .regularExpression
            ) != nil
        }

        var topRequestAllowsAllRows: Bool {
            if lowerQuestion.range(
                of: #"\bwithout\s+(?:a\s+)?limit\b"#,
                options: .regularExpression
            ) != nil {
                return true
            }
            if questionRequestsExplicitTopN {
                return false
            }
            return lowerQuestion.range(
                of: #"\b(?:all|every)\s+(?:rows?|records?|results?)\b"#,
                options: .regularExpression
            ) != nil
                || lowerQuestion.range(
                    of: #"(^|\b(?:find|list|rank|return|show)\s+)(?:all|every)\s+(?!time\b|day\b|week\b|month\b|quarter\b|year\b|date\b|period\b|range\b)[a-z][a-z0-9]*(?:\s+[a-z][a-z0-9]*){0,2}\b"#,
                    options: .regularExpression
                ) != nil
        }

        var sqlIncludesAggregateCount: Bool {
            lowerSQL.range(of: #"\b(count|sum|avg|min|max)\s*\("#, options: .regularExpression) != nil
        }

        var sqlIncludesAggregateCountOrSum: Bool {
            lowerSQL.range(of: #"\b(count|sum)\s*\("#, options: .regularExpression) != nil
        }

        var sqlIncludesDescendingOrder: Bool {
            lowerSQL.contains("order by") && lowerSQL.contains(" desc")
        }

        var sqlIncludesLimit: Bool {
            lowerSQL.range(of: #"\blimit\s+\d+\b"#, options: .regularExpression) != nil
        }

        var explicitAnchor: ExplicitAnchor? {
            Self.firstExplicitAnchor(in: question)
                ?? Self.firstContextExplicitAnchor(in: databaseContext)
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
                    of: #"(?:\b[a-z_][a-z0-9_]*\s*\.\s*)?"?\b(status|state)\b"?\s*(?:=|<>|!=|\bnot\s+in\b|\bin\b|\blike\b|\bis\b)"#,
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

        func selectListIncludesColumn(_ column: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: column.lowercased())
            return selectExpressions.contains { expression in
                expression.range(of: #"\b"# + escaped + #"\b"#, options: .regularExpression) != nil
            }
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
            explicitAnchorMatches(in: value).first?.anchor
        }

        private static func firstContextExplicitAnchor(in value: String) -> ExplicitAnchor? {
            explicitAnchorMatches(in: value).first { match in
                contextAnchorPhraseApplies(in: value, dateRange: match.range)
            }?.anchor
        }

        private static func explicitAnchorMatches(
            in value: String
        ) -> [(anchor: ExplicitAnchor, range: Range<String.Index>)] {
            guard let regex = try? NSRegularExpression(
                pattern: #"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:\s*UTC|Z|[+-]\d{2}:?\d{2})?)?\b"#,
                options: [.caseInsensitive]
            ) else { return [] }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.matches(in: value, range: range).compactMap { match in
                guard let valueRange = Range(match.range, in: value) else { return nil }
                let display = String(value[valueRange])
                let date = String(display.prefix(10)).lowercased()
                let timeMatch = display.range(
                    of: #"\d{2}:\d{2}(?::\d{2})?"#,
                    options: .regularExpression
                )
                return (
                    ExplicitAnchor(
                        display: display,
                        date: date,
                        time: timeMatch.map { String(display[$0]).lowercased() }
                    ),
                    valueRange
                )
            }
        }

        private static func contextAnchorPhraseApplies(
            in value: String,
            dateRange: Range<String.Index>
        ) -> Bool {
            let prefixStart = value.index(
                dateRange.lowerBound,
                offsetBy: -min(72, value.distance(from: value.startIndex, to: dateRange.lowerBound)),
                limitedBy: value.startIndex
            ) ?? value.startIndex
            let suffixEnd = value.index(
                dateRange.upperBound,
                offsetBy: min(32, value.distance(from: dateRange.upperBound, to: value.endIndex)),
                limitedBy: value.endIndex
            ) ?? value.endIndex
            let prefix = String(value[prefixStart..<dateRange.lowerBound]).lowercased()
            let suffix = String(value[dateRange.upperBound..<suffixEnd]).lowercased()
            let prefixAnchorPatterns = [
                #"\bas\s+of\b"#,
                #"\bcurrent\s+date(?:\s+is)?\b"#,
                #"\btoday(?:\s+is)?\b"#,
                #"\bstarting\b"#,
                #"\bstart\s+date\b"#,
                #"\bon\s+or\s+after\b"#,
                #"\b(?:reporting\s+)?window\s+ending\s*$"#,
                #"\banchor(?:\s+date)?\b"#,
                #"\buse\s+(?:the\s+)?(?:date\s+)?$"#,
            ]
            let suffixAnchorPatterns = [
                #"\bas\s+(?:the\s+)?current\s+date\b"#,
                #"\bas\s+today\b"#,
                #"\bis\s+(?:the\s+)?current\s+date\b"#,
                #"\btoday\b"#,
            ]
            return prefixAnchorPatterns.contains {
                prefix.range(of: $0, options: .regularExpression) != nil
            }
                || suffixAnchorPatterns.contains {
                    suffix.range(of: $0, options: .regularExpression) != nil
                }
        }

        private static func firstDateLiteral(in value: String) -> String? {
            value.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression)
                .map { String(value[$0]).lowercased() }
        }

        private static func topLevelSelectExpressions(in sql: String) -> [String] {
            guard let selectRange = sql.range(of: #"\bselect\b"#, options: .regularExpression) else {
                return []
            }
            var index = selectRange.upperBound
            var depth = 0
            var quote: Character?
            var fromStart: String.Index?
            while index < sql.endIndex {
                let character = sql[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = sql.index(after: index)
                    continue
                }
                if character == "'" || character == "\"" {
                    quote = character
                    index = sql.index(after: index)
                    continue
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if depth == 0,
                    sql[index...].range(of: #"^\s+from\b"#, options: .regularExpression) != nil
                {
                    fromStart = index
                    break
                }
                index = sql.index(after: index)
            }
            guard let fromStart else { return [] }
            let selectList = String(sql[selectRange.upperBound..<fromStart])
            return splitTopLevelCommaList(selectList)
        }

        private static func splitTopLevelCommaList(_ value: String) -> [String] {
            var expressions: [String] = []
            var start = value.startIndex
            var index = value.startIndex
            var depth = 0
            var quote: Character?
            while index < value.endIndex {
                let character = value[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = value.index(after: index)
                    continue
                }
                if character == "'" || character == "\"" {
                    quote = character
                    index = value.index(after: index)
                    continue
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if character == ",", depth == 0 {
                    expressions.append(String(value[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = value.index(after: index)
                }
                index = value.index(after: index)
            }
            expressions.append(String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
            return expressions.filter { !$0.isEmpty }
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

        private static func normalizedMetricSubjectTokens(_ tokens: Set<String>) -> Set<String> {
            tokens.reduce(into: Set<String>()) { normalizedTokens, token in
                guard token.count > 2, !Self.metricSubjectStopTokens.contains(token) else {
                    return
                }
                normalizedTokens.insert(Self.normalizedMetricSubjectToken(token))
            }
        }

        private static func normalizedMetricSubjectToken(_ token: String) -> String {
            if token.count > 4, token.hasSuffix("ies") {
                return String(token.dropLast(3)) + "y"
            }
            if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") {
                return String(token.dropLast())
            }
            return token
        }

        private static let statusPhraseTokens: Set<String> = [
            "active", "failed", "paid", "resolved", "unresolved", "verified",
        ]

        private static let protectedMetricTerms: Set<String> = [
            "best", "healthy", "important", "win", "winner", "wins",
        ]

        private static let metricDefinitionTokens: Set<String> = [
            "count", "counts", "define", "defines", "mean", "means", "metric",
            "rank", "ranked", "ranking", "ranks", "record", "records", "revenue",
            "spend", "total", "usage", "win", "wins",
        ]

        private static let personEntityTokens: Set<String> = [
            "account", "accounts", "customer", "customers", "person", "people",
            "user", "users",
        ]

        private static let moneyMetricTokens: Set<String> = [
            "amount", "average", "avg", "order", "orders", "paid", "revenue",
            "spend", "total", "value",
        ]

        private static let metricSubjectTokenGroups: [Set<String>] = [
            ["account", "accounts", "customer", "customers", "person", "people", "user", "users"],
            ["cluster", "clusters", "feedback"],
            ["tool", "tools"],
            ["ticket", "tickets"],
            ["subscription", "subscriptions"],
        ]

        private static let metricSubjectStopTokens: Set<String> = Set([
            "about", "after", "all", "also", "an", "and", "any", "are", "as",
            "at", "be", "before", "by", "can", "each", "every", "find",
            "for", "from", "has", "have", "highest", "in", "include",
            "including", "into", "is", "least", "list", "lowest", "most",
            "one", "our", "rank", "return", "show", "that", "the", "their",
            "these", "this", "those", "to", "top", "use", "using", "what",
            "when", "where", "which", "who", "with",
        ])
        .union(statusPhraseTokens)
        .union(protectedMetricTerms)
        .union(metricDefinitionTokens)
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
