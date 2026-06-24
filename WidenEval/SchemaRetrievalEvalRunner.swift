import CryptoKit
import Foundation

import WidenKit

enum SchemaRetrievalMode: String {
    case legacy
    case index
    case both

    var retrievers: [SchemaRetrievalRunnerKind] {
        switch self {
        case .legacy:
            [.legacy]
        case .index:
            [.index]
        case .both:
            [.legacy, .index]
        }
    }
}

enum SchemaRetrievalRunnerKind: String, Codable, CaseIterable {
    case legacy
    case index
}

struct SchemaRetrievalEvalSuite: Codable {
    var name: String
    var version: String
    var cases: [SchemaRetrievalEvalCase]
}

struct SchemaRetrievalEvalCase: Codable {
    var id: String
    var schemaFixture: String
    var question: String
    var databaseContext: String?
    var retrieval: SchemaRetrievalExpectation
}

struct SchemaRetrievalExpectation: Codable {
    var primaryTable: String?
    var requiredTables: [String]
    var acceptableAlternativeTableGroups: [[String]]
    var requiredJoinPaths: [SchemaRetrievalJoinPathExpectation]
    var requiredColumnMatches: [String]
    var forbiddenTopKDistractors: [SchemaRetrievalForbiddenDistractor]

    private enum CodingKeys: String, CodingKey {
        case primaryTable
        case requiredTables
        case acceptableAlternativeTableGroups
        case requiredJoinPaths
        case requiredColumnMatches
        case forbiddenTopKDistractors
    }

    init(
        primaryTable: String? = nil,
        requiredTables: [String] = [],
        acceptableAlternativeTableGroups: [[String]] = [],
        requiredJoinPaths: [SchemaRetrievalJoinPathExpectation] = [],
        requiredColumnMatches: [String] = [],
        forbiddenTopKDistractors: [SchemaRetrievalForbiddenDistractor] = []
    ) {
        self.primaryTable = primaryTable
        self.requiredTables = requiredTables
        self.acceptableAlternativeTableGroups = acceptableAlternativeTableGroups
        self.requiredJoinPaths = requiredJoinPaths
        self.requiredColumnMatches = requiredColumnMatches
        self.forbiddenTopKDistractors = forbiddenTopKDistractors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryTable = try container.decodeIfPresent(String.self, forKey: .primaryTable)
        requiredTables = try container.decodeIfPresent([String].self, forKey: .requiredTables) ?? []
        acceptableAlternativeTableGroups =
            try container.decodeIfPresent(
                [[String]].self,
                forKey: .acceptableAlternativeTableGroups
            ) ?? []
        requiredJoinPaths =
            try container.decodeIfPresent(
                [SchemaRetrievalJoinPathExpectation].self,
                forKey: .requiredJoinPaths
            ) ?? []
        requiredColumnMatches =
            try container.decodeIfPresent([String].self, forKey: .requiredColumnMatches) ?? []
        forbiddenTopKDistractors =
            try container.decodeIfPresent(
                [SchemaRetrievalForbiddenDistractor].self,
                forKey: .forbiddenTopKDistractors
            ) ?? []
    }
}

struct SchemaRetrievalJoinPathExpectation: Codable, Equatable {
    var from: String
    var to: String
    var maximumHops: Int
}

struct SchemaRetrievalForbiddenDistractor: Codable, Equatable {
    var table: String
    var topK: Int

    private enum CodingKeys: String, CodingKey {
        case table
        case topK
    }

    init(table: String, topK: Int = 5) {
        self.table = table
        self.topK = topK
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(String.self, forKey: .table)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? 5
    }
}

struct SchemaRetrievalEvalRun: Codable {
    var manifest: SchemaRetrievalEvalManifest
    var results: [SchemaRetrievalEvalResult]
    var summaries: [String: SchemaRetrievalSummary]
    var acceptance: SchemaRetrievalAcceptance
}

struct SchemaRetrievalEvalManifest: Codable {
    var suiteName: String
    var suiteVersion: String
    var suitePath: String
    var commitSHA: String
    var startedAt: String
    var finishedAt: String
    var retrieverMode: String
    var caseCount: Int
    var suiteFileHash: String
    var schemaFixtureHashes: [String: String]
}

