import Foundation

public enum SchemaToolAgentClarificationDecision: String, Codable, Equatable, Sendable {
    case acceptableAmbiguity
    case genericClarification
    case asksForAlreadyKnownEvidence
    case shouldAnswerWithSQL
    case insufficientSchemaEvidence
    case malformedClarification
}

public enum SchemaToolAgentUnresolvedDecisionKind: String, Codable, Equatable, Hashable, Sendable {
    case metric
    case relationship
    case statusOrFilter
    case timeField
    case eventTable
}

public struct SchemaToolAgentClarificationPolicyResult: Equatable, Sendable {
    public var decision: SchemaToolAgentClarificationDecision
    public var reason: String
    public var databaseContextFactsUsed: [String]
    public var evidenceSufficientForSQL: Bool
    public var unresolvedDecisionKinds: [SchemaToolAgentUnresolvedDecisionKind]

    public init(
        decision: SchemaToolAgentClarificationDecision,
        reason: String,
        databaseContextFactsUsed: [String] = [],
        evidenceSufficientForSQL: Bool = false,
        unresolvedDecisionKinds: [SchemaToolAgentUnresolvedDecisionKind] = []
    ) {
        self.decision = decision
        self.reason = reason
        self.databaseContextFactsUsed = databaseContextFactsUsed
        self.evidenceSufficientForSQL = evidenceSufficientForSQL
        self.unresolvedDecisionKinds = unresolvedDecisionKinds
    }
}

public enum SchemaToolAgentAnswerabilityPolicy {
    public static func evaluate(
        originalQuestion: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        terminalAction: String,
        terminalClarificationQuestion: String
    ) -> SchemaToolAgentClarificationPolicyResult {
        SchemaToolAgentClarificationPolicy.evaluate(
            originalQuestion: originalQuestion,
            databaseContext: databaseContext,
            evidence: evidence,
            terminalAction: terminalAction,
            terminalClarificationQuestion: terminalClarificationQuestion
        )
    }

    public static func answerableWithSQL(
        question: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary
    ) -> Bool {
        SchemaToolAgentClarificationPolicy.evidenceSufficientForSQL(
            question: question,
            databaseContext: databaseContext,
            evidence: evidence
        )
    }
}

public struct SchemaToolAgentProtectedMetricClarificationCandidate: Equatable, Sendable {
    public var question: String
    public var intentCoverage: SchemaToolAgentSQLIntentCoverageResult
    public var clarificationPolicy: SchemaToolAgentClarificationPolicyResult

    public init(
        question: String,
        intentCoverage: SchemaToolAgentSQLIntentCoverageResult,
        clarificationPolicy: SchemaToolAgentClarificationPolicyResult
    ) {
        self.question = question
        self.intentCoverage = intentCoverage
        self.clarificationPolicy = clarificationPolicy
    }
}

/// Joins the existing intent and clarification policies for the one case where
/// inspected evidence proves that a concrete protected metric decision remains
/// unresolved. This adds no vocabulary and does not make broader clarification
/// or SQL-shape decisions.
public enum SchemaToolAgentProtectedMetricClarificationPolicy {
    public static func evaluate(
        question: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        sql: String,
        requiredRelationshipTableIDs: [String] = []
    ) -> SchemaToolAgentProtectedMetricClarificationCandidate? {
        guard evidence.searched,
            !evidence.describedTableIDs.isEmpty,
            !evidence.exposedColumnIDs.isEmpty,
            !evidence.exposedForeignKeyPathIDs.isEmpty,
            hasQuestionRelevantRelationshipEvidence(
                question: question,
                evidence: evidence,
                requiredTableIDs: requiredRelationshipTableIDs
            )
        else {
            return nil
        }

        let intentCoverage = SchemaToolAgentSQLIntentCoveragePolicy.evaluate(
            question: question,
            databaseContext: databaseContext,
            evidence: evidence,
            sql: sql
        )
        guard intentCoverage.decision == .mustClarify,
            intentCoverage.unresolvedDecisionKinds == [.metric],
            let clarificationQuestion = intentCoverage.clarificationQuestion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !clarificationQuestion.isEmpty
        else {
            return nil
        }

        let clarificationPolicy = SchemaToolAgentAnswerabilityPolicy.evaluate(
            originalQuestion: question,
            databaseContext: databaseContext,
            evidence: evidence,
            terminalAction: "clarify",
            terminalClarificationQuestion: clarificationQuestion
        )
        guard clarificationPolicy.decision == .acceptableAmbiguity,
            !clarificationPolicy.evidenceSufficientForSQL,
            clarificationPolicy.unresolvedDecisionKinds.contains(.metric)
        else {
            return nil
        }

        return SchemaToolAgentProtectedMetricClarificationCandidate(
            question: clarificationQuestion,
            intentCoverage: intentCoverage,
            clarificationPolicy: clarificationPolicy
        )
    }

