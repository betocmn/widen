import Foundation

public struct LocalSchemaSearcher: SchemaSearching {
    let index: LocalSchemaSearchIndex
    private let documentsByTableID: [String: SchemaSearchDocument]
    private let duplicateUnqualifiedNames: Set<String>

    init(index: LocalSchemaSearchIndex) {
        self.index = index
        self.documentsByTableID = Dictionary(
            uniqueKeysWithValues: index.documents.map { ($0.tableID.stableString, $0) }
        )
        let nameCounts = index.documents.reduce(into: [String: Int]()) { counts, document in
            for alias in document.exactAliases where isUnquotedUnqualifiedAlias(alias) {
                counts[alias.lowercased(), default: 0] += 1
            }
        }
        self.duplicateUnqualifiedNames = Set(
            nameCounts.compactMap { $0.value > 1 ? $0.key : nil }
        )
    }

    public func search(
        _ request: SchemaSearchRequest,
        in snapshot: SchemaSearchSnapshot
    ) -> SchemaSearchResponse {
        let started = ContinuousClock.now
        let queryTokens = SchemaSearchTokenizer.queryTokens(in: request.query)
        let semanticTokens = SchemaSearchTokenizer.queryTokens(
            in: request.semanticBindingTerms.joined(separator: " ")
        )
        let lexicalTokens = uniqueOrdered(queryTokens + semanticTokens)
        let contextTokens = SchemaSearchTokenizer.queryTokens(in: request.databaseContext)

        let directCandidates = index.documents.compactMap { document -> CandidateScore? in
            let lexical = lexicalScore(document: document, queryTokens: lexicalTokens)
            let exact = exactIdentifierScore(document: document, query: request.query)
            let tableToken = exactTableTokenScore(
                document: document,
                queryTokens: lexicalTokens,
                query: request.query
            )
            guard lexical.score > 0 || exact.score > 0 || tableToken.score > 0 else { return nil }
            return CandidateScore(
                document: document,
                lexicalBM25Score: lexical.score,
                exactMatchScore: exact.score + tableToken.score,
                contextBoost: 0,
                graphBoost: 0,
                exactMatchQuality: exact.quality,
                matchedFields: lexical.matchedFields + exact.matchedFields + tableToken.matchedFields,
                matchedQueryTokens: lexical.matchedQueryTokens
            )
        }
        .sorted(by: candidateSort)
        .prefix(request.stageOneLimit)

        var candidatesByID = Dictionary(
            uniqueKeysWithValues: directCandidates.map { ($0.document.tableID.stableString, $0) }
        )
        let graphBoosts = boundedGraphBoosts(from: Array(directCandidates.prefix(5)))
        for (tableID, boost) in graphBoosts {
            guard let document = documentsByTableID[tableID] else { continue }
            var candidate = candidatesByID[tableID] ?? CandidateScore(
                document: document,
                lexicalBM25Score: 0,
                exactMatchScore: 0,
                contextBoost: 0,
                graphBoost: 0,
                exactMatchQuality: 0,
                matchedFields: [],
                matchedQueryTokens: []
            )
            candidate.graphBoost = max(candidate.graphBoost, boost)
            candidatesByID[tableID] = candidate
        }

        let rankedCandidates = candidatesByID.values.map { candidate in
            var candidate = candidate
            let context = contextScore(
                document: candidate.document,
                contextTokens: contextTokens
            )
            candidate.contextBoost = context.score
            candidate.matchedFields += context.matchedFields
            return candidate
        }
        .filter { $0.totalScore > 0 }
        .sorted(by: candidateSort)

        let hits = rankedCandidates.prefix(request.limit).enumerated().map { offset, candidate in
            SchemaSearchHit(
                tableObjectID: candidate.document.tableID,
                totalScore: rounded(candidate.totalScore),
                matchedTableTerms: matchedTableTerms(candidate.matchedFields),
                matchedColumnIDs: matchedColumnIDs(candidate.matchedFields),
                matchedFields: uniqueMatchedFields(candidate.matchedFields),
                exactMatchScore: rounded(candidate.exactMatchScore),
                lexicalBM25Score: rounded(candidate.lexicalBM25Score),
                contextBoost: rounded(candidate.contextBoost),
                graphBoost: rounded(candidate.graphBoost),
                rank: offset + 1
            )
        }

        let topScore = rankedCandidates.first?.totalScore ?? 0
        let secondScore = rankedCandidates.dropFirst().first?.totalScore
        let elapsed = schemaSearchMilliseconds(started.duration(to: .now))
        let coverage = queryCoverage(
            queryTokens: lexicalTokens,
            candidates: Array(rankedCandidates.prefix(max(request.limit, 3)))
        )
        let exactMatch = rankedCandidates.contains { $0.exactMatchQuality > 0 }
        return SchemaSearchResponse(
            hits: hits,
            queryTokenCoverage: rounded(coverage),
            topToSecondScoreMargin: secondScore.map { rounded(topScore - $0) },
            noStrongMatch: hits.isEmpty || (!exactMatch && (topScore < 1.2 || coverage < 0.25)),
            exactIdentifierMatch: exactMatch,
            queryLatencyMs: elapsed,
            indexBuildDurationMs: index.buildDurationMs,
            indexSerializedSizeBytes: index.serializedSizeBytes
        )
    }

