import Foundation

public enum QueryIntentPlanner {
    public static func deterministicIntent(for question: String) -> QueryIntentFrame {
        let normalized = normalize(question)
        let operation = operation(for: normalized)
        var measure: MeasureIntent = .none
        var measurePhrase: String?
        var ranking: RankingIntent?
        var requestedLimit: Int?
        var groupingPhrases: [String] = []
        var subjectPhrases: [String] = []
        var customBusinessTerms = customTerms(in: normalized)

        if let phrase = firstPhrase(in: normalized, from: countRankingPhrases) {
            measure = .countRows
            measurePhrase = phrase
            ranking = RankingIntent(direction: .descending, takeFirst: true)
            requestedLimit = 1
            let subject = subjectAfter(phrase, in: normalized)
            if !subject.isEmpty {
                subjectPhrases = [subject]
                groupingPhrases = [subject]
            }
        } else if let phrase = firstPhrase(in: normalized, from: latestPhrases) {
            ranking = RankingIntent(direction: .descending, takeFirst: true)
            requestedLimit = 1
            let subject = subjectAfter(phrase, in: normalized)
            if !subject.isEmpty {
                subjectPhrases = [subject]
            }
        } else if let phrase = firstPhrase(in: normalized, from: oldestPhrases) {
            ranking = RankingIntent(direction: .ascending, takeFirst: true)
            requestedLimit = 1
            let subject = subjectAfter(phrase, in: normalized)
            if !subject.isEmpty {
                subjectPhrases = [subject]
            }
        } else if normalized.contains("average") || normalized.contains(" avg ") {
            measure = .average
            measurePhrase = "average"
            subjectPhrases = subjectBeforeGrouping(in: normalized)
            groupingPhrases = groupingAfterPerOrBy(in: normalized)
        } else if normalized.contains("total") || normalized.contains(" sum ") {
            measure = normalized.contains("count") ? .countRows : .sum
            measurePhrase = normalized.contains("total") ? "total" : "sum"
            subjectPhrases = subjectBeforeGrouping(in: normalized)
            groupingPhrases = groupingAfterPerOrBy(in: normalized)
        } else if normalized.contains("unique") || normalized.contains("distinct") {
            measure = .countDistinct
            measurePhrase = normalized.contains("unique") ? "unique" : "distinct"
            subjectPhrases = subjectBeforeGrouping(in: normalized)
            groupingPhrases = groupingAfterPerOrBy(in: normalized)
        } else {
            subjectPhrases = subjectBeforeGrouping(in: normalized)
        }

        if !customBusinessTerms.isEmpty {
            measure = measure == .none ? .custom : measure
        }
        customBusinessTerms.removeAll { term in
            Set(SchemaIndex.tokens(in: measurePhrase ?? "")).contains(term)
        }

        let searches = Array((subjectPhrases + groupingPhrases + customBusinessTerms).prefix(4))
        return QueryIntentFrame(
            operation: operation,
            subjectPhrases: subjectPhrases,
            outputPhrases: subjectPhrases,
            measure: measure,
            measurePhrase: measurePhrase,
            groupingPhrases: groupingPhrases,
            ranking: ranking,
            requestedLimit: requestedLimit,
            filters: [],
            timeIntent: timePhrase(in: normalized).map(TimeIntent.init(phrase:)),
            customBusinessTerms: customBusinessTerms,
            schemaSearchQueries: searches
        )
    }