    private static func hasQuestionRelevantRelationshipEvidence(
        question: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        requiredTableIDs: [String]
    ) -> Bool {
        let describedTables = Set(evidence.describedTableIDs.map { $0.lowercased() })
        let exposedColumns = Set(evidence.exposedColumnIDs.map { $0.lowercased() })
        let requiredTables = Set(requiredTableIDs.map { $0.lowercased() })
        let searchedTables = Set(
            evidence.questionRelevantSearchedTableIDs.map { $0.lowercased() }
        )
        let questionTokens = Set(SchemaSearchTokenizer.queryTokens(in: question))
        guard !questionTokens.isEmpty else { return false }

        return evidence.exposedForeignKeyPathIDs.contains { path in
            guard let edge = relationshipEdge(path) else { return false }
            let sourceTable = edge.sourceTableID.lowercased()
            let targetTable = edge.targetTableID.lowercased()
            guard sourceTable != targetTable,
                describedTables.contains(sourceTable),
                describedTables.contains(targetTable),
                exposedColumns.contains(edge.sourceColumnID.lowercased()),
                exposedColumns.contains(edge.targetColumnID.lowercased()),
                requiredTables.isEmpty
                    || (requiredTables.contains(sourceTable) && requiredTables.contains(targetTable))
            else {
                return false
            }

            let relationshipTokens = Set(
                tableNameTokens(in: sourceTable) + tableNameTokens(in: targetTable)
            )
            let questionNamesRelationship = !questionTokens.isDisjoint(with: relationshipTokens)
            let searchEstablishedRelationship = !searchedTables.isEmpty
                && searchedTables.contains(sourceTable)
                && searchedTables.contains(targetTable)
            return questionNamesRelationship || searchEstablishedRelationship
        }
    }

    private static func relationshipEdge(
        _ path: String
    ) -> (
        sourceTableID: String,
        sourceColumnID: String,
        targetTableID: String,
        targetColumnID: String
    )? {
        let endpoints = path.split(separator: "->", maxSplits: 1).map(String.init)
        guard endpoints.count == 2,
            let sourceTableID = tableID(forColumnID: endpoints[0]),
            let targetTableID = tableID(forColumnID: endpoints[1])
        else {
            return nil
        }
        return (sourceTableID, endpoints[0], targetTableID, endpoints[1])
    }