    public func describe(
        objectIDs: [SchemaObjectID],
        in snapshot: SchemaSearchSnapshot
    ) -> [SchemaObjectDescription] {
        let tablesByID = Dictionary(
            uniqueKeysWithValues: snapshot.schemaSearchTables.map {
                (SchemaObjectID.table(schema: $0.schema, name: $0.name).stableString, $0)
            }
        )
        let availableSchemas = Set(snapshot.schema.schemas.map(\.name))
            .union(snapshot.schemaSearchTables.map(\.schema))
        let selectedSchemas = Set(snapshot.selectedSchemas)
        let relationships = snapshot.schemaSearchRelationships
        return objectIDs.compactMap { objectID in
            switch objectID.kind {
            case .schema:
                guard availableSchemas.contains(objectID.schema),
                    selectedSchemas.isEmpty || selectedSchemas.contains(objectID.schema)
                else {
                    return nil
                }
                return SchemaObjectDescription(
                    objectID: objectID,
                    kind: .schema,
                    schema: objectID.schema
                )
            case .table:
                guard let table = tablesByID[objectID.stableString] else { return nil }
                return SchemaObjectDescription(
                    objectID: objectID,
                    kind: .table,
                    schema: table.schema,
                    table: table.name,
                    comment: table.comment,
                    columns: table.columns.map(\.name),
                    keyConstraints: table.keyConstraints,
                    foreignKeyConstraints: relationships.filter {
                        ($0.sourceSchema == table.schema && $0.sourceTable == table.name)
                            || ($0.targetSchema == table.schema && $0.targetTable == table.name)
                    }
                )
            case .column:
                guard let tableName = objectID.table,
                    let columnName = objectID.column,
                    let table = tablesByID[
                        SchemaObjectID.table(schema: objectID.schema, name: tableName).stableString
                    ],
                    let column = table.columns.first(where: { $0.name == columnName })
                else { return nil }
                return SchemaObjectDescription(
                    objectID: objectID,
                    kind: .column,
                    schema: column.tableSchema,
                    table: column.tableName,
                    column: column.name,
                    dataType: column.dataType,
                    isNullable: column.isNullable,
                    comment: column.comment
                )
            case .keyConstraint:
                guard let tableName = objectID.table,
                    let constraintName = objectID.constraintName,
                    let table = tablesByID[
                        SchemaObjectID.table(schema: objectID.schema, name: tableName).stableString
                    ],
                    let key = table.keyConstraints.first(where: { $0.constraintName == constraintName })
                else { return nil }
                return SchemaObjectDescription(
                    objectID: objectID,
                    kind: .keyConstraint,
                    schema: key.schema,
                    table: key.table,
                    columns: key.columns,
                    keyConstraints: [key]
                )
            case .foreignKeyConstraint:
                guard let tableName = objectID.table,
                    let constraintName = objectID.constraintName,
                    let relationship = relationships.first(where: {
                        $0.sourceSchema == objectID.schema
                            && $0.sourceTable == tableName
                            && $0.constraintName == constraintName
                    })
                else { return nil }
                return SchemaObjectDescription(
                    objectID: objectID,
                    kind: .foreignKeyConstraint,
                    schema: relationship.sourceSchema,
                    table: relationship.sourceTable,
                    columns: relationship.columnPairs.map(\.sourceColumn),
                    foreignKeyConstraints: [relationship]
                )
            }
        }
    }