    private static func operation(for normalized: String) -> QueryOperation {
        if normalized.hasPrefix("insert ") || normalized.hasPrefix("add ") { return .insert }
        if normalized.hasPrefix("update ") || normalized.hasPrefix("change ") { return .update }
        if normalized.hasPrefix("delete ") || normalized.hasPrefix("remove ") { return .delete }
        return .read
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func firstPhrase(in text: String, from phrases: [String]) -> String? {
        phrases.first { phrase in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }

    private static func subjectAfter(_ phrase: String, in text: String) -> String {
        guard let range = text.range(of: phrase) else { return "" }
        let suffix = text[range.upperBound...]
        return cleanedSubject(String(suffix))
    }

    private static func subjectBeforeGrouping(in text: String) -> [String] {
        let chunks = text.components(separatedBy: " by ")
        let beforeBy = chunks.first ?? text
        let beforePer = beforeBy.components(separatedBy: " per ").first ?? beforeBy
        let subject = cleanedSubject(beforePer)
        return subject.isEmpty ? [] : [subject]
    }

    private static func groupingAfterPerOrBy(in text: String) -> [String] {
        if let range = text.range(of: " per ") ?? text.range(of: " by ") {
            let phrase = cleanedSubject(String(text[range.upperBound...]))
            return phrase.isEmpty ? [] : [phrase]
        }
        return []
    }

    private static func cleanedSubject(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        while let first = tokens.first, subjectStopWords.contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, subjectStopWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static func customTerms(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: " ").map(String.init).filter { token in
            customBusinessTerms.contains(token) && seen.insert(token).inserted
        }
    }

    private static func timePhrase(in text: String) -> String? {
        let phrases = ["last two weeks", "last week", "last month", "today", "yesterday"]
        return phrases.first { text.contains($0) }
    }

    private static let countRankingPhrases = [
        "most frequent", "most common", "most recurring", "occurs most often",
        "occur most often", "highest volume", "highest volume",
    ]
    private static let latestPhrases = ["latest", "newest", "most recent"]
    private static let oldestPhrases = ["oldest", "earliest"]
    private static let subjectStopWords: Set<String> = [
        "a", "an", "are", "calculate", "can", "each", "for", "get", "have", "in", "is",
        "list", "me", "of", "one", "return", "see", "show", "the", "to", "what", "which",
        "with",
    ]
    private static let customBusinessTerms: Set<String> = [
        "best", "engaged", "healthy", "quality", "successful", "valuable", "win", "winning",
        "wins", "worst",
    ]
}

public enum GroundedQueryPlanner {
    public static func ground(
        intent: QueryIntentFrame,
        schema: DatabaseSchema,
        referencedTables: [String] = []
    ) -> GroundedQueryPlan {
        var slots: [GroundingSlot] = []
        var selectedTables: [String] = []
        var selectedJoinPaths: [SchemaJoinPath] = []
        let subjectPhrase = (intent.groupingPhrases.first ?? intent.subjectPhrases.first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectCandidates = rankedTables(matching: subjectPhrase, schema: schema)
        let selectedSubject = subjectCandidates.count == 1 ? subjectCandidates[0].table : subjectCandidates.first?.table
        slots.append(
            GroundingSlot(
                id: .subject,
                kind: .subjectEntity,
                phrase: subjectPhrase,
                required: !subjectPhrase.isEmpty,
                candidates: subjectCandidates.map(\.candidate),
                selectedCandidate: subjectCandidates.count == 1 ? subjectCandidates[0].candidate : nil,
                state: subjectCandidates.isEmpty ? .unsupported : (subjectCandidates.count == 1 ? .grounded : .ambiguous)
            )
        )
        if let selectedSubject {
            selectedTables.append(selectedSubject.qualifiedName)
        }

        for term in intent.customBusinessTerms {
            slots.append(
                GroundingSlot(
                    id: .customBusinessTerm,
                    kind: .customBusinessTerm,
                    phrase: term,
                    required: true,
                    state: .unsupported
                )
            )
        }

        if intent.measure == .countRows,
            let groupTable = selectedSubject
        {
            var occurrence = occurrenceCandidates(for: groupTable, intent: intent, schema: schema)
            if occurrence.isEmpty,
                referencedTables.contains(groupTable.qualifiedName)
            {
                occurrence.append(
                    OccurrenceCandidate(
                        candidate: GroundingCandidate(
                            id: "table-rows:\(groupTable.id)",
                            label: "count rows in \(groupTable.qualifiedName)",
                            objectIDs: ["table:\(groupTable.id)"],
                            evidence: [groupTable.qualifiedName]
                        ),
                        tableIDs: [groupTable.qualifiedName],
                        joinPath: nil
                    )
                )
            }
            let selected = occurrence.count == 1 ? occurrence[0] : nil
            slots.append(
                GroundingSlot(
                    id: .occurrenceRelation,
                    kind: .occurrenceRelation,
                    phrase: occurrencePhrase(for: intent),
                    required: true,
                    candidates: occurrence.map(\.candidate),
                    selectedCandidate: selected?.candidate,
                    state: occurrence.isEmpty ? .unsupported : (occurrence.count == 1 ? .grounded : .ambiguous)
                )
            )
            if let selected {
                selectedTables.append(contentsOf: selected.tableIDs)
                if let joinPath = selected.joinPath {
                    selectedJoinPaths.append(joinPath)
                }
            }
        }

        let unresolved = slots.filter { $0.required && ($0.state == .unsupported || $0.state == .ambiguous) }
        let readiness: QueryPlanReadiness
        if unresolved.isEmpty {
            readiness = selectedTables.isEmpty ? .ready : .readyWithInterpretation
        } else {
            readiness = .needsClarification
        }
        var seen = Set<String>()
        selectedTables = selectedTables.filter { seen.insert($0).inserted }
        return GroundedQueryPlan(
            intent: intent,
            slots: slots,
            selectedTables: selectedTables,
            selectedJoinPaths: selectedJoinPaths,
            readiness: readiness,
            interpretationSummary: interpretationSummary(intent: intent, slots: slots)
        )
    }

    public static func clarification(
        for plan: GroundedQueryPlan,
        originalQuestion: String? = nil
    ) -> PendingClarification? {
        let unresolved = plan.slots.filter {
            $0.required && ($0.state == .unsupported || $0.state == .ambiguous)
        }
        guard let slot = unresolved.sorted(by: clarificationPriority).first else {
            return nil
        }
        let concept = SQLGroundingConcept(
            term: slot.phrase,
            kind: conceptKind(for: slot.kind),
            state: slot.state,
            required: slot.required,
            evidence: slot.candidates.flatMap(\.evidence)
        )
        return PendingClarification(
            concept: concept,
            originalQuestion: originalQuestion ?? plan.intent.subjectPhrases.first ?? slot.phrase,
            plan: plan,
            slotID: slot.id,
            question: question(for: slot),
            options: slot.candidates.prefix(3).map {
                ClarificationOption(
                    label: $0.label,
                    replyText: "Use \($0.label)",
                    definition: $0.objectIDs.joined(separator: ", "),
                    evidence: $0.evidence
                )
            },
            evidence: concept.evidence
        )
    }

    private struct RankedTable {
        var table: TableInfo
        var score: Int
        var candidate: GroundingCandidate
    }

    private struct OccurrenceCandidate {
        var candidate: GroundingCandidate
        var tableIDs: [String]
        var joinPath: SchemaJoinPath?
    }

    private static func rankedTables(matching phrase: String, schema: DatabaseSchema) -> [RankedTable] {
        let phraseTokens = Set(SchemaIndex.tokens(in: phrase))
        guard !phraseTokens.isEmpty else { return [] }
        let ranked = schema.tables.compactMap { table -> RankedTable? in
            let tableTokens = Set(SchemaIndex.tokens(in: table.name))
            let columnTokens = Set(table.columns.flatMap { SchemaIndex.tokens(in: $0.name) })
            let exact = table.name.lowercased() == phrase.replacingOccurrences(of: " ", with: "_")
            let tableMatches = phraseTokens.intersection(tableTokens).count
            let columnMatches = phraseTokens.intersection(columnTokens).count
            let score = (exact ? 100 : 0) + tableMatches * 20 + columnMatches * 3
            guard score > 0 else { return nil }
            return RankedTable(
                table: table,
                score: score,
                candidate: GroundingCandidate(
                    id: "table:\(table.id)",
                    label: table.qualifiedName,
                    objectIDs: ["table:\(table.id)"],
                    evidence: [table.qualifiedName]
                )
            )
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.table.qualifiedName < rhs.table.qualifiedName : lhs.score > rhs.score
        }
        guard let top = ranked.first else { return [] }
        return ranked.filter { $0.score == top.score }
    }

    private static func occurrenceCandidates(
        for groupTable: TableInfo,
        intent: QueryIntentFrame,
        schema: DatabaseSchema
    ) -> [OccurrenceCandidate] {
        var candidates: [OccurrenceCandidate] = []
        for foreignKey in schema.foreignKeys {
            let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
            let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
            guard targetID == groupTable.id || sourceID == groupTable.id else { continue }
            let occurrenceTableID = targetID == groupTable.id ? sourceID : targetID
            guard let occurrenceTable = schema.tables.first(where: { $0.id == occurrenceTableID }) else {
                continue
            }
            let evidence = [
                foreignKey.summary,
                occurrenceTable.qualifiedName,
            ]
            let label = "count rows in \(occurrenceTable.qualifiedName)"
            let path = SchemaJoinPath(
                id: "fk:\(foreignKey.constraintName)",
                foreignKeys: [foreignKey],
                summary: foreignKey.summary
            )
            candidates.append(
                OccurrenceCandidate(
                    candidate: GroundingCandidate(
                        id: "fk:\(foreignKey.constraintName)",
                        label: label,
                        objectIDs: ["fk:\(foreignKey.constraintName)", "table:\(occurrenceTable.id)"],
                        evidence: evidence
                    ),
                    tableIDs: [groupTable.qualifiedName, occurrenceTable.qualifiedName],
                    joinPath: path
                )
            )
        }
        for column in groupTable.columns {
            let tokens = Set(SchemaIndex.tokens(in: column.name))
            guard !tokens.intersection(["count", "total", "number"]).isEmpty else { continue }
            candidates.append(
                OccurrenceCandidate(
                    candidate: GroundingCandidate(
                        id: "column:\(column.id)",
                        label: "use \(groupTable.qualifiedName).\(column.name)",
                        objectIDs: ["column:\(column.id)"],
                        evidence: ["\(groupTable.qualifiedName).\(column.name)"]
                    ),
                    tableIDs: [groupTable.qualifiedName],
                    joinPath: nil
                )
            )
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.candidate.id).inserted }
    }

    private static func interpretationSummary(intent: QueryIntentFrame, slots: [GroundingSlot]) -> String {
        if intent.measure == .countRows,
            let selected = slots.first(where: { $0.kind == .occurrenceRelation })?.selectedCandidate
        {
            return "\"\(intent.measurePhrase ?? "count")\" means \(selected.label), grouped by \(intent.groupingPhrases.first ?? "the requested entity")."
        }
        return ""
    }

    private static func occurrencePhrase(for intent: QueryIntentFrame) -> String {
        let subject = intent.groupingPhrases.first ?? intent.subjectPhrases.first
        if let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(subject) occurrences"
        }
        return "row occurrences"
    }

    private static func clarificationPriority(lhs: GroundingSlot, rhs: GroundingSlot) -> Bool {
        priority(for: lhs.kind) < priority(for: rhs.kind)
    }

    private static func priority(for kind: GroundingSlotKind) -> Int {
        switch kind {
        case .customBusinessTerm:
            0
        case .occurrenceRelation, .relationshipPath:
            1
        case .filterValue:
            2
        case .timeColumn:
            3
        case .measureColumn, .groupingColumn, .filterColumn:
            4
        case .subjectEntity, .outputEntity:
            5
        }
    }

    private static func conceptKind(for slotKind: GroundingSlotKind) -> SQLGroundingConcept.Kind {
        switch slotKind {
        case .occurrenceRelation, .relationshipPath:
            .relationship
        case .measureColumn:
            .metric
        case .filterColumn, .filterValue:
            .filter
        case .timeColumn:
            .time
        case .customBusinessTerm:
            .businessTerm
        case .subjectEntity, .outputEntity, .groupingColumn:
            .entity
        }
    }

    private static func question(for slot: GroundingSlot) -> String {
        switch slot.kind {
        case .occurrenceRelation:
            if slot.candidates.count > 1 {
                let labels = slot.candidates.prefix(3).map(\.label).joined(separator: ", ")
                return "I found multiple ways to count \"\(slot.phrase)\": \(labels). Which should Widen use?"
            }
            return "Which schema relationship should define \"\(slot.phrase)\"?"
        case .customBusinessTerm:
            return "What metric should \"\(slot.phrase)\" mean here?"
        case .timeColumn:
            return "Which date or timestamp column should define \"\(slot.phrase)\"?"
        case .filterValue:
            return "Which schema value should represent \"\(slot.phrase)\"?"
        default:
            return "Which schema table or column should \"\(slot.phrase)\" refer to?"
        }
    }
}

public struct SQLIntentConformanceResult: Equatable, Sendable {
    public var isValid: Bool
    public var issues: [String]