    private static func tableID(forColumnID columnID: String) -> String? {
        guard let separator = columnID.lastIndex(of: ".") else { return nil }
        let tableID = columnID[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        return tableID.isEmpty ? nil : tableID
    }

    private static func tableNameTokens(in tableID: String) -> [String] {
        let tableName = tableID.split(separator: ".").last.map(String.init) ?? tableID
        return SchemaSearchTokenizer.indexTokens(in: tableName)
    }
}

public enum SchemaToolAgentClarificationPolicy {
    public static func evaluate(
        originalQuestion: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary,
        terminalAction: String,
        terminalClarificationQuestion: String
    ) -> SchemaToolAgentClarificationPolicyResult {
        guard terminalAction == "clarify" else {
            return result(.malformedClarification, "terminal action was not clarify")
        }

        let clarification = terminalClarificationQuestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clarification.isEmpty else {
            return result(.malformedClarification, "clarification question was empty")
        }

        let contextFacts = databaseContextFactKinds(
            databaseContext,
            question: originalQuestion,
            clarification: clarification
        )
        let unresolvedKinds = unresolvedDecisionKinds(in: clarification)
        let isGeneric = isGenericClarification(clarification)
        let sufficient = evidenceSufficientForSQL(
            question: originalQuestion,
            databaseContextFactKinds: contextFacts,
            evidence: evidence
        )

        if clarificationTokenCount(clarification) < 2 {
            return result(
                .malformedClarification,
                "clarification question was too short",
                contextFacts: contextFacts,
                sufficient: sufficient,
                unresolvedKinds: unresolvedKinds
            )
        }

        if databaseContextResolvesClarification(
            databaseContext,
            question: originalQuestion,
            clarification: clarification
        ) {
            return result(
                .asksForAlreadyKnownEvidence,
                "database context already defines the requested decision",
                contextFacts: contextFacts,
                sufficient: true,
                unresolvedKinds: unresolvedKinds
            )
        }

        if isGeneric, !sufficient {
            return result(
                .genericClarification,
                "clarification did not name a concrete unresolved database decision",
                contextFacts: contextFacts,
                sufficient: sufficient,
                unresolvedKinds: unresolvedKinds
            )
        }

        if isConcreteAmbiguityProtected(
            question: originalQuestion,
            contextFactKinds: contextFacts,
            evidence: evidence,
            unresolvedKinds: unresolvedKinds
        ) {
            return result(
                .acceptableAmbiguity,
                "clarification asks for a concrete unresolved database decision",
                contextFacts: contextFacts,
                sufficient: sufficient,
                unresolvedKinds: unresolvedKinds
            )
        }

        if sufficient, !hasProtectedAmbiguity(originalQuestion, contextFactKinds: contextFacts) {
            return result(
                .shouldAnswerWithSQL,
                "schema evidence and deterministic question patterns are sufficient for SQL",
                contextFacts: contextFacts,
                sufficient: true,
                unresolvedKinds: unresolvedKinds
            )
        }

        if isGeneric || unresolvedKinds.isEmpty {
            return result(
                .genericClarification,
                "clarification did not name a concrete unresolved database decision",
                contextFacts: contextFacts,
                sufficient: sufficient,
                unresolvedKinds: unresolvedKinds
            )
        }

        if !evidence.searched || evidence.describedTableIDs.isEmpty {
            return result(
                .insufficientSchemaEvidence,
                "schema search and table description evidence are not yet sufficient",
                contextFacts: contextFacts,
                sufficient: false,
                unresolvedKinds: unresolvedKinds
            )
        }

        return result(
            .acceptableAmbiguity,
            "clarification asks for a concrete unresolved database decision",
            contextFacts: contextFacts,
            sufficient: sufficient,
            unresolvedKinds: unresolvedKinds
        )
    }

    public static func evidenceSufficientForSQL(
        question: String,
        databaseContextFactKinds: [String],
        evidence: OpenRouterSchemaToolEvidenceSummary
    ) -> Bool {
        guard evidence.searched,
            !evidence.describedTableIDs.isEmpty,
            !evidence.exposedColumnIDs.isEmpty
        else {
            return false
        }
        if hasProtectedAmbiguity(question, contextFactKinds: databaseContextFactKinds) {
            return false
        }

        let pattern = SQLPatternSignals(question: question)
        if !databaseContextFactKinds.isEmpty {
            return true
        }
        if pattern.hasStatusPhrase, hasStatusOrBooleanSupport(pattern: pattern, evidence: evidence) {
            return true
        }
        if pattern.hasDateWindow, hasDateOrTimeColumn(evidence) {
            return true
        }
        if pattern.hasAntiJoin, hasMissingRowsSupport(evidence) {
            return true
        }
        if pattern.hasAverage {
            return true
        }
        if pattern.hasGroupBy || pattern.hasTopCount {
            return !hasProtectedAmbiguity(question, contextFactKinds: databaseContextFactKinds)
        }
        if pattern.hasComparison {
            return true
        }
        return false
    }