    public func findJoinPaths(
        from: SchemaObjectID,
        to: SchemaObjectID,
        maxHops: Int,
        in snapshot: SchemaSearchSnapshot
    ) -> [SchemaJoinPath] {
        guard let source = tableID(for: from),
            let target = tableID(for: to)
        else { return [] }

        let hopLimit = min(max(maxHops, 0), 3)
        guard hopLimit > 0 else { return [] }

        let adjacency = joinAdjacency(relationships: snapshot.schemaSearchRelationships)
        if source == target {
            let paths = (adjacency[source.stableString] ?? [])
                .filter { $0.toTableID == target }
                .map { SchemaJoinPath(edges: [$0]) }
            return Array(paths.sorted {
                pathSortKey($0) < pathSortKey($1)
            }.prefix(8))
        }

        struct QueueEntry {
            var tableID: SchemaObjectID
            var path: [SchemaJoinPathEdge]
            var visited: Set<String>
        }

        var queue = [
            QueueEntry(tableID: source, path: [], visited: [source.stableString])
        ]
        var paths: [SchemaJoinPath] = []
        let pathLimit = 8

        while !queue.isEmpty, paths.count < pathLimit {
            let entry = queue.removeFirst()
            guard entry.path.count < hopLimit else { continue }
            for edge in adjacency[entry.tableID.stableString] ?? [] {
                guard !entry.visited.contains(edge.toTableID.stableString) else { continue }
                let nextPath = entry.path + [edge]
                if edge.toTableID == target {
                    paths.append(SchemaJoinPath(edges: nextPath))
                    if paths.count >= pathLimit { break }
                } else {
                    var visited = entry.visited
                    visited.insert(edge.toTableID.stableString)
                    queue.append(
                        QueueEntry(
                            tableID: edge.toTableID,
                            path: nextPath,
                            visited: visited
                        )
                    )
                }
            }
        }

        return paths.sorted {
            if $0.hopCount == $1.hopCount {
                return pathSortKey($0) < pathSortKey($1)
            }
            return $0.hopCount < $1.hopCount
        }
    }

    private func lexicalScore(
        document: SchemaSearchDocument,
        queryTokens: [String]
    ) -> LexicalScore {
        guard !queryTokens.isEmpty else {
            return LexicalScore(score: 0, matchedFields: [], matchedQueryTokens: [])
        }
        let counts = document.termCounts()
        var total = 0.0
        var matchedFields: [SchemaSearchMatchedField] = []
        var matchedTokens: [String] = []

        for queryToken in queryTokens {
            if let fieldCounts = counts[queryToken] {
                total += bm25(
                    term: queryToken,
                    fieldCounts: fieldCounts,
                    documentLength: document.length
                )
                matchedFields += document.origins(for: queryToken).map {
                    SchemaSearchMatchedField(
                        field: $0.field,
                        term: queryToken,
                        objectID: $0.objectID
                    )
                }
                matchedTokens.append(queryToken)
                continue
            }

            let fuzzy = bestApproximateMatch(
                queryToken: queryToken,
                counts: counts,
                document: document
            )
            if let fuzzy {
                total += fuzzy.score
                matchedFields += fuzzy.matchedFields
                matchedTokens.append(queryToken)
            }
        }

        return LexicalScore(
            score: total,
            matchedFields: matchedFields,
            matchedQueryTokens: uniqueOrdered(matchedTokens)
        )
    }

