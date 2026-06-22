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
        "occur most often", "highest volume",
    ]
    private static let latestPhrases = ["latest", "newest", "most recent"]
    private static let oldestPhrases = ["oldest", "earliest"]
    private static let subjectStopWords: Set<String> = [
        "a", "an", "are", "average", "avg", "calculate", "can", "count", "distinct",
        "each", "for", "get", "have", "in", "is", "list", "me", "number", "of", "one",
        "return", "see", "show", "sum", "the", "to", "total", "unique", "what", "which",
        "with",
    ]
    private static let customBusinessTerms: Set<String> = [
        "best", "engaged", "healthy", "quality", "successful", "valuable", "win", "winning",
        "wins", "worst",
    ]
}

public enum ClarificationResolutionAction: String, Codable, Equatable, Sendable {
    case answer
    case newRequest
    case stillAmbiguous
    case cancel
}

public struct ClarificationResolution: Codable, Equatable, Sendable {
    public var action: ClarificationResolutionAction
    public var selectedOptionIndex: Int?
    public var normalizedDefinition: String
    public var mentionedSchemaTerms: [String]

    public init(
        action: ClarificationResolutionAction,
        selectedOptionIndex: Int? = nil,
        normalizedDefinition: String = "",
        mentionedSchemaTerms: [String] = []
    ) {
        self.action = action
        self.selectedOptionIndex = selectedOptionIndex
        self.normalizedDefinition = normalizedDefinition
        self.mentionedSchemaTerms = mentionedSchemaTerms
    }
}

public enum ClarificationResolver {
    public static func resolve(
        reply: String,
        pending: PendingClarification,
        selectedOption: ClarificationOption? = nil
    ) -> ClarificationResolution {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalize(trimmed)
        guard !normalized.isEmpty else {
            return ClarificationResolution(action: .stillAmbiguous)
        }
        if ["cancel", "stop", "never mind", "nevermind"].contains(normalized) {
            return ClarificationResolution(action: .cancel)
        }
        if let selectedOption,
            let index = pending.options.firstIndex(where: { $0.id == selectedOption.id })
        {
            return ClarificationResolution(
                action: .answer,
                selectedOptionIndex: index,
                normalizedDefinition: selectedOption.definition,
                mentionedSchemaTerms: mentionedTerms(in: selectedOption.definition, pending: pending)
            )
        }
        if let index = pending.options.firstIndex(where: {
            normalize($0.replyText) == normalized || normalize($0.label) == normalized
        }) {
            return ClarificationResolution(
                action: .answer,
                selectedOptionIndex: index,
                normalizedDefinition: pending.options[index].definition,
                mentionedSchemaTerms: mentionedTerms(in: pending.options[index].definition, pending: pending)
            )
        }
        if isAffirmative(normalized) {
            guard pending.options.count == 1 else {
                return ClarificationResolution(action: .stillAmbiguous)
            }
            return ClarificationResolution(
                action: .answer,
                selectedOptionIndex: 0,
                normalizedDefinition: pending.options[0].definition,
                mentionedSchemaTerms: mentionedTerms(in: pending.options[0].definition, pending: pending)
            )
        }
        if isNegative(normalized) {
            return ClarificationResolution(action: .stillAmbiguous)
        }
        if isDirectSQL(normalized) || isQuestionLike(normalized) {
            return ClarificationResolution(action: .newRequest)
        }
        return ClarificationResolution(
            action: .answer,
            normalizedDefinition: trimmed,
            mentionedSchemaTerms: mentionedTerms(in: trimmed, pending: pending)
        )
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?, \n\t"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isAffirmative(_ normalized: String) -> Bool {
        [
            "y", "yes", "yeah", "yep", "correct", "right", "that's right",
            "that is right", "sounds good", "ok", "okay", "sure", "use that",
            "do that", "exactly",
        ].contains(normalized)
    }

    private static func isNegative(_ normalized: String) -> Bool {
        [
            "n", "no", "nope", "nah", "not sure", "i don't know", "i dont know",
            "unknown", "something else",
        ].contains(normalized)
    }

    private static func isDirectSQL(_ normalized: String) -> Bool {
        ["select", "with", "insert", "update", "delete"].contains {
            normalized == $0 || normalized.hasPrefix("\($0) ")
        }
    }

    private static func isQuestionLike(_ normalized: String) -> Bool {
        var tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        while let first = tokens.first, questionPrefixFillers.contains(first) {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return false }
        let starters: Set<String> = [
            "average", "avg", "calculate", "count", "distinct", "find", "give", "how",
            "latest", "list", "max", "maximum", "min", "minimum", "most", "oldest",
            "return", "show", "sum", "total", "unique", "what", "when", "where",
            "which", "who", "why",
        ]
        return normalized.contains("?") || starters.contains(first)
    }

    private static let questionPrefixFillers: Set<String> = [
        "actually", "also", "can", "could", "do", "does", "did", "just", "now",
        "ok", "okay", "please", "then", "will", "would", "you",
    ]

    private static func mentionedTerms(
        in text: String,
        pending: PendingClarification
    ) -> [String] {
        let tokens = Set(SchemaIndex.tokens(in: text))
        guard !tokens.isEmpty else { return [] }
        return pending.options.flatMap { option in
            ([option.label] + option.evidence).filter { candidate in
                !Set(SchemaIndex.tokens(in: candidate)).intersection(tokens).isEmpty
            }
        }
    }
}

