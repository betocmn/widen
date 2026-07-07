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

        if signals.requiresScalarCountAggregate,
            !signals.sqlIncludesCountAggregate
        {
            missing.append("COUNT aggregate for how-many request")
            categories.append("wrong aggregate")
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
            let questionProtectedTerms = questionTokens.intersection(Self.protectedMetricTerms)
            let relevantTerms = Self.relatedProtectedMetricTerms(for: questionProtectedTerms)
            guard !contextTokens.intersection(relevantTerms).isEmpty else {
                return false
            }
            return relevantTerms.contains { term in
                let escaped = NSRegularExpression.escapedPattern(for: term)
                let termBeforeDefinition = lowerContext.range(
                    of: #"\b"#
                        + escaped
                        + #"\b[^.!?;\n]{0,40}\b(?:means|is|are|has|have)\b[^.!?;\n]{0,80}\b(?:when|if|where|with|using|status|active|paid|verified|null|true|false|count|counts|revenue|spend|total|usage|=)\b"#,
                    options: .regularExpression
                ) != nil
                let definitionBeforeTerm = lowerContext.range(
                    of: #"\b(?:means|is|are)\b[^.!?;\n]{0,40}\b"#
                        + escaped
                        + #"\b[^.!?;\n]{0,60}\b(?:when|if|where|with|using|status|null|true|false|=)\b"#,
                    options: .regularExpression
                ) != nil
                let conditionBeforeTerm = lowerContext.range(
                    of: #"\b(?:when|if|where|with|using|status|null|true|false|=)\b[^.!?;\n]{0,80}\b(?:means|is|are|counts?\s+as)\b[^.!?;\n]{0,40}\b"#
                        + escaped
                        + #"\b"#,
                    options: .regularExpression
                ) != nil
                let colonDefinition = lowerContext.range(
                    of: #"\b"#
                        + escaped
                        + #"\b\s*:\s*[^.!?;\n]{0,80}\b(?:when|if|where|with|using|status|is|not|null|true|false|count|counts|sum|=)\b"#,
                    options: .regularExpression
                ) != nil
                let termCountDefinition = lowerContext.range(
                    of: #"\b"#
                        + escaped
                        + #"\b\s+(?:count|counts|total|totals)\b[^.!?;\n]{0,80}\b(?:when|if|where|with|using|status|null|true|false|=)\b"#,
                    options: .regularExpression
                ) != nil
                let recordsTermDefinition = lowerContext.range(
                    of: #"\b(?:records?|counts?|represents?|stores?|tracks?|marks?|indicates?|denotes?)\b[^.!?;\n]{0,60}\b(?:one|a|an|1)\s+"#
                        + escaped
                        + #"\b"#,
                    options: .regularExpression
                ) != nil
                let matchesDefinition = termBeforeDefinition || definitionBeforeTerm
                    || conditionBeforeTerm || colonDefinition || termCountDefinition
                    || recordsTermDefinition
                guard matchesDefinition else { return false }
                return !Self.protectedTermAttachesToForeignSubject(
                    term: term,
                    in: lowerContext,
                    questionSubjects: Self.normalizedMetricSubjectTokens(
                        questionProtectedSubjectTokens ?? questionTokens
                    )
                )
            }
        }

        var containsScopedMetricDefinition: Bool {
            let questionProtectedTerms = questionTokens.intersection(Self.protectedMetricTerms)
            guard !questionProtectedTerms.isEmpty else {
                return false
            }
            let rankingApplicable = questionProtectedTerms
                .isSubset(of: Self.rankingApplicableProtectedTerms)
            let relevantTerms = Self.relatedProtectedMetricTerms(for: questionProtectedTerms)
            return Self.sentences(in: lowerContext).contains { sentence in
                let sentenceTokens = Set(Self.tokens(in: sentence))
                let candidateSubjects = Self.contextMetricSubjectCandidates(in: sentence)
                let sentenceSubjectTokens = candidateSubjects.isEmpty
                    ? sentenceTokens
                    : candidateSubjects
                let hasUseAsMetricDefinition = sentence.range(
                    of: #"\buse[sd]?\b[^.!?;\n]{0,60}\b(?:count|counts|revenue|spend|total|usage|win|wins|status|active|paid|verified|null|true|false)\b[^.!?;\n]{0,60}\bas\b[^.!?;\n]{0,40}\bmetric\b"#,
                    options: .regularExpression
                ) != nil
                if hasUseAsMetricDefinition, sharesMetricSubject(with: sentenceSubjectTokens) {
                    return true
                }
                guard rankingApplicable else { return false }
                if !sentenceTokens.intersection(relevantTerms).isEmpty {
                    let hasScopedRankDefinition = sentence.range(
                        of: #"\b(?:rank|ranked|ranking|ranks)\b[^.!?;\n]{0,40}\bby\b[^.!?;\n]{0,80}\b(?:count|counts|revenue|spend|total|usage|win|wins)\b"#,
                        options: .regularExpression
                    ) != nil
                    if hasScopedRankDefinition, sharesMetricSubject(with: sentenceSubjectTokens) {
                        return true
                    }
                }
                let hasMetricCue = sentence.range(
                    of: #"\b(?:metric|ranking|rank|ranked|define|defines|defined)\b"#,
                    options: .regularExpression
                ) != nil
                return hasMetricCue
                    && !sentenceTokens.intersection(Self.concreteMetricDefinitionTokens).isEmpty
                    && sharesMetricSubject(with: sentenceSubjectTokens)
            }
        }

        private static func contextMetricSubjectCandidates(in sentence: String) -> Set<String> {
            let patterns = [
                #"\brank(?:s|ed|ing)?\b\s+(?:the\s+|all\s+|every\s+)?([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)\s+by\b"#,
                #"\b([a-z][a-z-]*)\s+(?:are|is)\s+ranked\b"#,
                #"\bmetric\s+for\s+(?:the\s+|all\s+|every\s+)?([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)"#,
                #"\b([a-z][a-z-]*)\s+ranking\s+metric\b"#,
            ]
            return patterns.reduce(into: Set<String>()) { candidates, pattern in
                candidates.formUnion(subjectTokens(matching: pattern, in: sentence))
            }
        }

        private func sharesMetricSubject(with segmentTokens: Set<String>) -> Bool {
            let subjectTokens = questionProtectedSubjectTokens ?? questionTokens
            if !subjectTokens.intersection(Self.personEntityTokens).isEmpty,
                !segmentTokens.intersection(Self.personEntityTokens).isEmpty
            {
                return true
            }
            return Self.metricSubjectTokenGroups.contains { group in
                !subjectTokens.intersection(group).isEmpty
                    && !segmentTokens.intersection(group).isEmpty
            } || !Self.normalizedMetricSubjectTokens(subjectTokens)
                .intersection(Self.normalizedMetricSubjectTokens(segmentTokens))
                .isEmpty
        }

        private var questionProtectedSubjectTokens: Set<String>? {
            let protectedTerms = questionTokens.intersection(Self.protectedMetricTerms)
            guard !protectedTerms.isEmpty else { return nil }
            let whHeadSubjects = Self.subjectTokens(
                matching: #"^\s*(?:which|what|who)\b(?:\s+(?:are|is))?(?:\s+(?:our|the|all|any|my))?\s+([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)"#,
                in: lowerQuestion
            )
            if !whHeadSubjects.intersection(Self.knownMetricSubjectTokens).isEmpty {
                return whHeadSubjects
            }
            var subjects = Set<String>()
            for term in protectedTerms {
                let escaped = NSRegularExpression.escapedPattern(for: term)
                let patterns = [
                    #"\b"# + escaped + #"\b\s+([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)"#,
                    #"\b([a-z][a-z-]*)\s+(?:are|is)\s+(?:not\s+)?"# + escaped + #"\b"#,
                ]
                for pattern in patterns {
                    subjects.formUnion(Self.subjectTokens(matching: pattern, in: lowerQuestion))
                }
            }
            return subjects.isEmpty ? nil : subjects
        }

        private static func subjectTokens(matching pattern: String, in value: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            var subjects = Set<String>()
            for match in regex.matches(in: value, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: value) else { continue }
                for word in value[captureRange].split(whereSeparator: \.isWhitespace) {
                    let token = String(word)
                    guard token.count > 2, !metricSubjectStopTokens.contains(token) else {
                        continue
                    }
                    subjects.insert(token)
                }
            }
            return subjects
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
            if questionExplicitlyRequestsPersonEmail { return true }
            if questionRequestsScalarPersonAggregate { return false }
            if lowerQuestion.range(
                of: #"\bby\s+(?:country|org|organization|organizations)\b"#,
                options: .regularExpression
            ) != nil, !questionRequestsPersonEntityList, !questionStartsWithPersonNounPhrase {
                return false
            }
            if lowerQuestion.range(
                of: #"\b(?:per|by|each|every)\s+(?:account|accounts|customer|customers|person|people|user|users)\b"#,
                options: .regularExpression
            ) != nil {
                return true
            }
            return lowerQuestion.range(
                of: #"\b(?:find|list|show|get|return|display|give\s+me|which|who|what)\b"#,
                options: .regularExpression
            ) != nil
                || questionStartsWithPersonNounPhrase
                || requiresAntiJoin
                || requiresTopCount
        }

        var questionStartsWithPersonNounPhrase: Bool {
            lowerQuestion.range(
                of: #"^\s*(?:all\s+|every\s+|our\s+|the\s+)?(?:(?!(?:average|avg|count|number|sum|total)\s)[a-z][a-z-]*\s+){0,3}(?:account|accounts|customer|customers|person|people|user|users)\b"#,
                options: .regularExpression
            ) != nil
        }

        var questionExplicitlyRequestsPersonEmail: Bool {
            !questionTokens.intersection(Self.personEntityTokens).isEmpty
                && lowerQuestion.range(
                    of: #"\b(?:e-?mail|e-?mails)\b"#,
                    options: .regularExpression
                ) != nil
        }

        var questionRequestsScalarPersonAggregate: Bool {
            let groupsByPersonEntity = lowerQuestion.range(
                of: #"\b(?:per|by|each|every)\s+(?:account|accounts|customer|customers|person|people|user|users)\b"#,
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
                of: #"\btop[-\s]+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[-\s]+(?:one|two|three|four|five|six|seven|eight|nine))?)\b"#,
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
                    of: #"(^|\b(?:find|list|rank|return|show|get|display|give\s+me)\s+)(?:all|every)\s+(?:of\s+(?:the\s+)?|the\s+)?(?!time\b|day\b|week\b|month\b|quarter\b|year\b|date\b|period\b|range\b)[a-z][a-z0-9]*(?:\s+[a-z][a-z0-9]*){0,2}\b"#,
                    options: .regularExpression
                ) != nil
        }

        var requiresScalarCountAggregate: Bool {
            guard !questionRequestsPersonEntityResult else { return false }
            return lowerQuestion.range(
                of: #"\bhow\s+many\s+(?!days?\b|weeks?\b|months?\b|quarters?\b|years?\b|hours?\b|minutes?\b|seconds?\b)"#,
                options: .regularExpression
            ) != nil
        }

        var sqlIncludesCountAggregate: Bool {
            let expressions = selectExpressions
            guard !expressions.isEmpty else {
                return lowerSQL.range(of: #"\bcount\s*\("#, options: .regularExpression) != nil
            }
            return expressions.allSatisfy { expression in
                expression.range(
                    of: #"^\s*(?:\(\s*select\s+)?count\s*\("#,
                    options: .regularExpression
                ) != nil
                    && expression.range(of: #"\bover\s*\("#, options: .regularExpression) == nil
            }
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
                let positiveValues: Set<String> = status == "unresolved"
                    ? ["unresolved", "open"]
                    : [status]
                let negativeValues: Set<String> = status == "unresolved" ? ["resolved"] : []
                let predicateValueMatches = sqlStatusPredicateComparisons.contains { comparison in
                    comparison.matchesStatus(
                        positiveValues: positiveValues,
                        negativeValues: negativeValues
                    )
                }
                if predicateValueMatches { return true }
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

        private var sqlStatusPredicateComparisons: [SQLStatusPredicateComparison] {
            guard let regex = try? NSRegularExpression(
                pattern: #"(?:\b(?:lower|upper|trim|btrim)\s*\(\s*)?(?:\b[a-z_][a-z0-9_]*\s*\.\s*)?"?\b(?:status|state)\b"?(?:\s*::\s*[a-z_][a-z0-9_]*)?(?:\s*\))?\s*(=|<>|!=|\bnot\s+in\b|\bin\b|\blike\b|\bis\b)\s*('[^']*'|"[^"]*"|\([^)]*\)|(?:any|all)\s*\([^)]*\)|[a-z0-9_]+)"#
            ) else { return [] }
            let range = NSRange(lowerSQL.startIndex..<lowerSQL.endIndex, in: lowerSQL)
            return regex.matches(in: lowerSQL, range: range).compactMap { match in
                guard let operatorRange = Range(match.range(at: 1), in: lowerSQL),
                    let valueRange = Range(match.range(at: 2), in: lowerSQL)
                else {
                    return nil
                }
                return SQLStatusPredicateComparison(
                    operatorToken: Self.normalizedSQLComparisonOperator(String(lowerSQL[operatorRange])),
                    values: Self.normalizedStatusPredicateValues(from: String(lowerSQL[valueRange]))
                )
            }
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
            let matches = explicitAnchorMatches(in: value)
            let evaluationTimeAnchor = matches.first { match in
                contextAnchorPhraseApplies(in: value, dateRange: match.range, tier: .evaluationTime)
            }?.anchor
            if let evaluationTimeAnchor { return evaluationTimeAnchor }
            return matches.first { match in
                contextAnchorPhraseApplies(in: value, dateRange: match.range, tier: .windowBound)
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

        private enum ContextAnchorTier {
            case evaluationTime
            case windowBound
        }

        private static func contextAnchorPhraseApplies(
            in value: String,
            dateRange: Range<String.Index>,
            tier: ContextAnchorTier
        ) -> Bool {
            let prefixStart = value.index(
                dateRange.lowerBound,
                offsetBy: -min(72, value.distance(from: value.startIndex, to: dateRange.lowerBound)),
                limitedBy: value.startIndex
            ) ?? value.startIndex
            let maxSuffixEnd = value.index(
                dateRange.upperBound,
                offsetBy: min(32, value.distance(from: dateRange.upperBound, to: value.endIndex)),
                limitedBy: value.endIndex
            ) ?? value.endIndex
            let suffixEnd = value[dateRange.upperBound..<maxSuffixEnd]
                .firstIndex { ".!?;\n".contains($0) } ?? maxSuffixEnd
            let prefix = String(value[prefixStart..<dateRange.lowerBound]).lowercased()
            let suffix = String(value[dateRange.upperBound..<suffixEnd]).lowercased()
            let prefixAnchorPatterns: [String]
            let suffixAnchorPatterns: [String]
            switch tier {
            case .evaluationTime:
                prefixAnchorPatterns = [
                    #"\bas[\s-]+of(?:\s+the)?\b[\s,:=\-]*$"#,
                    #"\brelative\s+to\b[\s,:=\-]*$"#,
                    #"\bcurrent\s+date\b(?:\s+(?:for|of|in)\b[^.!?;\n]{0,30})?(?:\s+is)?[\s,:=\-]*$"#,
                    #"\btoday(?:\s+is)?\b[\s,:=\-]*$"#,
                    #"\banchor(?:\s+date)?(?:\s+(?:is|as))?\b[\s,:=\-]*$"#,
                    #"\buse\s+(?:the\s+)?(?:date\s+)?$"#,
                ]
                suffixAnchorPatterns = [
                    #"^[\s,)\-]*as\s+(?:the\s+)?current\s+date\b"#,
                    #"^[\s,)\-]*as\s+today\b"#,
                    #"^[\s,)\-]*(?:as|is)\s+(?:the\s+)?(?:evaluation\s+)?anchor(?:\s+date)?\b"#,
                    #"^[\s,)\-]*is\s+(?:the\s+)?current\s+date\b"#,
                    #"^[\s,)\-]*(?:is\s+)?today\b"#,
                ]
            case .windowBound:
                prefixAnchorPatterns = [
                    #"\bthrough\b[\s,:=\-]*$"#,
                    #"\buntil\b[\s,:=\-]*$"#,
                    #"\bstarting(?:\s+(?:on|from))?\b[\s,:=\-]*$"#,
                    #"\bstart\s+date(?:\s+is)?\b[\s,:=\-]*$"#,
                    #"\bon\s+or\s+after\b[\s,:=\-]*$"#,
                    #"\b(?:reporting\s+)?window\s+ending\s*$"#,
                ]
                suffixAnchorPatterns = []
            }
            return prefixAnchorPatterns.contains {
                prefix.range(of: $0, options: .regularExpression) != nil
            }
                || suffixAnchorPatterns.contains {
                    suffix.range(of: $0, options: .regularExpression) != nil
                }
        }

        private static func normalizedSQLComparisonOperator(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static func normalizedStatusPredicateValues(from value: String) -> [String] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueBody: String
            if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
                valueBody = String(trimmed.dropFirst().dropLast())
            } else {
                valueBody = trimmed
            }
            guard let regex = try? NSRegularExpression(
                pattern: #"'([^']*)'|"([^"]*)"|([a-z0-9_%.-]+)"#
            ) else { return [] }
            let range = NSRange(valueBody.startIndex..<valueBody.endIndex, in: valueBody)
            return regex.matches(in: valueBody, range: range).flatMap { match -> [String] in
                for captureIndex in 1...3 {
                    guard match.range(at: captureIndex).location != NSNotFound,
                        let captureRange = Range(match.range(at: captureIndex), in: valueBody)
                    else {
                        continue
                    }
                    let normalized = String(valueBody[captureRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !normalized.isEmpty else { return [] }
                    if normalized.hasPrefix("{"), normalized.hasSuffix("}") {
                        return normalized.dropFirst().dropLast()
                            .split(separator: ",")
                            .map {
                                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                            }
                            .filter { !$0.isEmpty }
                    }
                    return [normalized]
                }
                return []
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

        private static func sentences(in value: String) -> [String] {
            var sentences: [String] = []
            var current = ""
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                let next = value.index(after: index)
                let isPeriodInsideIdentifier = character == "."
                    && next < value.endIndex
                    && !value[next].isWhitespace
                if "!?;\n".contains(character) || (character == "." && !isPeriodInsideIdentifier) {
                    sentences.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
                index = next
            }
            sentences.append(current)
            return sentences.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
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

        private static let rankingApplicableProtectedTerms: Set<String> = [
            "best", "important", "win", "winner", "wins",
        ]

        private static let protectedMetricTermFamilies: [Set<String>] = [
            ["best"],
            ["healthy", "health"],
            ["important", "importance"],
            ["win", "winner", "wins"],
        ]

        private static func protectedTermAttachesToForeignSubject(
            term: String,
            in context: String,
            questionSubjects: Set<String>
        ) -> Bool {
            guard !questionSubjects.isEmpty else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let patterns = [
                #"\b"# + escaped + #"\b\s+([a-z][a-z0-9_-]*(?:\s+[a-z][a-z0-9_-]*){0,2})"#,
                #"\b([a-z][a-z-]*)\s+(?:are|is)\s+(?:not\s+)?"# + escaped + #"\b"#,
            ]
            let range = NSRange(context.startIndex..<context.endIndex, in: context)
            let attachedSubjects = patterns.flatMap { pattern -> [String] in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                return regex.matches(in: context, range: range)
                    .flatMap { match -> [String] in
                        guard let captureRange = Range(match.range(at: 1), in: context) else {
                            return []
                        }
                        var nounPhraseTokens: [String] = []
                        for word in context[captureRange].split(whereSeparator: \.isWhitespace) {
                            let token = String(word)
                            guard token.count > 2, !metricSubjectStopTokens.contains(token) else {
                                break
                            }
                            nounPhraseTokens.append(normalizedMetricSubjectToken(token))
                        }
                        return nounPhraseTokens
                    }
            }
            guard !attachedSubjects.isEmpty else { return false }
            return questionSubjects.isDisjoint(with: attachedSubjects)
        }

        private static func relatedProtectedMetricTerms(for terms: Set<String>) -> Set<String> {
            terms.reduce(into: Set<String>()) { related, term in
                related.formUnion(
                    Self.protectedMetricTermFamilies.first { $0.contains(term) } ?? [term]
                )
            }
        }

        private static let metricDefinitionTokens: Set<String> = [
            "count", "counts", "define", "defines", "mean", "means", "metric",
            "rank", "ranked", "ranking", "ranks", "record", "records", "revenue",
            "spend", "total", "usage", "win", "wins",
        ]

        private static let concreteMetricDefinitionTokens: Set<String> = [
            "count", "counts", "revenue", "spend", "total", "usage", "win",
            "wins",
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

        private static let knownMetricSubjectTokens: Set<String> = personEntityTokens
            .union(metricSubjectTokenGroups.reduce(into: Set<String>()) { $0.formUnion($1) })

        private static let metricSubjectStopTokens: Set<String> = Set([
            "about", "after", "all", "also", "an", "and", "any", "are", "as",
            "at", "be", "before", "by", "can", "current", "date", "dates",
            "day", "days", "each", "every", "find", "first", "five", "for",
            "four", "from", "has", "have", "highest", "in", "include",
            "including", "into", "is", "last", "least", "list", "lowest",
            "month", "months", "most", "next", "one", "our", "past",
            "period", "periods", "previous", "prior", "quarter", "quarters",
            "rank", "recent", "return", "show", "that", "the", "their",
            "these", "this", "those", "three", "time", "times", "to",
            "today", "top", "two", "use", "using", "week", "weeks", "what",
            "when", "where", "which", "who", "with", "year", "years",
            "yesterday",
        ])
        .union(statusPhraseTokens)
        .union(protectedMetricTerms)
        .union(metricDefinitionTokens)

        private struct SQLStatusPredicateComparison {
            var operatorToken: String
            var values: [String]

            func matchesStatus(
                positiveValues: Set<String>,
                negativeValues: Set<String>
            ) -> Bool {
                switch operatorToken {
                case "=", "is", "in":
                    return values.contains { positiveValues.contains($0) }
                case "like":
                    return values.contains { value in
                        positiveValues.contains(value)
                            || positiveValues.contains(
                                value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
                            )
                    }
                case "!=", "<>":
                    return values.contains { negativeValues.contains($0) }
                case "not in":
                    return values.contains { negativeValues.contains($0) }
                default:
                    return false
                }
            }
        }
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