    private func bestApproximateMatch(
        queryToken: String,
        counts: [String: [SchemaSearchField: Double]],
        document: SchemaSearchDocument
    ) -> ApproximateMatch? {
        var best: ApproximateMatch?
        for indexedToken in counts.keys.sorted() {
            let similarity = SchemaSearchTokenizer.similarity(
                queryToken: queryToken,
                indexedToken: indexedToken
            )
            guard similarity > 0, let fieldCounts = counts[indexedToken] else { continue }
            let score = bm25(
                term: indexedToken,
                fieldCounts: fieldCounts,
                documentLength: document.length
            ) * similarity * 0.35
            let candidate = ApproximateMatch(
                indexedToken: indexedToken,
                score: score,
                matchedFields: document.origins(for: indexedToken).map {
                    SchemaSearchMatchedField(
                        field: $0.field,
                        term: indexedToken,
                        objectID: $0.objectID
                    )
                }
            )
            guard candidate.isBetter(than: best) else { continue }
            best = candidate
        }
        return best
    }

    private func bm25(
        term: String,
        fieldCounts: [SchemaSearchField: Double],
        documentLength: Double
    ) -> Double {
        let corpusSize = max(index.documents.count, 1)
        let documentFrequency = max(index.documentFrequency[term, default: 1], 1)
        let idf = log((Double(corpusSize - documentFrequency) + 0.5) / (Double(documentFrequency) + 0.5) + 1)
        let weightedTermFrequency = min(
            fieldCounts.reduce(0.0) { partial, entry in
                partial + min(entry.value, termFrequencyCap(for: entry.key)) * entry.key.weight
            },
            18
        )
        let averageLength = max(index.averageDocumentLength, 1)
        let k1 = 1.2
        let b = 0.62
        let denominator = weightedTermFrequency + k1 * (1 - b + b * (documentLength / averageLength))
        return idf * ((weightedTermFrequency * (k1 + 1)) / denominator)
    }