    public static func evidenceSufficientForSQL(
        question: String,
        databaseContext: String,
        evidence: OpenRouterSchemaToolEvidenceSummary
    ) -> Bool {
        evidenceSufficientForSQL(
            question: question,
            databaseContextFactKinds: databaseContextFactKinds(
                databaseContext,
                question: question,
                clarification: ""
            ),
            evidence: evidence
        )
    }

    private static func isConcreteAmbiguityProtected(
        question: String,
        contextFactKinds: [String],
        evidence: OpenRouterSchemaToolEvidenceSummary,
        unresolvedKinds: [SchemaToolAgentUnresolvedDecisionKind]
    ) -> Bool {
        let contextFacts = Set(contextFactKinds)
        if unresolvedKinds.contains(.metric),
            hasProtectedAmbiguity(question, contextFactKinds: contextFactKinds),
            !contextFacts.contains("metric")
        {
            return true
        }
        if unresolvedKinds.contains(.relationship),
            evidence.exposedForeignKeyPathIDs.count > 1,
            !contextFacts.contains("relationship")
        {
            return true
        }
        if unresolvedKinds.contains(.timeField),
            dateOrTimeColumnCount(evidence) > 1,
            !contextFacts.contains("time")
        {
            return true
        }
        return false
    }

    public static func databaseContextResolvesClarification(
        _ databaseContext: String,
        question: String,
        clarification: String
    ) -> Bool {
        let rawContextTokens = Set(tokens(in: databaseContext))
        let contextTokens = expandedTokens(rawContextTokens.subtracting(databaseContextAuthorityStopWords))
        guard !contextTokens.isEmpty else { return false }
        let rawClarificationTokens = Set(tokens(in: clarification))
        let clarificationTokens = expandedTokens(
            rawClarificationTokens.subtracting(databaseContextAuthorityStopWords)
        )
        guard !clarificationTokens.isEmpty else { return false }
        let definitionScopes = databaseContextDefinitionScopes(in: databaseContext)
        guard !definitionScopes.isEmpty else { return false }
        let requestedStatusTokens = rawClarificationTokens
            .union(Set(tokens(in: question)))
            .intersection(statusPhraseTokens)
        if isTimeWindowClarification(rawClarificationTokens) {
            let questionTokens = Set(tokens(in: question))
            return definitionScopes.contains { scope in
                !scope.rawTokens.isDisjoint(with: databaseContextTemporalTokens)
                    && databaseContextContainsConcreteTemporalField(scope.text)
                    && databaseContextTemporalScopeMatchesQuestion(
                        scope,
                        questionTokens: questionTokens
                    )
            }
        }
        return definitionScopes.contains { scope in
            let scopeStatusTokens = scope.rawTokens.intersection(statusPhraseTokens)
            if !requestedStatusTokens.isEmpty,
                !scopeStatusTokens.isEmpty,
                scopeStatusTokens.isDisjoint(with: requestedStatusTokens)
            {
                return false
            }
            let scopedContextTokens = expandedTokens(scope.tokens).intersection(contextTokens)
            let overlap = clarificationTokens.intersection(scopedContextTokens)
            if scope.hasStrongDefinitionSignal {
                return hasBusinessSpecificDefinitionOverlap(overlap)
            }
            return false
        }
    }