struct SchemaRetrievalEvalResult: Codable {
    var caseID: String
    var retriever: SchemaRetrievalRunnerKind
    var rankedTables: [String]
    var requiredTableRanks: [String: Int]
    var missingRequiredTables: [String]
    var hasAlternativeTableGroupExpectation: Bool
    var bestAlternativeTableGroup: [String]?
    var alternativeGroupPresentAt3: Bool?
    var alternativeGroupPresentAt5: Bool?
    var alternativeGroupPresentAt8: Bool?
    var missingAlternativeTableGroups: [[String]]
    var noResultExpectationPassed: Bool?
    var hasPrimaryTableExpectation: Bool
    var primaryTableRank: Int?
    var primaryReciprocalRank: Double?
    var allRequiredPresentAt3: Bool
    var allRequiredPresentAt5: Bool
    var allRequiredPresentAt8: Bool
    var requiredJoinPathResults: [SchemaRetrievalJoinPathResult]
    var missingRequiredColumnMatches: [String]
    var forbiddenDistractorViolations: [SchemaRetrievalForbiddenDistractor]
    var wrongSchemaCollisionCount: Int
    var noResultOrLowSignal: Bool
    var queryLatencyMs: Int
    var indexBuildDurationMs: Int?
    var indexSerializedSizeBytes: Int?
    var scoreExplanations: [String]
}

struct SchemaRetrievalJoinPathResult: Codable {
    var from: String
    var to: String
    var maximumHops: Int
    var recovered: Bool
    var recoveredHopCount: Int?
}

struct SchemaRetrievalSummary: Codable {
    var retriever: SchemaRetrievalRunnerKind
    var caseCount: Int
    var requiredTableRecallAt3: Double
    var requiredTableRecallAt5: Double
    var requiredTableRecallAt8: Double
    var allRequiredTablesPresentAt3: Double
    var allRequiredTablesPresentAt5: Double
    var allRequiredTablesPresentAt8: Double
    var primaryTableTop3: Double
    var primaryTableMRR: Double
    var alternativeGroupPresentAt3: Double
    var alternativeGroupPresentAt5: Double
    var alternativeGroupPresentAt8: Double
    var noResultExpectationPassRate: Double
    var requiredJoinPathRecall: Double
    var missingRequiredColumnMatchCount: Int
    var wrongSchemaCollisionCount: Int
    var noResultOrLowSignalCount: Int
    var forbiddenDistractorViolationCount: Int
    var indexBuildDurationMs: Int?
    var indexSerializedSizeBytes: Int?
    var queryLatency: LatencySummary
}

struct SchemaRetrievalAcceptance: Codable {
    var passed: Bool
    var messages: [String]
}

struct SchemaRetrievalEvalRunner {
    var options: EvalCLIOptions