    private func exactIdentifierScore(
        document: SchemaSearchDocument,
        query: String
    ) -> ExactIdentifierScore {
        let lowercasedUnquotedQuery = lowercasedOutsideQuotedIdentifiers(query)
        var score = 0.0
        var quality = 0
        var matchedFields: [SchemaSearchMatchedField] = []

        for alias in document.exactAliases {
            guard containsIdentifierAlias(query, alias: alias, caseSensitive: true) else { continue }
            let qualified = alias.contains(".")
            if qualified {
                score += 30
                quality = max(quality, 3)
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: .exactTableQualified,
                        term: alias,
                        objectID: document.tableID
                    )
                )
            } else if !duplicateUnqualifiedNames.contains(document.tableName.lowercased()) {
                score += 12
                quality = max(quality, 2)
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: .exactTableUnqualified,
                        term: alias,
                        objectID: document.tableID
                    )
                )
            }
        }

        for alias in document.lowercasedAliases where !containsQuotedIdentifier(alias) {
            guard containsIdentifierAlias(lowercasedUnquotedQuery, alias: alias, caseSensitive: true) else { continue }
            let qualified = alias.contains(".")
            if qualified {
                score += 18
                quality = max(quality, 2)
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: .exactTableQualified,
                        term: alias,
                        objectID: document.tableID
                    )
                )
            } else if !duplicateUnqualifiedNames.contains(document.tableName.lowercased()) {
                score += 7
                quality = max(quality, 1)
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: .exactTableUnqualified,
                        term: alias,
                        objectID: document.tableID
                    )
                )
            }
        }

        return ExactIdentifierScore(
            score: score,
            quality: quality,
            matchedFields: matchedFields
        )
    }

    private func exactTableTokenScore(
        document: SchemaSearchDocument,
        queryTokens: [String],
        query: String
    ) -> ExactIdentifierScore {
        guard !queryTokens.isEmpty else {
            return ExactIdentifierScore(score: 0, quality: 0, matchedFields: [])
        }
        if containsQuotedIdentifier(query) {
            return ExactIdentifierScore(score: 0, quality: 0, matchedFields: [])
        }
        if isUnquotedIdentifierLikeQuery(query),
            (!SchemaSearchTokenizer.canReferenceUnquoted(document.schema)
                || !SchemaSearchTokenizer.canReferenceUnquoted(document.tableName))
        {
            return ExactIdentifierScore(score: 0, quality: 0, matchedFields: [])
        }
        let queryTokenSet = Set(queryTokens)
        var score = 0.0
        var matchedFields: [SchemaSearchMatchedField] = []
        for term in document.terms {
            guard queryTokenSet.contains(term.term) else { continue }
            switch term.field {
            case .exactTableQualified:
                score += 0.55
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: term.field,
                        term: term.term,
                        objectID: term.objectID
                    )
                )
            case .exactTableUnqualified:
                score += 0.9
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: term.field,
                        term: term.term,
                        objectID: term.objectID
                    )
                )
            default:
                continue
            }
        }
        return ExactIdentifierScore(
            score: min(score, 2.4),
            quality: 0,
            matchedFields: matchedFields
        )
    }

    private func isUnquotedIdentifierLikeQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !trimmed.contains("\""),
            !trimmed.contains("'")
        else { return false }

        return trimmed.allSatisfy {
            $0 == "." || $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber
        }
    }

    private func contextScore(
        document: SchemaSearchDocument,
        contextTokens: [String]
    ) -> ContextScore {
        guard !contextTokens.isEmpty else {
            return ContextScore(score: 0, matchedFields: [])
        }
        let counts = document.termCounts()
        var total = 0.0
        var matchedFields: [SchemaSearchMatchedField] = []
        let corpusSize = max(index.documents.count, 1)

        for token in contextTokens where token.count >= 3 {
            guard counts[token] != nil else { continue }
            let documentFrequency = max(index.documentFrequency[token, default: 1], 1)
            let rarity = max(0.12, log((Double(corpusSize) + 1) / (Double(documentFrequency) + 1)))
            var tokenScore = 0.0
            for origin in document.origins(for: token) {
                let fieldWeight = contextFieldWeight(origin.field)
                guard fieldWeight > 0 else { continue }
                tokenScore += fieldWeight
                matchedFields.append(
                    SchemaSearchMatchedField(
                        field: origin.field,
                        term: token,
                        objectID: origin.objectID
                    )
                )
            }
            total += min(tokenScore, 3.2) * rarity * 0.72
        }

        return ContextScore(
            score: min(total, 6),
            matchedFields: matchedFields
        )
    }

    private func boundedGraphBoosts(from anchors: [CandidateScore]) -> [String: Double] {
        guard !anchors.isEmpty else { return [:] }
        let adjacency = joinAdjacency(relationships: index.foreignKeyConstraints)
        var boosts: [String: Double] = [:]
        for (offset, anchor) in anchors.enumerated() {
            guard anchor.lexicalBM25Score + anchor.exactMatchScore > 0.8 else { continue }
            let neighbors = adjacency[anchor.document.tableID.stableString] ?? []
            let degreePenalty = max(1, min(neighbors.count, 8))
            let boost = min(1.2 / Double(degreePenalty), 0.65) * pow(0.78, Double(offset))
            for edge in neighbors.prefix(12) {
                guard edge.toTableID != anchor.document.tableID else { continue }
                boosts[edge.toTableID.stableString] = max(
                    boosts[edge.toTableID.stableString, default: 0],
                    boost
                )
            }
        }
        return boosts
    }

    private func joinAdjacency(
        relationships: [SchemaForeignKeyConstraintInfo]
    ) -> [String: [SchemaJoinPathEdge]] {
        var adjacency: [String: [SchemaJoinPathEdge]] = [:]
        for relationship in relationships {
            let source = SchemaObjectID.table(
                schema: relationship.sourceSchema,
                name: relationship.sourceTable
            )
            let target = SchemaObjectID.table(
                schema: relationship.targetSchema,
                name: relationship.targetTable
            )
            adjacency[source.stableString, default: []].append(
                SchemaJoinPathEdge(
                    constraintName: relationship.constraintName,
                    fromTableID: source,
                    toTableID: target,
                    sourceTableID: source,
                    targetTableID: target,
                    columnPairs: relationship.columnPairs,
                    traversalDirection: .forward
                )
            )
            adjacency[target.stableString, default: []].append(
                SchemaJoinPathEdge(
                    constraintName: relationship.constraintName,
                    fromTableID: target,
                    toTableID: source,
                    sourceTableID: source,
                    targetTableID: target,
                    columnPairs: relationship.columnPairs,
                    traversalDirection: .reverse
                )
            )
        }
        return adjacency.mapValues {
            $0.sorted {
                if $0.toTableID.stableString == $1.toTableID.stableString {
                    return $0.constraintName < $1.constraintName
                }
                return $0.toTableID.stableString < $1.toTableID.stableString
            }
        }
    }

    private func tableID(for objectID: SchemaObjectID) -> SchemaObjectID? {
        switch objectID.kind {
        case .schema:
            return nil
        case .table:
            guard let table = objectID.table else { return nil }
            return .table(schema: objectID.schema, name: table)
        case .column, .keyConstraint, .foreignKeyConstraint:
            guard let table = objectID.table else { return nil }
            return .table(schema: objectID.schema, name: table)
        }
    }
}