    private static func result(
        _ decision: SchemaToolAgentClarificationDecision,
        _ reason: String,
        contextFacts: [String] = [],
        sufficient: Bool = false,
        unresolvedKinds: [SchemaToolAgentUnresolvedDecisionKind] = []
    ) -> SchemaToolAgentClarificationPolicyResult {
        SchemaToolAgentClarificationPolicyResult(
            decision: decision,
            reason: reason,
            databaseContextFactsUsed: contextFacts,
            evidenceSufficientForSQL: sufficient,
            unresolvedDecisionKinds: unresolvedKinds
        )
    }

    private static func isGenericClarification(_ question: String) -> Bool {
        let lower = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lower.isEmpty { return true }
        let genericFragments = [
            "can you clarify",
            "could you clarify",
            "what do you mean",
            "please provide more context",
            "what column, condition, or table defines",
            "what column or table defines",
            "which column defines",
            "which table defines",
        ]
        return genericFragments.contains { lower.contains($0) }
    }

    private static func unresolvedDecisionKinds(
        in clarification: String
    ) -> [SchemaToolAgentUnresolvedDecisionKind] {
        let tokenSet = Set(tokens(in: clarification))
        var kinds = Set<SchemaToolAgentUnresolvedDecisionKind>()
        if !tokenSet.isDisjoint(with: metricClarificationTokens) {
            kinds.insert(.metric)
        }
        if !tokenSet.isDisjoint(with: relationshipClarificationTokens) {
            kinds.insert(.relationship)
        }
        if !tokenSet.isDisjoint(with: filterClarificationTokens) {
            kinds.insert(.statusOrFilter)
        }
        if !tokenSet.isDisjoint(with: timeClarificationTokens) {
            kinds.insert(.timeField)
        }
        if !tokenSet.isDisjoint(with: eventTableClarificationTokens) {
            kinds.insert(.eventTable)
        }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private static func databaseContextFactKinds(
        _ databaseContext: String,
        question: String,
        clarification: String
    ) -> [String] {
        let questionTokens = Set(tokens(in: question))
        let clarificationTokens = Set(tokens(in: clarification))
        let relevanceTokens = expandedTokens(
            questionTokens
                .union(clarificationTokens)
                .subtracting(databaseContextAuthorityStopWords)
                .subtracting(databaseContextGenericDefinitionOverlapTokens)
                .subtracting(databaseContextTemporalRelevanceStopWords)
                .subtracting(["define", "defines", "definition", "metric", "should"])
        )
        var facts = Set<String>()
        for scope in databaseContextDefinitionScopes(in: databaseContext) {
            let scopeRelevanceTokens = expandedTokens(
                scope.tokens
                    .subtracting(databaseContextGenericDefinitionOverlapTokens)
                    .subtracting(databaseContextTemporalRelevanceStopWords)
                    .subtracting(["define", "defines", "definition", "metric", "should"])
            )
            guard !scopeRelevanceTokens.isDisjoint(with: relevanceTokens) else {
                continue
            }
            if !scope.rawTokens.isDisjoint(with: metricDefinitionTokens)
                || !scope.rawTokens.isDisjoint(with: questionTokens.intersection(metricClarificationTokens))
            {
                facts.insert("metric")
            }
            if !scope.rawTokens.isDisjoint(with: filterDefinitionTokens)
                || !scope.rawTokens.isDisjoint(with: clarificationTokens.intersection(filterClarificationTokens))
            {
                facts.insert("filter")
            }
            if !scope.rawTokens.isDisjoint(with: databaseContextTemporalTokens)
                || databaseContextContainsConcreteTemporalField(scope.text)
            {
                facts.insert("time")
            }
            if !scope.rawTokens.isDisjoint(with: relationshipDefinitionTokens) {
                facts.insert("relationship")
            }
        }
        return facts.sorted()
    }

    private static func hasProtectedAmbiguity(
        _ question: String,
        contextFactKinds: [String]
    ) -> Bool {
        let tokenSet = Set(tokens(in: question))
        if contextFactKinds.contains("metric") { return false }
        return !tokenSet.isDisjoint(with: protectedMetricTerms)
    }

    private static func hasStatusOrBooleanSupport(
        pattern: SQLPatternSignals,
        evidence: OpenRouterSchemaToolEvidenceSummary
    ) -> Bool {
        let columnNames = evidence.exposedColumnIDs.compactMap(lastSQLPathComponent).map { $0.lowercased() }
        guard !columnNames.isEmpty else { return false }
        if columnNames.contains("status") || columnNames.contains("state") {
            return true
        }
        return pattern.statusTokens.contains { status in
            columnNames.contains { column in
                column == status
                    || column == "is_\(status)"
                    || column == "\(status)_at"
                    || column == "\(status)_date"
                    || column == "\(status)_on"
                    || column.contains("_\(status)_")
                    || column.hasSuffix("_\(status)")
            }
        }
    }

    private static func hasDateOrTimeColumn(_ evidence: OpenRouterSchemaToolEvidenceSummary) -> Bool {
        dateOrTimeColumnCount(evidence) > 0
    }

    private static func dateOrTimeColumnCount(_ evidence: OpenRouterSchemaToolEvidenceSummary) -> Int {
        evidence.exposedColumnIDs.filter { column in
            let name = lastSQLPathComponent(column) ?? column
            let lower = name.lowercased()
            return lower == "date"
                || lower == "time"
                || lower.contains("timestamp")
                || lower.hasSuffix("_at")
                || lower.hasSuffix("_date")
                || lower.hasSuffix("_time")
                || lower.hasSuffix("_on")
                || name.range(of: #"(?:At|Date|Time|Timestamp)$"#, options: .regularExpression) != nil
        }.count
    }

    private static func hasMissingRowsSupport(_ evidence: OpenRouterSchemaToolEvidenceSummary) -> Bool {
        if !evidence.exposedForeignKeyPathIDs.isEmpty { return true }
        return evidence.exposedColumnIDs.contains { column in
            let lower = (lastSQLPathComponent(column) ?? column).lowercased()
            return lower.hasSuffix("_id") || lower.hasSuffix("id")
        }
    }

    private static func hasBusinessSpecificDefinitionOverlap(_ tokens: Set<String>) -> Bool {
        tokens.contains { token in
            !databaseContextGenericDefinitionOverlapTokens.contains(token)
        }
    }

    private static func databaseContextTemporalScopeMatchesQuestion(
        _ scope: DatabaseContextDefinitionScope,
        questionTokens: Set<String>
    ) -> Bool {
        let scopeSpecific = expandedTokens(scope.tokens.subtracting(databaseContextTemporalRelevanceStopWords))
        if scopeSpecific.isEmpty { return true }
        let questionSpecific = expandedTokens(questionTokens.subtracting(databaseContextTemporalRelevanceStopWords))
        return !scopeSpecific.isDisjoint(with: questionSpecific)
    }

    private static func databaseContextDefinitionScopes(
        in databaseContext: String
    ) -> [DatabaseContextDefinitionScope] {
        databaseContextDefinitionSegments(in: databaseContext)
            .compactMap { segment -> DatabaseContextDefinitionScope? in
                let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let rawTokens = Set(tokens(in: text))
                let hasStrongSignal = !rawTokens.isDisjoint(with: databaseContextStrongDefinitionTokens)
                let hasUseSignal = !rawTokens.isDisjoint(with: databaseContextUseDefinitionTokens)
                guard hasStrongSignal || hasUseSignal else { return nil }
                return DatabaseContextDefinitionScope(
                    text: text,
                    rawTokens: rawTokens,
                    tokens: rawTokens.subtracting(databaseContextAuthorityStopWords),
                    hasStrongDefinitionSignal: hasStrongSignal
                )
            }
    }

    private static func databaseContextDefinitionSegments(in databaseContext: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = databaseContext.startIndex
        while index < databaseContext.endIndex {
            let character = databaseContext[index]
            let nextIndex = databaseContext.index(after: index)
            let nextCharacter = nextIndex < databaseContext.endIndex ? databaseContext[nextIndex] : nil
            let endsSentence =
                character == "\n" || character == ";"
                    || (character == "." && (nextCharacter == nil || nextCharacter?.isWhitespace == true))
            if endsSentence {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = nextIndex
        }
        segments.append(current)
        return segments
    }

    private static func isTimeWindowClarification(_ tokens: Set<String>) -> Bool {
        !tokens.isDisjoint(with: ["date", "time", "window", "timestamp", "timestamps"])
    }

    private static func databaseContextContainsConcreteTemporalField(_ databaseContext: String) -> Bool {
        let snakeTemporalIdentifier =
            #"\b[a-z][a-z0-9]*(?:_at|_date|_time|_timestamp)\b"#
        if databaseContext.range(
            of: snakeTemporalIdentifier,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        let camelTemporalIdentifier = #"\b[a-z][A-Za-z0-9]*(?:At|Date|Time|Timestamp)\b"#
        return databaseContext.range(of: camelTemporalIdentifier, options: [.regularExpression]) != nil
    }

    private static func clarificationTokenCount(_ value: String) -> Int {
        tokens(in: value).count
    }

    private static func lastSQLPathComponent(_ value: String) -> String? {
        sqlPathComponents(value).last
    }

    private static func sqlPathComponents(_ value: String) -> [String] {
        var components: [String] = []
        var current = ""
        var inQuote = false
        var iterator = value.trimmingCharacters(in: .whitespacesAndNewlines).makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if inQuote, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuote = false
                        if next == "." {
                            components.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuote.toggle()
                }
            } else if character == ".", !inQuote {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            components.append(current)
        }
        return components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    private static func expandedTokens(_ tokens: Set<String>) -> Set<String> {
        var expanded = tokens
        for token in tokens where token.count > 2 {
            if token.hasSuffix("ies"), token.count > 4 {
                expanded.insert(String(token.dropLast(3)) + "y")
            }
            if token.hasSuffix("es"), token.count > 4 {
                expanded.insert(String(token.dropLast(2)))
            }
            if token.hasSuffix("s"), token.count > 3 {
                expanded.insert(String(token.dropLast()))
            } else if token.count > 3 {
                expanded.insert(token + "s")
            }
        }
        return expanded
    }

    private struct SQLPatternSignals {
        var hasAntiJoin: Bool
        var hasGroupBy: Bool
        var hasTopCount: Bool
        var hasAverage: Bool
        var hasDateWindow: Bool
        var hasStatusPhrase: Bool
        var hasComparison: Bool
        var statusTokens: Set<String>

        init(question: String) {
            let lower = question.lowercased()
            let tokenSet = Set(SchemaToolAgentClarificationPolicy.tokens(in: question))
            statusTokens = tokenSet.intersection(SchemaToolAgentClarificationPolicy.statusPhraseTokens)
            hasStatusPhrase = !statusTokens.isEmpty
            hasAntiJoin = tokenSet.contains("without")
                || lower.contains("never placed")
                || lower.contains("no ")
            hasGroupBy = tokenSet.contains("per") || tokenSet.contains("by") || tokenSet.contains("each")
            hasTopCount = !tokenSet.isDisjoint(with: ["most", "frequent", "top"])
            hasAverage = !tokenSet.isDisjoint(with: ["average", "avg", "mean"])
            hasDateWindow =
                lower.range(
                    of: #"\b(last|next)\s+\d+\s+(day|days|week|weeks|month|months|year|years)\b"#,
                    options: .regularExpression
                ) != nil
                || lower.range(
                    of: #"\b(ending|starting)\s+\d{4}-\d{2}-\d{2}\b"#,
                    options: .regularExpression
                ) != nil
                || (!tokenSet.isDisjoint(with: ["last", "next"])
                    && !tokenSet.isDisjoint(with: ["day", "days", "week", "weeks", "month", "months", "year", "years"]))
            hasComparison = lower.contains("more than")
                || lower.contains("less than")
                || tokenSet.contains("overallocated")
                || tokenSet.contains("exceeding")
                || tokenSet.contains("expired")
                || tokenSet.contains("expiring")
        }
    }

    private struct DatabaseContextDefinitionScope {
        var text: String
        var rawTokens: Set<String>
        var tokens: Set<String>
        var hasStrongDefinitionSignal: Bool
    }

    private static let protectedMetricTerms: Set<String> = [
        "best", "healthy", "important", "win", "winner", "wins",
    ]

    private static let statusPhraseTokens: Set<String> = [
        "active", "failed", "paid", "resolved", "unresolved", "verified",
    ]

    private static let metricClarificationTokens: Set<String> = [
        "average", "best", "cluster", "count", "counts", "define", "defines",
        "definition", "healthy", "important", "mean", "meaning", "metric",
        "revenue", "usage", "win", "winner", "wins",
    ]

    private static let relationshipClarificationTokens: Set<String> = [
        "between", "join", "joins", "path", "relationship", "relationships",
    ]

    private static let filterClarificationTokens: Set<String> = [
        "active", "condition", "conditions", "failed", "filter", "filters",
        "non", "null", "paid", "resolved", "status", "statuses", "unresolved",
        "value", "values", "verified", "where",
    ]

    private static let timeClarificationTokens: Set<String> = [
        "anchor", "date", "field", "time", "timestamp", "timestamps", "window",
    ]

    private static let eventTableClarificationTokens: Set<String> = [
        "event", "events", "record", "records", "row", "rows", "source", "table", "tables",
    ]

    private static let metricDefinitionTokens: Set<String> = [
        "count", "counts", "define", "defines", "mean", "means", "metric",
        "record", "records", "revenue", "usage", "win", "wins",
    ]

    private static let filterDefinitionTokens: Set<String> = [
        "active", "failed", "filter", "non", "null", "paid", "resolved",
        "status", "unresolved", "verified", "where",
    ]

    private static let relationshipDefinitionTokens: Set<String> = [
        "join", "joins", "membership", "relationship", "relationships", "with",
    ]

    private static let databaseContextStrongDefinitionTokens: Set<String> = [
        "active", "count", "counts", "counting", "define", "defines", "definition",
        "mean", "means", "metric", "non", "null", "paid", "record", "records",
        "resolved", "status", "unresolved", "where", "when",
    ]

    private static let databaseContextUseDefinitionTokens: Set<String> = [
        "use", "uses",
    ]

    private static let databaseContextTemporalTokens: Set<String> = [
        "created", "date", "dated", "ended", "ending", "finish", "finished",
        "occurred", "scheduled", "start", "started", "starts", "time", "timestamp",
        "timestamps", "updated", "window", "windows",
    ]

    private static let databaseContextGenericDefinitionOverlapTokens: Set<String> = {
        let tokens = [
            "column", "columns", "condition", "conditions", "field", "fields",
            "filter", "filters", "status", "statuses", "table", "tables", "value",
            "values",
        ]
        return Set(tokens.flatMap { SchemaToolAgentClarificationPolicy.tokens(in: $0) })
    }()

    private static let databaseContextAuthorityStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
        "is", "it", "of", "on", "or", "the", "this", "to", "utc", "timestamp",
        "timestamps", "time", "date", "which", "what", "column", "condition",
        "table", "question",
    ]

    private static let databaseContextTemporalRelevanceStopWords: Set<String> =
        databaseContextAuthorityStopWords
        .union(databaseContextTemporalTokens)
        .union(databaseContextGenericDefinitionOverlapTokens)
        .union(databaseContextStrongDefinitionTokens)
        .union(databaseContextUseDefinitionTokens)
        .union([
            "day", "days", "hour", "hours", "last", "minute", "minutes", "month",
            "months", "one", "past", "previous", "recent", "rolling", "seven", "six",
            "ten", "three", "two", "week", "weeks", "year", "years",
        ])
}