public enum GroundedQueryPlanner {
    public static func ground(
        intent: QueryIntentFrame,
        schema: DatabaseSchema,
        referencedTables: [String] = [],
        confirmedSemanticBindings: [String] = []
    ) -> GroundedQueryPlan {
        var slots: [GroundingSlot] = []
        var selectedTables: [String] = []
        var selectedJoinPaths: [SchemaJoinPath] = []
        let bindingHints = bindingHints(from: confirmedSemanticBindings)
        let subjectPhrase = (intent.groupingPhrases.first ?? intent.subjectPhrases.first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectCandidates = rankedTables(matching: subjectPhrase, schema: schema)
        let subjectBindingHint = bindingHint(
            for: subjectPhrase,
            kind: .subjectEntity,
            hints: bindingHints
        )
        let selectedSubjectFromBinding = tableCandidate(
            matching: subjectBindingHint,
            candidates: subjectCandidates
        )
            ?? tableCandidate(matching: subjectBindingHint, schema: schema)
        let selectedSubjectCandidate = selectedSubjectFromBinding
            ?? (subjectCandidates.count == 1 ? subjectCandidates[0] : nil)
        let selectedSubject = selectedSubjectCandidate?.table ?? subjectCandidates.first?.table
        let subjectSlotCandidates = rankedTableCandidates(
            subjectCandidates,
            selectedCandidate: selectedSubjectCandidate
        )
        slots.append(
            GroundingSlot(
                id: .subject,
                kind: .subjectEntity,
                phrase: subjectPhrase,
                required: !subjectPhrase.isEmpty,
                candidates: subjectSlotCandidates,
                selectedCandidate: selectedSubjectCandidate?.candidate,
                state: selectedSubjectCandidate == nil
                    ? (subjectCandidates.isEmpty ? .unsupported : .ambiguous)
                    : .grounded
            )
        )
        if let selectedSubject {
            selectedTables.append(selectedSubject.qualifiedName)
        }

        for term in intent.customBusinessTerms {
            let binding = bindingHint(for: term, kind: .customBusinessTerm, hints: bindingHints)
            let schemaCandidates = schemaObjectCandidates(
                matching: term,
                selectedSubject: selectedSubject,
                schema: schema
            )
            let bindingCandidate = binding.map {
                GroundingCandidate(
                    id: "binding:\(term)",
                    label: $0.normalizedDefinition,
                    objectIDs: Array($0.objectIDs).sorted(),
                    evidence: [$0.normalizedDefinition]
                )
            }
            let selectedCandidate = bindingCandidate ?? (schemaCandidates.count == 1 ? schemaCandidates[0] : nil)
            slots.append(
                GroundingSlot(
                    id: .customBusinessTerm,
                    kind: .customBusinessTerm,
                    phrase: term,
                    required: true,
                    candidates: ([bindingCandidate].compactMap { $0 } + schemaCandidates),
                    selectedCandidate: selectedCandidate,
                    state: selectedCandidate == nil
                        ? (schemaCandidates.count > 1 ? .ambiguous : .unsupported)
                        : .grounded
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
            let occurrenceSlotPhrase = occurrencePhrase(for: intent)
            let selectedFromBinding = occurrenceCandidate(
                matching: bindingHint(
                    for: occurrenceSlotPhrase,
                    kind: .occurrenceRelation,
                    hints: bindingHints
                ),
                candidates: occurrence
            )
            let selected = selectedFromBinding ?? (occurrence.count == 1 ? occurrence[0] : nil)
            slots.append(
                GroundingSlot(
                    id: .occurrenceRelation,
                    kind: .occurrenceRelation,
                    phrase: occurrenceSlotPhrase,
                    required: true,
                    candidates: occurrence.map(\.candidate),
                    selectedCandidate: selected?.candidate,
                    state: occurrence.isEmpty
                        ? .unsupported
                        : (selected == nil ? .ambiguous : .grounded)
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

    private struct BindingHint {
        var phraseTokens: Set<String>
        var normalizedDefinition: String
        var objectIDs: Set<String>
        var definitionTokens: Set<String>
    }

    private static func bindingHints(from lines: [String]) -> [BindingHint] {
        lines.compactMap { line -> BindingHint? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let phrase = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !definition.isEmpty else { return nil }
            return BindingHint(
                phraseTokens: Set(SchemaIndex.tokens(in: phrase)),
                normalizedDefinition: definition,
                objectIDs: objectIDs(in: definition),
                definitionTokens: Set(SchemaIndex.tokens(in: definition))
            )
        }
    }

    private static func objectIDs(in definition: String) -> Set<String> {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        return Set(
            definition
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".()[]{}\"'")) }
                .filter { value in
                    value.hasPrefix("table:")
                        || value.hasPrefix("column:")
                        || value.hasPrefix("fk:")
                }
        )
    }

    private static func bindingHint(
        for phrase: String,
        kind: GroundingSlotKind,
        hints: [BindingHint]
    ) -> BindingHint? {
        let phraseTokens = Set(SchemaIndex.tokens(in: phrase))
        guard !phraseTokens.isEmpty else { return nil }
        return hints.first { hint in
            let overlap = phraseTokens.intersection(hint.phraseTokens)
            switch kind {
            case .occurrenceRelation, .relationshipPath:
                return overlap.count >= min(2, phraseTokens.count)
                    || (!hint.objectIDs.isEmpty && !overlap.isEmpty)
            default:
                return overlap.count == phraseTokens.count
                    || hint.phraseTokens.intersection(phraseTokens).count >= 1
            }
        }
    }

    private static func occurrenceCandidate(
        matching hint: BindingHint?,
        candidates: [OccurrenceCandidate]
    ) -> OccurrenceCandidate? {
        guard let hint else { return nil }
        if !hint.objectIDs.isEmpty {
            let matching = candidates.filter { candidate in
                !Set(candidate.candidate.objectIDs).intersection(hint.objectIDs).isEmpty
            }
            if matching.count == 1 { return matching[0] }
        }
        let matching = candidates.filter { candidate in
            let candidateTokens = Set(
                SchemaIndex.tokens(
                    in: ([candidate.candidate.label] + candidate.candidate.evidence).joined(separator: " ")
                )
            )
            return !candidateTokens.intersection(hint.definitionTokens).isEmpty
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func tableCandidate(
        matching hint: BindingHint?,
        candidates: [RankedTable]
    ) -> RankedTable? {
        guard let hint else { return nil }
        if !hint.objectIDs.isEmpty {
            let matching = candidates.filter { candidate in
                !Set(candidate.candidate.objectIDs).intersection(hint.objectIDs).isEmpty
            }
            if matching.count == 1 { return matching[0] }
        }
        let matching = candidates.filter { candidate in
            let candidateTokens = Set(
                SchemaIndex.tokens(
                    in: ([candidate.candidate.label] + candidate.candidate.evidence).joined(separator: " ")
                )
            )
            return !candidateTokens.intersection(hint.definitionTokens).isEmpty
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func tableCandidate(
        matching hint: BindingHint?,
        schema: DatabaseSchema
    ) -> RankedTable? {
        guard let hint, !hint.objectIDs.isEmpty else { return nil }
        let tableIDs = Set(hint.objectIDs.compactMap { objectID -> String? in
            if objectID.hasPrefix("table:") {
                return String(objectID.dropFirst("table:".count))
            }
            if objectID.hasPrefix("column:") {
                let value = String(objectID.dropFirst("column:".count))
                let parts = value.split(separator: ".").map(String.init)
                guard parts.count >= 3 else { return nil }
                return "\(parts[0]).\(parts[1])"
            }
            return nil
        })
        let matches = schema.tables.filter { tableIDs.contains($0.id) }
        guard matches.count == 1, let table = matches.first else { return nil }
        return RankedTable(
            table: table,
            score: 1_000,
            candidate: GroundingCandidate(
                id: "table:\(table.id)",
                label: table.qualifiedName,
                objectIDs: ["table:\(table.id)"],
                evidence: [hint.normalizedDefinition, table.qualifiedName]
            )
        )
    }

    private static func rankedTableCandidates(
        _ rankedTables: [RankedTable],
        selectedCandidate: RankedTable?
    ) -> [GroundingCandidate] {
        var seen = Set<String>()
        var candidates: [GroundingCandidate] = []
        if let selectedCandidate {
            candidates.append(selectedCandidate.candidate)
            seen.insert(selectedCandidate.candidate.id)
        }
        for rankedTable in rankedTables where seen.insert(rankedTable.candidate.id).inserted {
            candidates.append(rankedTable.candidate)
        }
        return candidates
    }

    private static func schemaObjectCandidates(
        matching phrase: String,
        selectedSubject: TableInfo?,
        schema: DatabaseSchema
    ) -> [GroundingCandidate] {
        let phraseTokens = Set(SchemaIndex.tokens(in: phrase))
        guard !phraseTokens.isEmpty else { return [] }
        let preferredTableID = selectedSubject?.id
        let matches = schema.tables.flatMap { table -> [(GroundingCandidate, Int)] in
            let tableTokens = Set(SchemaIndex.tokens(in: table.name))
            var tableMatches: [(GroundingCandidate, Int)] = []
            if phraseTokens.contains(where: { tableTokens.contains($0) }) {
                let score = 40 + (table.id == preferredTableID ? 20 : 0)
                tableMatches.append(
                    (
                        GroundingCandidate(
                            id: "schema:table:\(table.id)",
                            label: table.qualifiedName,
                            objectIDs: ["table:\(table.id)"],
                            evidence: [table.qualifiedName]
                        ),
                        score
                    )
                )
            }
            let columnMatches = table.columns.compactMap { column -> (GroundingCandidate, Int)? in
                let columnTokens = Set(SchemaIndex.tokens(in: column.name))
                guard phraseTokens.contains(where: { columnTokens.contains($0) }) else {
                    return nil
                }
                let exact = column.name.caseInsensitiveCompare(phrase.replacingOccurrences(of: " ", with: "_")) == .orderedSame
                let score = (exact ? 100 : 50) + (table.id == preferredTableID ? 25 : 0)
                return (
                    GroundingCandidate(
                        id: "schema:column:\(column.id)",
                        label: "\(table.qualifiedName).\(column.name)",
                        objectIDs: ["column:\(column.id)"],
                        evidence: ["\(table.qualifiedName).\(column.name)"]
                    ),
                    score
                )
            }
            return tableMatches + columnMatches
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.label < rhs.0.label : lhs.1 > rhs.1
        }
        guard let topScore = matches.first?.1 else { return [] }
        return matches.filter { $0.1 == topScore }.map(\.0)
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
        let tokens = SQLToken.tokenize(sql)
        let sqlStringLiterals = Set(stringLiteralBodies(in: sql).map { $0.lowercased() })
        var issues: [String] = []
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        let storedCountColumn = selectedStoredCountColumnObjectID(in: plan)
        let usesStoredCountColumn = storedCountColumn.map {
            referencesColumn(objectID: $0, in: schemaValidation.analysis, schema: schema)
        } ?? false
        let hasCountAggregate = containsAggregateFunction(named: "count", in: tokens)
        if storedCountColumn != nil, !usesStoredCountColumn {
            issues.append("Stored count intent requires the selected count column.")
        }
        if plan.intent.measure == .countRows,
            !hasCountAggregate,
            !usesStoredCountColumn
        {
            issues.append("Frequency intent requires COUNT.")
        }
        if !plan.intent.groupingPhrases.isEmpty, !usesStoredCountColumn {
            if plan.intent.measure == .countRows {
                if !hasGroupedCountForFrequencyEntity(
                    plan: plan,
                    tokens: tokens,
                    analysis: schemaValidation.analysis,
                    schema: schema
                ) {
                    issues.append("Frequency intent requires GROUP BY for the requested entity.")
                }
            } else if !hasTopLevelClausePair("group", "by", in: tokens),
                !hasNestedAverageCountGrouping(plan: plan, tokens: tokens)
            {
                issues.append("Frequency intent requires GROUP BY for the requested entity.")
            }
        }
        if plan.intent.ranking?.direction == .descending {
            let orderByClause = topLevelOrderByClause(in: tokens)
            let primarySortKey = orderByClause.flatMap(primaryOrderBySortKey)
            if primarySortKey == nil || primarySortKey?.tokens.contains(where: { $0.normalized == "desc" }) != true {
                issues.append("Descending ranking intent requires ORDER BY ... DESC.")
            }
            if plan.intent.measure == .countRows,
                let primarySortKey
            {
                if let storedCountColumn {
                    if !referencesColumn(
                        objectID: storedCountColumn,
                        in: schemaValidation.analysis,
                        schema: schema,
                        offsetRange: primarySortKey.offsetRange
                    ) {
                        issues.append("Frequency ranking must order by the selected count column.")
                    }
                } else {
                    let countAliases = aggregateAliases(named: "count", in: tokens)
                    if !orderByUsesAggregateMetric(
                        named: "count",
                        aliases: countAliases,
                        orderByTokens: primarySortKey.tokens,
                        selectItems: topLevelSelectItems(in: tokens)
                    ) {
                        issues.append("Frequency ranking must order by the count metric.")
                    }
                }
            }
        }
        if plan.intent.ranking?.takeFirst == true || plan.intent.requestedLimit == 1 {
            if !hasTopLevelLimitOne(in: tokens) {
                issues.append("Singular top result intent requires LIMIT 1.")
            }
        }
        let referenced = Set(schemaValidation.referencedTables)
        for table in plan.selectedTables where !referenced.contains(table) {
            issues.append("SQL does not reference grounded table \(table).")
        }
        for joinPath in plan.selectedJoinPaths {
            for foreignKey in joinPath.foreignKeys {
                let sourceObjectID = "column:\(foreignKey.sourceSchema).\(foreignKey.sourceTable).\(foreignKey.sourceColumn)"
                let targetObjectID = "column:\(foreignKey.targetSchema).\(foreignKey.targetTable).\(foreignKey.targetColumn)"
                if !hasColumnEquality(
                    sourceObjectID: sourceObjectID,
                    targetObjectID: targetObjectID,
                    in: schemaValidation.analysis,
                    schema: schema,
                    tokens: tokens
                )
                {
                    issues.append("SQL does not use grounded join path \(foreignKey.constraintName).")
                }
            }
        }
        for slot in plan.slots where slot.kind == .customBusinessTerm {
            guard slot.state == .grounded, let candidate = slot.selectedCandidate else { continue }
            for objectID in candidate.objectIDs where objectID.hasPrefix("column:") {
                if !referencesColumn(objectID: objectID, in: schemaValidation.analysis, schema: schema) {
                    issues.append("SQL does not reference grounded definition object \(objectID).")
                }
            }
            for literal in stringLiteralBodies(in: ([candidate.label] + candidate.evidence).joined(separator: " ")) {
                if !sqlStringLiterals.contains(literal.lowercased()) {
                    issues.append("SQL does not include grounded definition literal '\(literal)'.")
                }
            }
        }
        return SQLIntentConformanceResult(isValid: issues.isEmpty, issues: issues)
    }

    private static func selectedStoredCountColumnObjectID(in plan: GroundedQueryPlan) -> String? {
        plan.slots
            .first { $0.kind == .occurrenceRelation }?
            .selectedCandidate?
            .objectIDs
            .first { $0.hasPrefix("column:") }
    }

    private static func referencesColumn(
        objectID: String,
        in analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema,
        offsetRange: Range<Int>? = nil
    ) -> Bool {
        guard let columnRef = columnObjectReference(from: objectID) else { return false }
        let tableQualifiers = qualifiers(for: columnRef.tableID, in: analysis)
        let columns = Set(analysis.columns + analysis.scopes.flatMap(\.columns))
        for column in columns {
            if let offsetRange {
                guard let start = column.startOffset,
                    let end = column.endOffset,
                    offsetRange.contains(start),
                    end <= offsetRange.upperBound
                else {
                    continue
                }
            }
            guard columnNameMatches(column.name, columnRef.column, isQuoted: column.isQuoted) else {
                continue
            }
            if let qualifier = column.qualifier {
                if tableQualifiers.contains(where: {
                    qualifierMatches(
                        qualifier,
                        qualifierIsQuoted: column.qualifierIsQuoted,
                        expected: $0.name,
                        expectedIsQuoted: $0.isQuoted
                    )
                }) {
                    return true
                }
                continue
            }
            let matchingTables = referencedTables(in: analysis, schema: schema).filter {
                $0.columns.contains { columnNameMatches(column.name, $0.name, isQuoted: column.isQuoted) }
            }
            if matchingTables.count == 1, matchingTables[0].id == columnRef.tableID {
                return true
            }
        }
        return false
    }

    private static func hasColumnEquality(
        sourceObjectID: String,
        targetObjectID: String,
        in analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema,
        tokens: [SQLToken]
    ) -> Bool {
        guard let sourceReference = columnObjectReference(from: sourceObjectID),
            let targetReference = columnObjectReference(from: targetObjectID)
        else {
            return false
        }
        for index in tokens.indices where tokens[index].text == "=" {
            guard let leftRange = expressionOffsetRange(before: index, tokens: tokens),
                let rightRange = expressionOffsetRange(after: index, tokens: tokens)
            else {
                continue
            }
            let sourceLeft = referencesColumn(
                objectID: sourceObjectID,
                in: analysis,
                schema: schema,
                offsetRange: leftRange
            ) || rangeContainsProjectedColumn(sourceReference.column, in: leftRange, tokens: tokens)
            let targetLeft = referencesColumn(
                objectID: targetObjectID,
                in: analysis,
                schema: schema,
                offsetRange: leftRange
            ) || rangeContainsProjectedColumn(targetReference.column, in: leftRange, tokens: tokens)
            let sourceRight = referencesColumn(
                objectID: sourceObjectID,
                in: analysis,
                schema: schema,
                offsetRange: rightRange
            ) || rangeContainsProjectedColumn(sourceReference.column, in: rightRange, tokens: tokens)
            let targetRight = referencesColumn(
                objectID: targetObjectID,
                in: analysis,
                schema: schema,
                offsetRange: rightRange
            ) || rangeContainsProjectedColumn(targetReference.column, in: rightRange, tokens: tokens)
            if (sourceLeft && targetRight) || (targetLeft && sourceRight) {
                return true
            }
        }
        return false
    }

    private static func rangeContainsProjectedColumn(
        _ columnName: String,
        in offsetRange: Range<Int>,
        tokens: [SQLToken]
    ) -> Bool {
        guard columnName.lowercased() != "id" else { return false }
        return tokens.contains { token in
            token.isIdentifierLike
                && offsetRange.contains(token.startOffset)
                && token.endOffset <= offsetRange.upperBound
                && token.identifierValue.caseInsensitiveCompare(columnName) == .orderedSame
        }
    }

    private static func expressionOffsetRange(
        before index: Int,
        tokens: [SQLToken]
    ) -> Range<Int>? {
        guard index > 0 else { return nil }
        var cursor = index - 1
        var depth = 0
        var start = cursor
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text == ")" {
                depth += 1
            } else if token.text == "(" {
                depth = max(0, depth - 1)
            }
            if depth == 0,
                expressionBoundaryTokens.contains(token.normalized) || token.text == ","
            {
                start = cursor + 1
                break
            }
            start = cursor
            if cursor == 0 { break }
            cursor -= 1
        }
        guard let lower = tokens[safe: start]?.startOffset,
            let upper = tokens[safe: index - 1]?.endOffset,
            lower < upper
        else {
            return nil
        }
        return lower..<upper
    }

    private static func expressionOffsetRange(
        after index: Int,
        tokens: [SQLToken]
    ) -> Range<Int>? {
        guard index + 1 < tokens.count else { return nil }
        var cursor = index + 1
        var depth = 0
        var end = cursor
        while cursor < tokens.count {
            let token = tokens[cursor]
            if depth == 0,
                expressionBoundaryTokens.contains(token.normalized) || token.text == ","
            {
                end = cursor
                break
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                if depth == 0 {
                    end = cursor
                    break
                }
                depth -= 1
            }
            end = cursor + 1
            cursor += 1
        }
        guard end > index + 1,
            let lower = tokens[safe: index + 1]?.startOffset,
            let upper = tokens[safe: end - 1]?.endOffset,
            lower < upper
        else {
            return nil
        }
        return lower..<upper
    }

    private struct ColumnObjectReference {
        var schema: String
        var table: String
        var column: String
        var tableID: String { "\(schema).\(table)" }
    }

    private struct ColumnQualifier {
        var name: String
        var isQuoted: Bool
    }

    private static func columnObjectReference(from objectID: String) -> ColumnObjectReference? {
        guard objectID.hasPrefix("column:") else { return nil }
        let parts = objectID.dropFirst("column:".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return ColumnObjectReference(
            schema: String(parts[0]),
            table: String(parts[1]),
            column: String(parts[2])
        )
    }

    private static func qualifiers(
        for tableID: String,
        in analysis: SQLReferenceAnalysis
    ) -> [ColumnQualifier] {
        analysis.relations.flatMap { relation -> [ColumnQualifier] in
            guard relationMatches(relation, tableID: tableID) else { return [] }
            var qualifiers = [
                ColumnQualifier(name: relation.name, isQuoted: relation.nameIsQuoted),
                ColumnQualifier(name: relation.displayName, isQuoted: relation.schemaIsQuoted || relation.nameIsQuoted),
            ]
            if let alias = relation.alias {
                qualifiers.append(ColumnQualifier(name: alias, isQuoted: relation.aliasIsQuoted))
            }
            return qualifiers
        }
    }

    private static func referencedTables(
        in analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema
    ) -> [TableInfo] {
        analysis.relations.compactMap { relation in
            table(matching: relation, schema: schema)
        }
    }

    private static func table(matching relation: SQLRelationReference, schema: DatabaseSchema) -> TableInfo? {
        if let relationSchema = relation.schema {
            let schemaName = relation.schemaIsQuoted ? relationSchema : relationSchema.lowercased()
            let tableName = relation.nameIsQuoted ? relation.name : relation.name.lowercased()
            return schema.tables.first { $0.schema == schemaName && $0.name == tableName }
        }
        let tableName = relation.nameIsQuoted ? relation.name : relation.name.lowercased()
        let matches = schema.tables.filter { $0.name == tableName }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func relationMatches(_ relation: SQLRelationReference, tableID: String) -> Bool {
        let tableParts = tableID.split(separator: ".", maxSplits: 1).map(String.init)
        guard tableParts.count == 2 else { return false }
        let schemaName = tableParts[0]
        let tableName = tableParts[1]
        if let relationSchema = relation.schema {
            let schemaMatches = relation.schemaIsQuoted
                ? relationSchema == schemaName
                : relationSchema.lowercased() == schemaName.lowercased()
            let tableMatches = relation.nameIsQuoted
                ? relation.name == tableName
                : relation.name.lowercased() == tableName.lowercased()
            return schemaMatches && tableMatches
        }
        return relation.nameIsQuoted
            ? relation.name == tableName
            : relation.name.lowercased() == tableName.lowercased()
    }

    private static func qualifierMatches(
        _ qualifier: String,
        qualifierIsQuoted: Bool,
        expected: String,
        expectedIsQuoted: Bool
    ) -> Bool {
        if qualifierIsQuoted || expectedIsQuoted {
            return qualifier == expected
        }
        return qualifier.lowercased() == expected.lowercased()
    }

    private static func columnNameMatches(_ actual: String, _ expected: String, isQuoted: Bool) -> Bool {
        isQuoted ? actual == expected : actual.lowercased() == expected.lowercased()
    }

    private static func containsAggregateFunction(named name: String, in tokens: [SQLToken]) -> Bool {
        tokens.indices.contains { index in
            tokens[index].normalized == name
                && tokens[safe: index + 1]?.text == "("
        }
    }

    private static func aggregateAliases(named name: String, in tokens: [SQLToken]) -> Set<String> {
        var aliases = Set<String>()
        for index in tokens.indices where tokens[index].normalized == name {
            guard tokens[safe: index + 1]?.text == "(",
                let closeIndex = matchingCloseParenIndex(openIndex: index + 1, tokens: tokens)
            else {
                continue
            }
            var aliasIndex = closeIndex + 1
            if tokens[safe: aliasIndex]?.normalized == "as" {
                aliasIndex += 1
            }
            if let alias = tokens[safe: aliasIndex],
                alias.isIdentifierLike,
                !SQLToken.keywords.contains(alias.normalized)
            {
                aliases.insert(alias.identifierValue.lowercased())
            }
        }
        return aliases
    }

    private static func orderByUsesAggregateMetric(
        named name: String,
        aliases: Set<String>,
        orderByTokens: [SQLToken],
        selectItems: [[SQLToken]]
    ) -> Bool {
        containsAggregateFunction(named: name, in: orderByTokens)
            || orderByTokens.contains {
                $0.isIdentifierLike && aliases.contains($0.identifierValue.lowercased())
            }
            || orderByOrdinalUsesAggregateMetric(
                named: name,
                aliases: aliases,
                orderByTokens: orderByTokens,
                selectItems: selectItems
            )
    }

    private static func orderByOrdinalUsesAggregateMetric(
        named name: String,
        aliases: Set<String>,
        orderByTokens: [SQLToken],
        selectItems: [[SQLToken]]
    ) -> Bool {
        guard let first = orderByTokens.first,
            first.kind == .number,
            let ordinal = Int(first.text),
            ordinal > 0,
            ordinal <= selectItems.count
        else {
            return false
        }
        let item = selectItems[ordinal - 1]
        return containsAggregateFunction(named: name, in: item)
            || item.contains {
                $0.isIdentifierLike && aliases.contains($0.identifierValue.lowercased())
            }
    }

    private static func hasNestedAverageCountGrouping(
        plan: GroundedQueryPlan,
        tokens: [SQLToken]
    ) -> Bool {
        plan.intent.measure == .average
            && containsAggregateFunction(named: "avg", in: tokens)
            && containsAggregateFunction(named: "count", in: tokens)
            && hasClausePair("group", "by", in: tokens)
    }

    private static func hasGroupedCountForFrequencyEntity(
        plan: GroundedQueryPlan,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema
    ) -> Bool {
        guard containsAggregateFunction(named: "count", in: tokens) else { return false }
        let groupingObjectIDs = frequencyGroupingObjectIDs(plan: plan, schema: schema)
        guard !groupingObjectIDs.isEmpty else {
            return hasClausePair("group", "by", in: tokens)
        }
        return groupByClauses(in: tokens).contains { clause in
            groupingObjectIDs.contains { objectID in
                referencesColumn(
                    objectID: objectID,
                    in: analysis,
                    schema: schema,
                    offsetRange: clause.offsetRange
                )
            }
        }
    }

    private static func frequencyGroupingObjectIDs(
        plan: GroundedQueryPlan,
        schema: DatabaseSchema
    ) -> Set<String> {
        var objectIDs = Set<String>()
        let requestedTokens = tokenVariants(
            Set(
                (plan.intent.groupingPhrases
                    + plan.intent.subjectPhrases
                    + plan.intent.outputPhrases)
                    .flatMap { SchemaIndex.tokens(in: $0) }
            )
        )
        let subjectObjectIDs = plan.slots
            .first { $0.kind == .subjectEntity }?
            .selectedCandidate?
            .objectIDs ?? []
        let subjectTableIDs = Set(subjectObjectIDs.compactMap { objectID -> String? in
            guard objectID.hasPrefix("table:") else { return nil }
            return String(objectID.dropFirst("table:".count))
        })
        objectIDs.formUnion(subjectObjectIDs.filter { $0.hasPrefix("column:") })
        for tableID in subjectTableIDs {
            if let table = schema.tables.first(where: { $0.id == tableID }) {
                let requestedColumnIDs = requestedFrequencyColumnObjectIDs(
                    in: table,
                    requestedTokens: requestedTokens
                )
                objectIDs.formUnion(requestedColumnIDs)
                if requestedColumnIDs.isEmpty {
                    objectIDs.formUnion(entityGroupingColumnObjectIDs(in: table))
                }
            }
        }
        for joinPath in plan.selectedJoinPaths {
            for foreignKey in joinPath.foreignKeys {
                let sourceTableID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
                let targetTableID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
                if subjectTableIDs.contains(sourceTableID) || subjectTableIDs.contains(targetTableID) {
                    objectIDs.insert("column:\(sourceTableID).\(foreignKey.sourceColumn)")
                    objectIDs.insert("column:\(targetTableID).\(foreignKey.targetColumn)")
                }
            }
        }
        return objectIDs
    }

    private static func requestedFrequencyColumnObjectIDs(
        in table: TableInfo,
        requestedTokens: Set<String>
    ) -> Set<String> {
        guard !requestedTokens.isEmpty else { return [] }
        return Set(
            table.columns.compactMap { column -> String? in
                let columnTokens = tokenVariants(Set(SchemaIndex.tokens(in: column.name)))
                guard !columnTokens.isEmpty,
                    columnTokens.isSubset(of: requestedTokens)
                        || requestedTokens.isSubset(of: columnTokens)
                else {
                    return nil
                }
                return "column:\(column.id)"
            }
        )
    }

    private static func entityGroupingColumnObjectIDs(in table: TableInfo) -> Set<String> {
        let tableTokens = tokenVariants(Set(SchemaIndex.tokens(in: table.name)))
        let tableName = table.name.lowercased()
        let singularTableName = singularToken(tableName)
        let labelNames: Set<String> = ["display_name", "label", "name", "title"]
        return Set(
            table.columns.compactMap { column -> String? in
                let columnName = column.name.lowercased()
                let columnTokens = tokenVariants(Set(SchemaIndex.tokens(in: column.name)))
                let isIdentifier =
                    columnName == "id"
                    || columnName == "\(tableName)_id"
                    || columnName == "\(singularTableName)_id"
                    || (columnTokens.contains("id")
                        && !columnTokens.isDisjoint(with: tableTokens))
                guard isIdentifier || labelNames.contains(columnName) else { return nil }
                return "column:\(column.id)"
            }
        )
    }

    private static func tokenVariants(_ tokens: Set<String>) -> Set<String> {
        Set(tokens.flatMap { token -> [String] in
            let singular = singularToken(token)
            return singular == token ? [token] : [token, singular]
        })
    }

    private static func singularToken(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 3 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("ses"), token.count > 3 {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s"), token.count > 1 {
            return String(token.dropLast())
        }
        return token
    }

    private static func topLevelOrderByClause(in tokens: [SQLToken]) -> (
        tokens: [SQLToken], offsetRange: Range<Int>
    )? {
        var depth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if depth == 0,
                token.normalized == "order",
                tokens[safe: index + 1]?.normalized == "by"
            {
                let start = index + 2
                var end = start
                var clauseDepth = 0
                while end < tokens.count {
                    let current = tokens[end]
                    if clauseDepth == 0,
                        ["limit", "offset", "fetch", "union", "intersect", "except"].contains(current.normalized)
                    {
                        break
                    }
                    if current.text == "(" {
                        clauseDepth += 1
                    } else if current.text == ")" {
                        clauseDepth = max(0, clauseDepth - 1)
                    }
                    end += 1
                }
                guard start < end,
                    let lower = tokens[safe: start]?.startOffset,
                    let upper = tokens[safe: end - 1]?.endOffset
                else {
                    return nil
                }
                return (Array(tokens[start..<end]), lower..<upper)
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
            index += 1
        }
        return nil
    }

    private static func primaryOrderBySortKey(
        in clause: (tokens: [SQLToken], offsetRange: Range<Int>)
    ) -> (tokens: [SQLToken], offsetRange: Range<Int>)? {
        var depth = 0
        var end = clause.tokens.count
        for index in clause.tokens.indices {
            let token = clause.tokens[index]
            if depth == 0, token.text == "," {
                end = index
                break
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
        }
        guard end > 0,
            let lower = clause.tokens.first?.startOffset,
            let upper = clause.tokens[safe: end - 1]?.endOffset
        else {
            return nil
        }
        return (Array(clause.tokens[0..<end]), lower..<upper)
    }

    private static func topLevelSelectItems(in tokens: [SQLToken]) -> [[SQLToken]] {
        var depth = 0
        var selectIndex: Int?
        var fromIndex: Int?
        for index in tokens.indices {
            let token = tokens[index]
            if depth == 0, token.normalized == "select" {
                selectIndex = index
            } else if depth == 0, token.normalized == "from", selectIndex != nil {
                fromIndex = index
                break
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
        }
        guard let selectIndex, let fromIndex, selectIndex + 1 < fromIndex else {
            return []
        }
        return splitTopLevelItems(Array(tokens[(selectIndex + 1)..<fromIndex]))
    }

    private static func groupByClauses(in tokens: [SQLToken]) -> [(
        tokens: [SQLToken], offsetRange: Range<Int>
    )] {
        var clauses: [(tokens: [SQLToken], offsetRange: Range<Int>)] = []
        var depth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.normalized == "group",
                tokens[safe: index + 1]?.normalized == "by"
            {
                let baseDepth = depth
                let start = index + 2
                var end = start
                var clauseDepth = baseDepth
                while end < tokens.count {
                    let current = tokens[end]
                    if current.text == ")" && clauseDepth == baseDepth {
                        break
                    }
                    if clauseDepth == baseDepth,
                        groupByBoundaryTokens.contains(current.normalized)
                    {
                        break
                    }
                    if current.text == "(" {
                        clauseDepth += 1
                    } else if current.text == ")" {
                        clauseDepth = max(baseDepth, clauseDepth - 1)
                    }
                    end += 1
                }
                if start < end,
                    let lower = tokens[safe: start]?.startOffset,
                    let upper = tokens[safe: end - 1]?.endOffset
                {
                    clauses.append((Array(tokens[start..<end]), lower..<upper))
                }
                index = max(index + 1, end)
                continue
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
            index += 1
        }
        return clauses
    }

    private static func splitTopLevelItems(_ tokens: [SQLToken]) -> [[SQLToken]] {
        var items: [[SQLToken]] = []
        var start = 0
        var depth = 0
        for index in tokens.indices {
            let token = tokens[index]
            if depth == 0, token.text == "," {
                items.append(Array(tokens[start..<index]))
                start = index + 1
                continue
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
        }
        if start < tokens.count {
            items.append(Array(tokens[start..<tokens.count]))
        }
        return items.filter { !$0.isEmpty }
    }

    private static func hasTopLevelClausePair(
        _ first: String,
        _ second: String,
        in tokens: [SQLToken]
    ) -> Bool {
        var depth = 0
        for index in tokens.indices {
            let token = tokens[index]
            if depth == 0,
                token.normalized == first,
                tokens[safe: index + 1]?.normalized == second
            {
                return true
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
        }
        return false
    }

    private static func hasClausePair(
        _ first: String,
        _ second: String,
        in tokens: [SQLToken]
    ) -> Bool {
        tokens.indices.contains { index in
            tokens[index].normalized == first
                && tokens[safe: index + 1]?.normalized == second
        }
    }

    private static func hasTopLevelLimitOne(in tokens: [SQLToken]) -> Bool {
        var depth = 0
        for index in tokens.indices {
            let token = tokens[index]
            if depth == 0,
                token.normalized == "limit",
                tokens[safe: index + 1]?.text == "1"
            {
                return true
            }
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
        }
        return false
    }

    private static func matchingCloseParenIndex(openIndex: Int, tokens: [SQLToken]) -> Int? {
        guard tokens[safe: openIndex]?.text == "(" else { return nil }
        var depth = 0
        for index in openIndex..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func stringLiteralBodies(in text: String) -> [String] {
        SQLToken.tokenize(text).compactMap { token -> String? in
            guard token.kind == .string,
                let firstQuote = token.text.firstIndex(of: "'"),
                let lastQuote = token.text.lastIndex(of: "'"),
                firstQuote < lastQuote
            else {
                return nil
            }
            return String(token.text[token.text.index(after: firstQuote)..<lastQuote])
                .replacingOccurrences(of: "''", with: "'")
        }
    }

    private static let expressionBoundaryTokens: Set<String> = [
        "and", "by", "from", "group", "having", "join", "limit", "offset", "on", "or",
        "order", "select", "using", "where",
    ]

    private static let groupByBoundaryTokens: Set<String> = [
        "except", "fetch", "having", "intersect", "limit", "offset", "order", "union",
        "where",
    ]
}

public enum AnalyticQueryCompiler {
    public static func compile(
        question: String,
        schema: DatabaseSchema,
        defaultRowLimit: Int,
        databaseContext: String = ""
    ) -> SQLGenerationResult? {
        let intent = QueryIntentPlanner.deterministicIntent(for: question)
        guard intent.operation == .read else { return nil }
        guard intent.timeIntent == nil else { return nil }
        if intent.measure == .countRows,
            intent.ranking?.direction == .descending,
            intent.ranking?.takeFirst == true
        {
            return compileTopCountOverJoin(intent: intent, schema: schema)
                ?? compileTopCountOverColumn(intent: intent, schema: schema)
        }
        if intent.measure == .none,
            let ranking = intent.ranking,
            ranking.takeFirst
        {
            return compileRankedRow(intent: intent, schema: schema, direction: ranking.direction)
        }
        if intent.measure == .average,
            !intent.groupingPhrases.isEmpty
        {
            if let averageRows = compileAverageRowsPerTimeBucket(intent: intent, schema: schema) {
                return averageRows
            }
        }
        if [.average, .countDistinct, .sum, .minimum, .maximum].contains(intent.measure),
            !intent.groupingPhrases.isEmpty
        {
            return compileGroupedMeasure(intent: intent, schema: schema, defaultRowLimit: defaultRowLimit)
        }
        return nil
    }

    private static func compileTopCountOverJoin(
        intent: QueryIntentFrame,
        schema: DatabaseSchema
    ) -> SQLGenerationResult? {
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        guard plan.readiness == .readyWithInterpretation || plan.readiness == .ready,
            let joinPath = plan.selectedJoinPaths.first,
            let foreignKey = joinPath.foreignKeys.first
        else {
            return nil
        }
        let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
        let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
        let subjectTableID = selectedSubjectTableID(in: plan) ?? targetID
        let groupSchema: String
        let groupName: String
        let groupColumnName: String
        let occurrenceSchema: String
        let occurrenceName: String
        let occurrenceColumnName: String
        if subjectTableID == sourceID {
            groupSchema = foreignKey.sourceSchema
            groupName = foreignKey.sourceTable
            groupColumnName = foreignKey.sourceColumn
            occurrenceSchema = foreignKey.targetSchema
            occurrenceName = foreignKey.targetTable
            occurrenceColumnName = foreignKey.targetColumn
        } else if subjectTableID == targetID {
            groupSchema = foreignKey.targetSchema
            groupName = foreignKey.targetTable
            groupColumnName = foreignKey.targetColumn
            occurrenceSchema = foreignKey.sourceSchema
            occurrenceName = foreignKey.sourceTable
            occurrenceColumnName = foreignKey.sourceColumn
        } else {
            return nil
        }
        guard let groupTable = table(schema: groupSchema, name: groupName, in: schema),
            let occurrenceTable = table(schema: occurrenceSchema, name: occurrenceName, in: schema)
        else {
            return nil
        }
        let groupAlias = "g"
        let occurrenceAlias = "o"
        let groupID = qualifiedColumn(alias: groupAlias, column: groupColumnName)
        let occurrenceFK = qualifiedColumn(alias: occurrenceAlias, column: occurrenceColumnName)
        let sql = """
            SELECT \(groupID), COUNT(*) AS occurrence_count
            FROM \(qualifiedName(occurrenceTable)) AS \(occurrenceAlias)
            JOIN \(qualifiedName(groupTable)) AS \(groupAlias)
              ON \(occurrenceFK) = \(groupID)
            GROUP BY \(groupID)
            ORDER BY occurrence_count DESC
            LIMIT 1
            """
        return result(
            sql: sql,
            plan: plan,
            schema: schema,
            referencedTables: [occurrenceTable.qualifiedName, groupTable.qualifiedName],
            fallbackExplanation: "Generated a count-ranked query."
        )
    }

    private static func compileTopCountOverColumn(
        intent: QueryIntentFrame,
        schema: DatabaseSchema
    ) -> SQLGenerationResult? {
        guard let phrase = intent.groupingPhrases.first ?? intent.subjectPhrases.first,
            let match = uniqueColumn(matching: phrase, schema: schema),
            let table = table(schema: match.column.tableSchema, name: match.column.tableName, in: schema)
        else {
            return nil
        }
        let alias = "t"
        let dimension = qualifiedColumn(alias: alias, column: match.column.name)
        let sql = """
            SELECT \(dimension), COUNT(*) AS occurrence_count
            FROM \(qualifiedName(table)) AS \(alias)
            GROUP BY \(dimension)
            ORDER BY occurrence_count DESC
            LIMIT 1
            """
        let interpretation = "\"\(intent.measurePhrase ?? "count")\" means count rows in \(table.qualifiedName), grouped by \(match.column.name)."
        let plan = compiledPlan(
            intent: intent,
            selectedTables: [table.qualifiedName],
            phrase: phrase,
            evidence: ["\(table.qualifiedName).\(match.column.name)"],
            interpretation: interpretation
        )
        return result(
            sql: sql,
            plan: plan,
            schema: schema,
            referencedTables: [table.qualifiedName],
            fallbackExplanation: "Generated a count-ranked query."
        )
    }

    private static func compileRankedRow(
        intent: QueryIntentFrame,
        schema: DatabaseSchema,
        direction: RankingDirection
    ) -> SQLGenerationResult? {
        guard let phrase = intent.subjectPhrases.first,
            let table = uniqueTable(matching: phrase, schema: schema),
            let column = preferredTemporalColumn(in: table)
        else {
            return nil
        }
        let alias = "t"
        let directionSQL = direction == .descending ? "DESC" : "ASC"
        let sql = """
            SELECT \(alias).*
            FROM \(qualifiedName(table)) AS \(alias)
            ORDER BY \(qualifiedColumn(alias: alias, column: column.name)) \(directionSQL)
            LIMIT 1
            """
        let interpretation = "Rank \(table.qualifiedName) by \(column.name) \(directionSQL.lowercased()) and take the first row."
        let plan = compiledPlan(
            intent: intent,
            selectedTables: [table.qualifiedName],
            phrase: phrase,
            evidence: ["\(table.qualifiedName).\(column.name)"],
            interpretation: interpretation
        )
        return result(
            sql: sql,
            plan: plan,
            schema: schema,
            referencedTables: [table.qualifiedName],
            fallbackExplanation: "Generated a ranked-row query."
        )
    }

    private static func compileAverageRowsPerTimeBucket(
        intent: QueryIntentFrame,
        schema: DatabaseSchema
    ) -> SQLGenerationResult? {
        guard let subjectPhrase = intent.subjectPhrases.first,
            let table = uniqueTable(matching: subjectPhrase, schema: schema),
            let group = groupingSelection(for: intent.groupingPhrases[0], table: table),
            ["day", "date", "week", "month", "year"].contains(
                intent.groupingPhrases[0].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            return nil
        }
        let alias = "t"
        let groupExpression = group.expression(alias)
        let sql = """
            SELECT AVG(row_count) AS \(quotedIdentifier("average_\(safeAlias(table.name))_per_\(group.alias)"))
            FROM (
              SELECT \(groupExpression) AS \(quotedIdentifier(group.alias)), COUNT(*) AS row_count
              FROM \(qualifiedName(table)) AS \(alias)
              GROUP BY \(groupExpression)
            ) AS grouped_counts
            """
        let interpretation = "Average row count in \(table.qualifiedName) per \(group.alias)."
        let plan = compiledPlan(
            intent: intent,
            selectedTables: [table.qualifiedName],
            phrase: subjectPhrase,
            evidence: ["\(table.qualifiedName).\(group.label)"],
            interpretation: interpretation
        )
        return result(
            sql: sql,
            plan: plan,
            schema: schema,
            referencedTables: [table.qualifiedName],
            fallbackExplanation: "Generated an average per-time-bucket query."
        )
    }

    private static func compileGroupedMeasure(
        intent: QueryIntentFrame,
        schema: DatabaseSchema,
        defaultRowLimit: Int
    ) -> SQLGenerationResult? {
        guard let subjectPhrase = intent.subjectPhrases.first,
            let subject = uniqueColumn(
                matching: subjectPhrase,
                schema: schema,
                requireNumeric: intent.measure != .countDistinct
            ),
            let table = table(
                schema: subject.column.tableSchema,
                name: subject.column.tableName,
                in: schema
            ),
            let group = groupingSelection(for: intent.groupingPhrases[0], table: table)
        else {
            return nil
        }
        let alias = "t"
        let measureSQL: String
        let measureAlias: String
        switch intent.measure {
        case .countDistinct:
            measureSQL = "COUNT(DISTINCT \(qualifiedColumn(alias: alias, column: subject.column.name)))"
            measureAlias = "distinct_\(safeAlias(subject.column.name))_count"
        case .average:
            measureSQL = "AVG(\(qualifiedColumn(alias: alias, column: subject.column.name)))"
            measureAlias = "average_\(safeAlias(subject.column.name))"
        case .sum:
            measureSQL = "SUM(\(qualifiedColumn(alias: alias, column: subject.column.name)))"
            measureAlias = "total_\(safeAlias(subject.column.name))"
        case .minimum:
            measureSQL = "MIN(\(qualifiedColumn(alias: alias, column: subject.column.name)))"
            measureAlias = "minimum_\(safeAlias(subject.column.name))"
        case .maximum:
            measureSQL = "MAX(\(qualifiedColumn(alias: alias, column: subject.column.name)))"
            measureAlias = "maximum_\(safeAlias(subject.column.name))"
        default:
            return nil
        }
        let groupExpression = group.expression(alias)
        let sql = """
            SELECT \(groupExpression) AS \(quotedIdentifier(group.alias)), \(measureSQL) AS \(quotedIdentifier(measureAlias))
            FROM \(qualifiedName(table)) AS \(alias)
            GROUP BY \(groupExpression)
            LIMIT \(sanitizedLimit(defaultRowLimit))
            """
        let interpretation = "\(intent.measure.rawValue) of \(subject.column.name), grouped by \(group.label)."
        let plan = compiledPlan(
            intent: intent,
            selectedTables: [table.qualifiedName],
            phrase: subjectPhrase,
            evidence: [
                "\(table.qualifiedName).\(subject.column.name)",
                "\(table.qualifiedName).\(group.label)",
            ],
            interpretation: interpretation
        )
        return result(
            sql: sql,
            plan: plan,
            schema: schema,
            referencedTables: [table.qualifiedName],
            fallbackExplanation: "Generated a grouped aggregate query."
        )
    }

    private static func selectedSubjectTableID(in plan: GroundedQueryPlan) -> String? {
        plan.slots
            .first { $0.kind == .subjectEntity }?
            .selectedCandidate?
            .objectIDs
            .compactMap { objectID -> String? in
                guard objectID.hasPrefix("table:") else { return nil }
                return String(objectID.dropFirst("table:".count))
            }
            .first
    }

    private static func sanitizedLimit(_ limit: Int) -> Int {
        max(1, limit)
    }

    private struct ColumnMatch {
        var column: ColumnInfo
        var score: Int
    }

    private struct GroupingSelection {
        var label: String
        var alias: String
        var expression: (String) -> String
    }

    private static func result(
        sql: String,
        plan: GroundedQueryPlan,
        schema: DatabaseSchema,
        referencedTables: [String],
        fallbackExplanation: String
    ) -> SQLGenerationResult? {
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        guard !schemaValidation.hasDefiniteErrors else { return nil }
        let conformance = SQLIntentConformanceValidator.validate(sql: sql, plan: plan, schema: schema)
        guard conformance.isValid else { return nil }
        return SQLGenerationResult(
            sql: sql,
            explanation: plan.interpretationSummary.isEmpty
                ? fallbackExplanation
                : "Interpretation: \(plan.interpretationSummary)",
            assumptions: plan.interpretationSummary.isEmpty ? [] : [plan.interpretationSummary],
            referencedTables: referencedTables,
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

    private static func compiledPlan(
        intent: QueryIntentFrame,
        selectedTables: [String],
        phrase: String,
        evidence: [String],
        interpretation: String
    ) -> GroundedQueryPlan {
        GroundedQueryPlan(
            intent: intent,
            slots: [
                GroundingSlot(
                    id: .subject,
                    kind: .subjectEntity,
                    phrase: phrase,
                    required: true,
                    selectedCandidate: GroundingCandidate(
                        id: "compiled:\(phrase)",
                        label: evidence.first ?? phrase,
                        evidence: evidence
                    ),
                    state: .grounded
                )
            ],
            selectedTables: selectedTables,
            readiness: .readyWithInterpretation,
            interpretationSummary: interpretation
        )
    }

    private static func table(schema schemaName: String, name: String, in schema: DatabaseSchema) -> TableInfo? {
        schema.tables.first { $0.schema == schemaName && $0.name == name }
    }

    private static func uniqueTable(matching phrase: String, schema: DatabaseSchema) -> TableInfo? {
        let phraseTokens = Set(SchemaIndex.tokens(in: phrase))
        guard !phraseTokens.isEmpty else { return nil }
        let matches = schema.tables.compactMap { table -> (TableInfo, Int)? in
            let tableTokens = Set(SchemaIndex.tokens(in: table.name))
            let columnTokens = Set(table.columns.flatMap { SchemaIndex.tokens(in: $0.name) })
            let exact = table.name.lowercased() == phrase.replacingOccurrences(of: " ", with: "_")
            let score = (exact ? 100 : 0)
                + phraseTokens.intersection(tableTokens).count * 30
                + phraseTokens.intersection(columnTokens).count * 2
            return score > 0 ? (table, score) : nil
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.qualifiedName < rhs.0.qualifiedName : lhs.1 > rhs.1
        }
        guard let top = matches.first else { return nil }
        return matches.filter { $0.1 == top.1 }.count == 1 ? top.0 : nil
    }

    private static func uniqueColumn(
        matching phrase: String,
        schema: DatabaseSchema,
        in table: TableInfo? = nil,
        requireNumeric: Bool = false
    ) -> ColumnMatch? {
        let phraseTokens = Set(SchemaIndex.tokens(in: phrase))
        guard !phraseTokens.isEmpty else { return nil }
        let candidateTables = table.map { [$0] } ?? schema.tables
        let matches = candidateTables.flatMap { table in
            table.columns.compactMap { column -> ColumnMatch? in
                guard !requireNumeric || isNumeric(column) else { return nil }
                let columnTokens = Set(SchemaIndex.tokens(in: column.name))
                let tableTokens = Set(SchemaIndex.tokens(in: table.name))
                let exact = column.name.lowercased() == phrase.replacingOccurrences(of: " ", with: "_")
                let containsAll = phraseTokens.isSubset(of: columnTokens)
                let score = (exact ? 120 : 0)
                    + (containsAll ? 70 : 0)
                    + phraseTokens.intersection(columnTokens).count * 25
                    + phraseTokens.intersection(tableTokens).count * 3
                    - (column.name.lowercased() == "id" ? 15 : 0)
                return score > 0 ? ColumnMatch(column: column, score: score) : nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.column.id < rhs.column.id
            }
            return lhs.score > rhs.score
        }
        guard let top = matches.first else { return nil }
        return matches.filter { $0.score == top.score }.count == 1 ? top : nil
    }

    private static func groupingSelection(for phrase: String, table: TableInfo) -> GroupingSelection? {
        let normalized = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["day", "date"].contains(normalized),
            let column = preferredTemporalColumn(in: table)
        {
            return GroupingSelection(
                label: column.name,
                alias: "day",
                expression: { alias in "\(qualifiedColumn(alias: alias, column: column.name))::date" }
            )
        }
        if ["week", "month", "year"].contains(normalized),
            let column = preferredTemporalColumn(in: table)
        {
            return GroupingSelection(
                label: column.name,
                alias: normalized,
                expression: { alias in
                    "DATE_TRUNC('\(normalized)', \(qualifiedColumn(alias: alias, column: column.name)))"
                }
            )
        }
        guard let match = uniqueColumn(matching: phrase, schema: DatabaseSchema(tables: [table]), in: table) else {
            return nil
        }
        return GroupingSelection(
            label: match.column.name,
            alias: safeAlias(match.column.name),
            expression: { alias in qualifiedColumn(alias: alias, column: match.column.name) }
        )
    }

    private static func preferredTemporalColumn(in table: TableInfo) -> ColumnInfo? {
        let temporal = table.columns.filter(isTemporal)
        let preferred = ["created_at", "created_on", "occurred_at", "timestamp", "updated_at", "date"]
        for name in preferred {
            if let match = temporal.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
        }
        return temporal.first
    }

    private static func isNumeric(_ column: ColumnInfo) -> Bool {
        let type = column.dataType.lowercased()
        return [
            "bigint", "decimal", "double", "integer", "numeric", "real", "smallint",
        ].contains { type.contains($0) }
    }

    private static func isTemporal(_ column: ColumnInfo) -> Bool {
        let name = column.name.lowercased()
        let type = column.dataType.lowercased()
        return type.contains("date")
            || type.contains("time")
            || name.hasSuffix("_at")
            || name.hasSuffix("_date")
            || name == "date"
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

    private static func safeAlias(_ identifier: String) -> String {
        let alias = SchemaIndex.tokens(in: identifier).joined(separator: "_")
        return alias.isEmpty ? "value" : alias
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