private struct LexicalScore {
    var score: Double
    var matchedFields: [SchemaSearchMatchedField]
    var matchedQueryTokens: [String]
}

private struct ApproximateMatch {
    var indexedToken: String
    var score: Double
    var matchedFields: [SchemaSearchMatchedField]

    func isBetter(than current: ApproximateMatch?) -> Bool {
        guard let current else { return true }
        if score != current.score {
            return score > current.score
        }
        if indexedToken != current.indexedToken {
            return indexedToken < current.indexedToken
        }
        return matchedFields.stableSortKey < current.matchedFields.stableSortKey
    }
}

private struct ExactIdentifierScore {
    var score: Double
    var quality: Int
    var matchedFields: [SchemaSearchMatchedField]
}

private struct ContextScore {
    var score: Double
    var matchedFields: [SchemaSearchMatchedField]
}

private struct CandidateScore {
    var document: SchemaSearchDocument
    var lexicalBM25Score: Double
    var exactMatchScore: Double
    var contextBoost: Double
    var graphBoost: Double
    var exactMatchQuality: Int
    var matchedFields: [SchemaSearchMatchedField]
    var matchedQueryTokens: [String]

    var totalScore: Double {
        lexicalBM25Score + exactMatchScore + contextBoost + graphBoost
    }
}

private func candidateSort(_ lhs: CandidateScore, _ rhs: CandidateScore) -> Bool {
    if lhs.totalScore == rhs.totalScore {
        if lhs.exactMatchQuality == rhs.exactMatchQuality {
            return lhs.document.qualifiedName < rhs.document.qualifiedName
        }
        return lhs.exactMatchQuality > rhs.exactMatchQuality
    }
    return lhs.totalScore > rhs.totalScore
}

private func contextFieldWeight(_ field: SchemaSearchField) -> Double {
    switch field {
    case .columnName:
        return 1.25
    case .exactTableQualified:
        return 1.15
    case .exactTableUnqualified:
        return 1.05
    case .tableComment, .columnComment:
        return 0.85
    case .keyColumn, .valueConstraint:
        return 0.65
    case .constraintName:
        return 0.22
    case .connectedColumnPair:
        return 0.3
    case .connectedTableName:
        return 0.04
    case .dataType, .schemaName, .foreignKeyNeighbor:
        return 0.03
    }
}

private func termFrequencyCap(for field: SchemaSearchField) -> Double {
    switch field {
    case .exactTableQualified, .exactTableUnqualified:
        return 1
    case .columnName:
        return 1.15
    case .tableComment, .columnComment:
        return 2
    case .keyColumn, .valueConstraint:
        return 1.5
    case .constraintName, .connectedTableName, .connectedColumnPair:
        return 1
    case .dataType, .schemaName, .foreignKeyNeighbor:
        return 1
    }
}

private func uniqueOrdered<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

private func uniqueMatchedFields(
    _ values: [SchemaSearchMatchedField]
) -> [SchemaSearchMatchedField] {
    uniqueOrdered(values).sorted {
        if $0.field.rawValue == $1.field.rawValue {
            if $0.term == $1.term {
                return ($0.objectID?.stableString ?? "") < ($1.objectID?.stableString ?? "")
            }
            return $0.term < $1.term
        }
        return $0.field.rawValue < $1.field.rawValue
    }
}