    func run() async throws -> SchemaRetrievalEvalRun {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let suiteURL = URL(fileURLWithPath: options.suitePath).standardizedFileURL
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(SchemaRetrievalEvalSuite.self, from: suiteData)
        let selectedCases = try filteredCases(suite.cases)
        let evalDirectory = suiteURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaDirectory = evalDirectory.appendingPathComponent("schemas", isDirectory: true)
        let schemas = try loadSchemas(
            for: Set(selectedCases.map(\.schemaFixture)),
            schemaDirectory: schemaDirectory
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-retrieval-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let indexStore = SchemaSearchIndexStore(directory: cacheDirectory)

        var results: [SchemaRetrievalEvalResult] = []
        for retriever in (options.retrieverMode ?? .index).retrievers {
            for evalCase in selectedCases {
                guard let schemaRecord = schemas[evalCase.schemaFixture] else {
                    throw EvalRunnerError.missingSchemaFixture(evalCase.schemaFixture)
                }
                let selectedSchemas = schemaRecord.schema.schemas.map(\.name).sorted()
                let snapshot = SchemaSearchSnapshot(
                    connectionID: deterministicConnectionID(for: evalCase.schemaFixture),
                    selectedSchemas: selectedSchemas,
                    schema: schemaRecord.schema
                )
                switch retriever {
                case .legacy:
                    results.append(legacyResult(evalCase: evalCase, snapshot: snapshot))
                case .index:
                    results.append(
                        try await indexResult(
                            evalCase: evalCase,
                            snapshot: snapshot,
                            indexStore: indexStore
                        )
                    )
                }
            }
        }

        let summaries = Dictionary(
            uniqueKeysWithValues: (options.retrieverMode ?? .index).retrievers.map { retriever in
                (
                    retriever.rawValue,
                    summarize(results.filter { $0.retriever == retriever }, retriever: retriever)
                )
            }
        )
        let acceptance = acceptance(summaries: summaries)
        let finishedAt = ISO8601DateFormatter().string(from: Date())
        return SchemaRetrievalEvalRun(
            manifest: SchemaRetrievalEvalManifest(
                suiteName: suite.name,
                suiteVersion: suite.version,
                suitePath: suiteURL.path,
                commitSHA: Self.commitSHA(),
                startedAt: startedAt,
                finishedAt: finishedAt,
                retrieverMode: (options.retrieverMode ?? .index).rawValue,
                caseCount: selectedCases.count,
                suiteFileHash: Self.sha256(suiteData),
                schemaFixtureHashes: schemas.mapValues(\.sha256)
            ),
            results: results,
            summaries: summaries,
            acceptance: acceptance
        )
    }

    private func filteredCases(_ cases: [SchemaRetrievalEvalCase]) throws -> [SchemaRetrievalEvalCase] {
        guard let caseID = options.caseID else { return cases }
        let matches = cases.filter { $0.id == caseID }
        guard !matches.isEmpty else { throw EvalRunnerError.missingCase(caseID) }
        return matches
    }

    private func loadSchemas(
        for fixtures: Set<String>,
        schemaDirectory: URL
    ) throws -> [String: (schema: DatabaseSchema, sha256: String)] {
        try fixtures.reduce(into: [:]) { result, fixture in
            let url = schemaDirectory.appendingPathComponent("\(fixture)-schema.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let schema = try JSONDecoder().decode(DatabaseSchema.self, from: data)
                result[fixture] = (schema, Self.sha256(data))
            } else if fixture == "retrieval-noise" {
                let schema = Self.syntheticNoiseSchema()
                let fingerprint = try SchemaSearchIndexStore.schemaFingerprint(for: schema)
                result[fixture] = (schema, "synthetic:\(fingerprint)")
            } else {
                throw EvalRunnerError.missingSchemaFixture(fixture)
            }
        }
    }

    private func legacyResult(
        evalCase: SchemaRetrievalEvalCase,
        snapshot: SchemaSearchSnapshot
    ) -> SchemaRetrievalEvalResult {
        let started = ContinuousClock.now
        let ranked = SchemaRelevanceRanker.rank(
            schema: snapshot.schema,
            input: SchemaRankingInput(
                question: evalCase.question,
                databaseContext: evalCase.databaseContext ?? ""
            )
        )
        .filter { $0.score > 0 }
        let rankedTables = ranked.map(\.table.qualifiedName)
        let rankedTableIDs = ranked.map { SchemaObjectID.table(schema: $0.table.schema, name: $0.table.name) }
        let latency = schemaRetrievalMilliseconds(started.duration(to: .now))
        return result(
            evalCase: evalCase,
            retriever: .legacy,
            rankedTables: rankedTableIDs,
            hitDetails: [:],
            joinPathResults: evalCase.retrieval.requiredJoinPaths.map {
                SchemaRetrievalJoinPathResult(
                    from: $0.from,
                    to: $0.to,
                    maximumHops: $0.maximumHops,
                    recovered: false,
                    recoveredHopCount: nil
                )
            },
            noResultOrLowSignal: rankedTables.isEmpty,
            queryLatencyMs: latency,
            indexBuildDurationMs: nil,
            indexSerializedSizeBytes: nil,
            scoreExplanations: ranked.prefix(8).map {
                "\($0.table.qualifiedName) score=\($0.score) reasons=\($0.reasons.joined(separator: ","))"
            }
        )
    }

    private func indexResult(
        evalCase: SchemaRetrievalEvalCase,
        snapshot: SchemaSearchSnapshot,
        indexStore: SchemaSearchIndexStore
    ) async throws -> SchemaRetrievalEvalResult {
        let searcher = try await indexStore.searcher(for: snapshot)
        let response = searcher.search(
            SchemaSearchRequest(
                query: evalCase.question,
                databaseContext: evalCase.databaseContext ?? "",
                limit: 20
            ),
            in: snapshot
        )
        let hitDetails = Dictionary(uniqueKeysWithValues: response.hits.map {
            ($0.tableObjectID.stableString, $0)
        })
        let joinResults = evalCase.retrieval.requiredJoinPaths.map { expected in
            let paths: [SchemaJoinPath]
            if let from = SchemaObjectID.tableFromQualifiedName(expected.from),
                let to = SchemaObjectID.tableFromQualifiedName(expected.to)
            {
                paths = searcher.findJoinPaths(
                    from: from,
                    to: to,
                    maxHops: expected.maximumHops,
                    in: snapshot
                )
            } else {
                paths = []
            }
            return SchemaRetrievalJoinPathResult(
                from: expected.from,
                to: expected.to,
                maximumHops: expected.maximumHops,
                recovered: !paths.isEmpty,
                recoveredHopCount: paths.first?.hopCount
            )
        }
        return result(
            evalCase: evalCase,
            retriever: .index,
            rankedTables: response.hits.map(\.tableObjectID),
            hitDetails: hitDetails,
            joinPathResults: joinResults,
            noResultOrLowSignal: response.noStrongMatch,
            queryLatencyMs: response.queryLatencyMs,
            indexBuildDurationMs: response.indexBuildDurationMs,
            indexSerializedSizeBytes: response.indexSerializedSizeBytes,
            scoreExplanations: response.hits.prefix(8).map {
                let fields = $0.matchedFields.map { "\($0.field.rawValue):\($0.term)" }
                    .joined(separator: ",")
                return "\($0.tableObjectID.description) total=\($0.totalScore) lexical=\($0.lexicalBM25Score) exact=\($0.exactMatchScore) context=\($0.contextBoost) graph=\($0.graphBoost) fields=\(fields)"
            }
        )
    }

    private func result(
        evalCase: SchemaRetrievalEvalCase,
        retriever: SchemaRetrievalRunnerKind,
        rankedTables: [SchemaObjectID],
        hitDetails: [String: SchemaSearchHit],
        joinPathResults: [SchemaRetrievalJoinPathResult],
        noResultOrLowSignal: Bool,
        queryLatencyMs: Int,
        indexBuildDurationMs: Int?,
        indexSerializedSizeBytes: Int?,
        scoreExplanations: [String]
    ) -> SchemaRetrievalEvalResult {
        let rankedTableDescriptions = rankedTables.map(\.description)
        let ranks = tableRanksByDescription(rankedTables)
        let required = evalCase.retrieval.requiredTables
        let requiredRanks = Dictionary(uniqueKeysWithValues: required.compactMap { table in
            ranks[table].map { rank in (table, rank) }
        })
        let alternativeGroups = evalCase.retrieval.acceptableAlternativeTableGroups
        let hasAlternativeGroups = !alternativeGroups.isEmpty
        let alternativeAt3 = hasAlternativeGroups
            ? any(alternativeGroups, presentIn: rankedTableDescriptions, at: 3)
            : nil
        let alternativeAt5 = hasAlternativeGroups
            ? any(alternativeGroups, presentIn: rankedTableDescriptions, at: 5)
            : nil
        let alternativeAt8 = hasAlternativeGroups
            ? any(alternativeGroups, presentIn: rankedTableDescriptions, at: 8)
            : nil
        let noResultExpectationPassed = expectsNoResult(evalCase.retrieval)
            ? noResultOrLowSignal
            : nil
        let primaryRank = evalCase.retrieval.primaryTable.flatMap { ranks[$0] }
        let missingColumnMatches = evalCase.retrieval.requiredColumnMatches.filter { columnID in
            !hitDetails.values.contains { hit in
                hit.matchedColumnIDs.contains { $0.description == columnID }
            }
        }
        let violations = evalCase.retrieval.forbiddenTopKDistractors.filter { forbidden in
            guard let rank = ranks[forbidden.table] else { return false }
            return rank <= forbidden.topK
        }
        let collisionCount = wrongSchemaCollisionCount(
            rankedTables: rankedTableDescriptions,
            requiredTables: required,
            primaryTable: evalCase.retrieval.primaryTable
        )
        return SchemaRetrievalEvalResult(
            caseID: evalCase.id,
            retriever: retriever,
            rankedTables: Array(rankedTableDescriptions.prefix(20)),
            requiredTableRanks: requiredRanks,
            missingRequiredTables: required.filter { requiredRanks[$0] == nil },
            hasAlternativeTableGroupExpectation: hasAlternativeGroups,
            bestAlternativeTableGroup: bestAlternativeGroup(alternativeGroups, ranks: ranks),
            alternativeGroupPresentAt3: alternativeAt3,
            alternativeGroupPresentAt5: alternativeAt5,
            alternativeGroupPresentAt8: alternativeAt8,
            missingAlternativeTableGroups: alternativeAt8 == false ? alternativeGroups : [],
            noResultExpectationPassed: noResultExpectationPassed,
            hasPrimaryTableExpectation: evalCase.retrieval.primaryTable != nil,
            primaryTableRank: primaryRank,
            primaryReciprocalRank: primaryRank.map { 1 / Double($0) },
            allRequiredPresentAt3: all(required, presentIn: rankedTableDescriptions, at: 3),
            allRequiredPresentAt5: all(required, presentIn: rankedTableDescriptions, at: 5),
            allRequiredPresentAt8: all(required, presentIn: rankedTableDescriptions, at: 8),
            requiredJoinPathResults: joinPathResults,
            missingRequiredColumnMatches: missingColumnMatches,
            forbiddenDistractorViolations: violations,
            wrongSchemaCollisionCount: collisionCount,
            noResultOrLowSignal: noResultOrLowSignal,
            queryLatencyMs: queryLatencyMs,
            indexBuildDurationMs: indexBuildDurationMs,
            indexSerializedSizeBytes: indexSerializedSizeBytes,
            scoreExplanations: scoreExplanations
        )
    }

    private func summarize(
        _ results: [SchemaRetrievalEvalResult],
        retriever: SchemaRetrievalRunnerKind
    ) -> SchemaRetrievalSummary {
        let requiredDenominator = results.reduce(0) { total, result in
            total + result.requiredTableRanks.count + result.missingRequiredTables.count
        }
        func recall(at limit: Int) -> Double {
            guard requiredDenominator > 0 else { return 1 }
            let hits = results.reduce(0) { total, result in
                total + result.requiredTableRanks.values.filter { $0 <= limit }.count
            }
            return Double(hits) / Double(requiredDenominator)
        }
        let requiredCases = results.filter {
            !$0.requiredTableRanks.isEmpty || !$0.missingRequiredTables.isEmpty
        }
        let alternativeCases = results.filter(\.hasAlternativeTableGroupExpectation)
        let noResultCases = results.compactMap(\.noResultExpectationPassed)
        let primaryResults = results.filter(\.hasPrimaryTableExpectation)
        let joinResults = results.flatMap(\.requiredJoinPathResults)
        let latencies = results.map(\.queryLatencyMs).sorted()
        return SchemaRetrievalSummary(
            retriever: retriever,
            caseCount: results.count,
            requiredTableRecallAt3: recall(at: 3),
            requiredTableRecallAt5: recall(at: 5),
            requiredTableRecallAt8: recall(at: 8),
            allRequiredTablesPresentAt3: rate(requiredCases.map(\.allRequiredPresentAt3)),
            allRequiredTablesPresentAt5: rate(requiredCases.map(\.allRequiredPresentAt5)),
            allRequiredTablesPresentAt8: rate(requiredCases.map(\.allRequiredPresentAt8)),
            primaryTableTop3: rate(primaryResults.map { ($0.primaryTableRank ?? Int.max) <= 3 }),
            primaryTableMRR: average(primaryResults.map { $0.primaryReciprocalRank ?? 0 }),
            alternativeGroupPresentAt3: rate(alternativeCases.compactMap(\.alternativeGroupPresentAt3)),
            alternativeGroupPresentAt5: rate(alternativeCases.compactMap(\.alternativeGroupPresentAt5)),
            alternativeGroupPresentAt8: rate(alternativeCases.compactMap(\.alternativeGroupPresentAt8)),
            noResultExpectationPassRate: rate(noResultCases),
            requiredJoinPathRecall: joinResults.isEmpty
                ? 1
                : Double(joinResults.filter(\.recovered).count) / Double(joinResults.count),
            missingRequiredColumnMatchCount: results.reduce(0) {
                $0 + $1.missingRequiredColumnMatches.count
            },
            wrongSchemaCollisionCount: results.reduce(0) { $0 + $1.wrongSchemaCollisionCount },
            noResultOrLowSignalCount: results.filter(\.noResultOrLowSignal).count,
            forbiddenDistractorViolationCount: results.reduce(0) {
                $0 + $1.forbiddenDistractorViolations.count
            },
            indexBuildDurationMs: maxValue(results.compactMap(\.indexBuildDurationMs)),
            indexSerializedSizeBytes: maxValue(results.compactMap(\.indexSerializedSizeBytes)),
            queryLatency: latencySummary(latencies)
        )
    }

    private func acceptance(summaries: [String: SchemaRetrievalSummary]) -> SchemaRetrievalAcceptance {
        guard let index = summaries[SchemaRetrievalRunnerKind.index.rawValue] else {
            return SchemaRetrievalAcceptance(passed: true, messages: [])
        }
        var messages: [String] = []
        if index.allRequiredTablesPresentAt8 < 0.90 {
            messages.append("all required tables present@8 below 90%")
        }
        if index.allRequiredTablesPresentAt5 < 0.80 {
            messages.append("all required tables present@5 below 80%")
        }
        if index.primaryTableTop3 < 0.85 {
            messages.append("primary table top@3 below 85%")
        }
        if index.alternativeGroupPresentAt8 < 1 {
            messages.append("acceptable alternative groups present@8 below 100%")
        }
        if index.noResultExpectationPassRate < 1 {
            messages.append("no-result expectations failed")
        }
        if index.requiredJoinPathRecall < 0.90 {
            messages.append("required join path recall below 90%")
        }
        if index.missingRequiredColumnMatchCount > 0 {
            messages.append("required column matches missing")
        }
        if index.forbiddenDistractorViolationCount > 0 {
            messages.append("forbidden distractor violations detected")
        }
        if index.wrongSchemaCollisionCount > 0 {
            messages.append("wrong-schema collisions detected")
        }
        if let legacy = summaries[SchemaRetrievalRunnerKind.legacy.rawValue] {
            if index.requiredTableRecallAt5 < legacy.requiredTableRecallAt5 {
                messages.append("index Recall@5 below legacy")
            }
            if index.primaryTableMRR < legacy.primaryTableMRR {
                messages.append("index MRR below legacy")
            }
        }
        return SchemaRetrievalAcceptance(passed: messages.isEmpty, messages: messages)
    }

    private func wrongSchemaCollisionCount(
        rankedTables: [String],
        requiredTables: [String],
        primaryTable: String?
    ) -> Int {
        let expected = Set(requiredTables + [primaryTable].compactMap { $0 })
        var count = 0
        for table in expected {
            let parts = table.split(separator: ".")
            guard parts.count == 2 else {
                continue
            }
            let tableName = String(parts[1])
            let collisionSearchLimit = rankedTables.firstIndex(of: table) ?? min(rankedTables.count, 8)
            let collisions = rankedTables.prefix(collisionSearchLimit).filter {
                $0.hasSuffix(".\(tableName)") && $0 != table
            }
            count += collisions.count
        }
        return count
    }

    private func tableRanksByDescription(_ rankedTables: [SchemaObjectID]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var duplicateDescriptions = Set<String>()
        for (offset, tableID) in rankedTables.enumerated() {
            let description = tableID.description
            if ranks[description] != nil {
                duplicateDescriptions.insert(description)
            } else {
                ranks[description] = offset + 1
            }
        }
        for description in duplicateDescriptions {
            ranks[description] = nil
        }
        return ranks
    }

    private func all(_ required: [String], presentIn rankedTables: [String], at limit: Int) -> Bool {
        guard !required.isEmpty else { return true }
        let top = Set(rankedTables.prefix(limit))
        return required.allSatisfy { top.contains($0) }
    }

    private func any(_ groups: [[String]], presentIn rankedTables: [String], at limit: Int) -> Bool {
        let top = Set(rankedTables.prefix(limit))
        return groups.contains { group in
            !group.isEmpty && group.allSatisfy { top.contains($0) }
        }
    }

    private func bestAlternativeGroup(_ groups: [[String]], ranks: [String: Int]) -> [String]? {
        groups.min { lhs, rhs in
            let lhsMissing = lhs.filter { ranks[$0] == nil }.count
            let rhsMissing = rhs.filter { ranks[$0] == nil }.count
            if lhsMissing != rhsMissing {
                return lhsMissing < rhsMissing
            }
            let lhsWorstRank = lhs.compactMap { ranks[$0] }.max() ?? Int.max
            let rhsWorstRank = rhs.compactMap { ranks[$0] }.max() ?? Int.max
            if lhsWorstRank != rhsWorstRank {
                return lhsWorstRank < rhsWorstRank
            }
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.joined(separator: "|") < rhs.joined(separator: "|")
        }
    }

    private func expectsNoResult(_ expectation: SchemaRetrievalExpectation) -> Bool {
        expectation.primaryTable == nil
            && expectation.requiredTables.isEmpty
            && expectation.acceptableAlternativeTableGroups.isEmpty
            && expectation.requiredJoinPaths.isEmpty
            && expectation.requiredColumnMatches.isEmpty
            && expectation.forbiddenTopKDistractors.isEmpty
    }

    private func rate(_ values: [Bool]) -> Double {
        guard !values.isEmpty else { return 1 }
        return Double(values.filter { $0 }.count) / Double(values.count)
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func maxValue(_ values: [Int]) -> Int? {
        values.max()
    }

    private func latencySummary(_ latencies: [Int]) -> LatencySummary {
        guard !latencies.isEmpty else {
            return LatencySummary(minMs: 0, averageMs: 0, p50Ms: 0, p95Ms: 0, maxMs: 0)
        }
        return LatencySummary(
            minMs: latencies.first ?? 0,
            averageMs: Double(latencies.reduce(0, +)) / Double(latencies.count),
            p50Ms: percentile(latencies, 0.5),
            p95Ms: percentile(latencies, 0.95),
            maxMs: latencies.last ?? 0
        )
    }

    private func percentile(_ sorted: [Int], _ percentile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded()))
        return sorted[index]
    }