    public init(isValid: Bool, issues: [String] = []) {
        self.isValid = isValid
        self.issues = issues
    }
}

public enum SQLIntentConformanceValidator {
    public static func validate(
        sql: String,
        plan: GroundedQueryPlan,
        schema: DatabaseSchema
    ) -> SQLIntentConformanceResult {
        let normalized = sql.lowercased()
        var issues: [String] = []
        if plan.intent.measure == .countRows,
            !normalized.contains("count(")
        {
            issues.append("Frequency intent requires COUNT.")
        }
        if !plan.intent.groupingPhrases.isEmpty,
            !normalized.contains("group by")
        {
            issues.append("Frequency intent requires GROUP BY for the requested entity.")
        }
        if plan.intent.ranking?.direction == .descending {
            if !normalized.contains("order by") || !normalized.contains("desc") {
                issues.append("Descending ranking intent requires ORDER BY ... DESC.")
            }
        }
        if plan.intent.ranking?.takeFirst == true || plan.intent.requestedLimit == 1 {
            if normalized.range(of: #"(?i)\blimit\s+1\b"#, options: .regularExpression) == nil {
                issues.append("Singular top result intent requires LIMIT 1.")
            }
        }
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        let referenced = Set(schemaValidation.referencedTables)
        for table in plan.selectedTables where !referenced.contains(table) {
            issues.append("SQL does not reference grounded table \(table).")
        }
        return SQLIntentConformanceResult(isValid: issues.isEmpty, issues: issues)
    }
}

public enum AnalyticQueryCompiler {
    public static func compile(
        question: String,
        schema: DatabaseSchema,
        defaultRowLimit: Int,
        databaseContext: String = ""
    ) -> SQLGenerationResult? {
        let intent = QueryIntentPlanner.deterministicIntent(for: question)
        guard intent.operation == .read,
            intent.measure == .countRows,
            intent.ranking?.direction == .descending,
            intent.ranking?.takeFirst == true
        else {
            return nil
        }
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        guard plan.readiness == .readyWithInterpretation || plan.readiness == .ready,
            let joinPath = plan.selectedJoinPaths.first,
            let foreignKey = joinPath.foreignKeys.first,
            let groupTable = table(
                schema: foreignKey.targetSchema,
                name: foreignKey.targetTable,
                in: schema
            ),
            let occurrenceTable = table(
                schema: foreignKey.sourceSchema,
                name: foreignKey.sourceTable,
                in: schema
            )
        else {
            return nil
        }
        let groupAlias = "g"
        let occurrenceAlias = "o"
        let groupID = qualifiedColumn(alias: groupAlias, column: foreignKey.targetColumn)
        let occurrenceFK = qualifiedColumn(alias: occurrenceAlias, column: foreignKey.sourceColumn)
        let sql = """
            SELECT \(groupID), COUNT(*) AS occurrence_count
            FROM \(qualifiedName(occurrenceTable)) AS \(occurrenceAlias)
            JOIN \(qualifiedName(groupTable)) AS \(groupAlias)
              ON \(occurrenceFK) = \(groupID)
            GROUP BY \(groupID)
            ORDER BY occurrence_count DESC
            LIMIT 1
            """
        let conformance = SQLIntentConformanceValidator.validate(sql: sql, plan: plan, schema: schema)
        guard conformance.isValid else { return nil }
        return SQLGenerationResult(
            sql: sql,
            explanation: plan.interpretationSummary.isEmpty
                ? "Generated a count-ranked query."
                : "Interpretation: \(plan.interpretationSummary)",
            assumptions: plan.interpretationSummary.isEmpty ? [] : [plan.interpretationSummary],
            referencedTables: [occurrenceTable.qualifiedName, groupTable.qualifiedName],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            groundingConcepts: plan.slots.map {
                SQLGroundingConcept(
                    term: $0.phrase,
                    kind: .entity,
                    state: $0.state,
                    required: $0.required,
                    evidence: $0.selectedCandidate?.evidence ?? $0.candidates.flatMap(\.evidence)
                )
            }
        )
    }

    private static func table(schema schemaName: String, name: String, in schema: DatabaseSchema) -> TableInfo? {
        schema.tables.first { $0.schema == schemaName && $0.name == name }
    }

    private static func qualifiedName(_ table: TableInfo) -> String {
        "\(quotedIdentifier(table.schema)).\(quotedIdentifier(table.name))"
    }

    private static func qualifiedColumn(alias: String, column: String) -> String {
        "\(alias).\(quotedIdentifier(column))"
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