private func matchedTableTerms(_ fields: [SchemaSearchMatchedField]) -> [String] {
    uniqueOrdered(
        fields.compactMap {
            [.exactTableQualified, .exactTableUnqualified].contains($0.field) ? $0.term : nil
        }
    ).sorted()
}

private func matchedColumnIDs(_ fields: [SchemaSearchMatchedField]) -> [SchemaObjectID] {
    uniqueOrdered(
        fields.compactMap { field in
            guard field.objectID?.kind == .column else { return nil }
            return field.objectID
        }
    )
    .sorted { $0.stableString < $1.stableString }
}

private func queryCoverage(queryTokens: [String], candidates: [CandidateScore]) -> Double {
    guard !queryTokens.isEmpty else { return 0 }
    let matched = Set(candidates.flatMap(\.matchedQueryTokens))
    return Double(Set(queryTokens).intersection(matched).count) / Double(Set(queryTokens).count)
}

private func rounded(_ value: Double) -> Double {
    (value * 10_000).rounded() / 10_000
}

private func containsIdentifierAlias(
    _ query: String,
    alias: String,
    caseSensitive: Bool
) -> Bool {
    let searchableQuery = caseSensitive ? query : query.lowercased()
    let searchableAlias = caseSensitive ? alias : alias.lowercased()
    guard !searchableAlias.isEmpty else { return false }

    var searchStart = searchableQuery.startIndex
    while searchStart < searchableQuery.endIndex,
        let range = searchableQuery.range(
            of: searchableAlias,
            range: searchStart..<searchableQuery.endIndex
        )
    {
        if hasIdentifierAliasBoundaries(in: searchableQuery, range: range) {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func lowercasedOutsideQuotedIdentifiers(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    var insideQuotedIdentifier = false

    while index < text.endIndex {
        let character = text[index]
        if character == "\"" {
            result.append(" ")
            let next = text.index(after: index)
            if insideQuotedIdentifier, next < text.endIndex, text[next] == "\"" {
                result.append(" ")
                index = text.index(after: next)
            } else {
                insideQuotedIdentifier.toggle()
                index = next
            }
            continue
        }

        if insideQuotedIdentifier {
            result.append(" ")
        } else {
            result.append(contentsOf: String(character).lowercased())
        }
        index = text.index(after: index)
    }

    return result
}

private func isUnquotedUnqualifiedAlias(_ alias: String) -> Bool {
    !alias.contains(".")
        && !containsQuotedIdentifier(alias)
        && SchemaSearchTokenizer.canReferenceUnquoted(alias)
}

private func containsQuotedIdentifier(_ alias: String) -> Bool {
    alias.contains("\"")
}

private func hasIdentifierAliasBoundaries(
    in text: String,
    range: Range<String.Index>
) -> Bool {
    let prefixAllowed: Bool
    if range.lowerBound == text.startIndex {
        prefixAllowed = true
    } else {
        let previous = text[text.index(before: range.lowerBound)]
        prefixAllowed = !isIdentifierBody(previous) && previous != "."
    }

    let suffixAllowed: Bool
    if range.upperBound == text.endIndex {
        suffixAllowed = true
    } else {
        suffixAllowed = !isIdentifierBody(text[range.upperBound])
    }

    return prefixAllowed && suffixAllowed
}

private func isIdentifierBody(_ character: Character) -> Bool {
    character == "_" || character == "$" || character.isLetter || character.isNumber
}

private extension Array where Element == SchemaSearchMatchedField {
    var stableSortKey: String {
        map { field in
            "\(field.field.rawValue):\(field.term):\(field.objectID?.stableString ?? "")"
        }
        .joined(separator: "|")
    }
}

private func pathSortKey(_ path: SchemaJoinPath) -> String {
    path.edges.map {
        "\($0.fromTableID.stableString)>\($0.toTableID.stableString):\($0.constraintName):\($0.traversalDirection.rawValue)"
    }
    .joined(separator: "|")
}