    private func deterministicConnectionID(for fixture: String) -> UUID {
        let digest = SHA256.hash(data: Data(fixture.utf8))
        let bytes = Array(digest.prefix(16))
        let uuidString = String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func commitSHA() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "unknown" : text
        } catch {
            return "unknown"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SchemaRetrievalEvalRunner {
    static func syntheticNoiseSchema() -> DatabaseSchema {
        var tables = (1...110).map { index in
            TableInfo(
                schema: "noise",
                name: "noise_table_\(String(format: "%03d", index))",
                type: .baseTable,
                columns: [
                    column(schema: "noise", table: "noise_table_\(String(format: "%03d", index))", name: "id", ordinal: 1),
                    column(schema: "noise", table: "noise_table_\(String(format: "%03d", index))", name: "name", ordinal: 2),
                    column(schema: "noise", table: "noise_table_\(String(format: "%03d", index))", name: "status", ordinal: 3),
                    column(schema: "noise", table: "noise_table_\(String(format: "%03d", index))", name: "createdAt", ordinal: 4),
                ]
            )
        }
        tables += [
            TableInfo(
                schema: "public",
                name: "users",
                type: .baseTable,
                columns: [
                    column(table: "users", name: "id", ordinal: 1),
                    column(table: "users", name: "email", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "auth",
                name: "users",
                type: .baseTable,
                columns: [
                    column(schema: "auth", table: "users", name: "id", ordinal: 1),
                    column(schema: "auth", table: "users", name: "provider", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "UserEvents",
                type: .baseTable,
                comment: "Quoted mixed-case application events",
                columns: [
                    column(table: "UserEvents", name: "id", ordinal: 1),
                    column(table: "UserEvents", name: "eventName", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "userevents",
                type: .baseTable,
                columns: [
                    column(table: "userevents", name: "id", ordinal: 1),
                    column(table: "userevents", name: "event_name", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "ledger_entries",
                type: .baseTable,
                columns: [
                    column(table: "ledger_entries", name: "id", ordinal: 1),
                    column(
                        table: "ledger_entries",
                        name: "amount_cents",
                        ordinal: 2,
                        comment: "Recognized revenue amount"
                    ),
                    column(table: "ledger_entries", name: "created_at", ordinal: 3),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "payment_records",
                type: .baseTable,
                comment: "Customer payment and revenue records",
                columns: [
                    column(table: "payment_records", name: "id", ordinal: 1),
                    column(table: "payment_records", name: "customer_id", ordinal: 2),
                    column(table: "payment_records", name: "paid_at", ordinal: 3),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "benchmark_runs",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "benchmark_runs",
                        name: "status",
                        dataType: "text",
                        isNullable: false,
                        ordinalPosition: 1,
                        valueConstraints: [
                            ColumnValueConstraint(
                                kind: .check,
                                values: ["scheduled", "running", "succeeded", "failed"],
                                expression: "CHECK (status IN ('scheduled', 'running', 'succeeded', 'failed'))",
                                constraintName: "benchmark_runs_status_check"
                            )
                        ]
                    )
                ]
            ),
            TableInfo(
                schema: "public",
                name: "invoices",
                type: .baseTable,
                columns: [
                    column(table: "invoices", name: "id", ordinal: 1),
                    column(table: "invoices", name: "invoice_number", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "orders",
                type: .baseTable,
                columns: [
                    column(table: "orders", name: "id", ordinal: 1),
                    column(table: "orders", name: "customer_id", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "products",
                type: .baseTable,
                columns: [
                    column(table: "products", name: "id", ordinal: 1),
                    column(table: "products", name: "name", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "order_products",
                type: .baseTable,
                columns: [
                    column(table: "order_products", name: "order_id", ordinal: 1),
                    column(table: "order_products", name: "product_id", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "accounts",
                type: .baseTable,
                columns: [
                    column(table: "accounts", name: "tenant_id", ordinal: 1),
                    column(table: "accounts", name: "external_id", ordinal: 2),
                    column(table: "accounts", name: "name", ordinal: 3),
                ],
                keyConstraints: [
                    SchemaKeyConstraintInfo(
                        constraintName: "accounts_tenant_external_key",
                        schema: "public",
                        table: "accounts",
                        kind: .unique,
                        columns: ["tenant_id", "external_id"]
                    )
                ]
            ),
            TableInfo(
                schema: "public",
                name: "account_events",
                type: .baseTable,
                columns: [
                    column(table: "account_events", name: "tenant_id", ordinal: 1),
                    column(table: "account_events", name: "external_id", ordinal: 2),
                    column(table: "account_events", name: "event_status", ordinal: 3),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "tools",
                type: .baseTable,
                columns: [
                    column(table: "tools", name: "id", ordinal: 1),
                    column(table: "tools", name: "name", ordinal: 2),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "tool_matches",
                type: .baseTable,
                columns: [
                    column(table: "tool_matches", name: "winner_tool_id", ordinal: 1),
                    column(table: "tool_matches", name: "loser_tool_id", ordinal: 2),
                ]
            ),
        ]

        let foreignKeyConstraints = [
            fk("order_products_order_fkey", from: "order_products", "order_id", to: "orders", "id"),
            fk("order_products_product_fkey", from: "order_products", "product_id", to: "products", "id"),
            SchemaForeignKeyConstraintInfo(
                constraintName: "account_events_account_fkey",
                sourceSchema: "public",
                sourceTable: "account_events",
                targetSchema: "public",
                targetTable: "accounts",
                columnPairs: [
                    SchemaForeignKeyColumnPair(
                        sourceColumn: "tenant_id",
                        targetColumn: "tenant_id",
                        ordinalPosition: 1
                    ),
                    SchemaForeignKeyColumnPair(
                        sourceColumn: "external_id",
                        targetColumn: "external_id",
                        ordinalPosition: 2
                    ),
                ]
            ),
            fk("tool_matches_winner_fkey", from: "tool_matches", "winner_tool_id", to: "tools", "id"),
            fk("tool_matches_loser_fkey", from: "tool_matches", "loser_tool_id", to: "tools", "id"),
        ]

        return DatabaseSchema(
            schemas: [SchemaInfo(name: "auth"), SchemaInfo(name: "noise"), SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: foreignKeyConstraints.flatMap { legacyForeignKeys(from: $0) },
            foreignKeyConstraints: foreignKeyConstraints
        )
    }

    private static func column(
        schema: String = "public",
        table: String,
        name: String,
        ordinal: Int,
        comment: String? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            tableSchema: schema,
            tableName: table,
            name: name,
            comment: comment,
            dataType: "text",
            isNullable: true,
            ordinalPosition: ordinal
        )
    }

    private static func fk(
        _ name: String,
        from sourceTable: String,
        _ sourceColumn: String,
        to targetTable: String,
        _ targetColumn: String
    ) -> SchemaForeignKeyConstraintInfo {
        SchemaForeignKeyConstraintInfo(
            constraintName: name,
            sourceSchema: "public",
            sourceTable: sourceTable,
            targetSchema: "public",
            targetTable: targetTable,
            columnPairs: [
                SchemaForeignKeyColumnPair(
                    sourceColumn: sourceColumn,
                    targetColumn: targetColumn,
                    ordinalPosition: 1
                )
            ]
        )
    }

    private static func legacyForeignKeys(
        from constraint: SchemaForeignKeyConstraintInfo
    ) -> [ForeignKeyInfo] {
        constraint.columnPairs.map { pair in
            ForeignKeyInfo(
                constraintName: constraint.constraintName,
                sourceSchema: constraint.sourceSchema,
                sourceTable: constraint.sourceTable,
                sourceColumn: pair.sourceColumn,
                targetSchema: constraint.targetSchema,
                targetTable: constraint.targetTable,
                targetColumn: pair.targetColumn,
                ordinalPosition: pair.ordinalPosition
            )
        }
    }
}

private func schemaRetrievalMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    return Int(milliseconds)
}
