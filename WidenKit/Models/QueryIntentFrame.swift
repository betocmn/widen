import Foundation

public struct QueryIntentFrame: Codable, Equatable, Sendable {
    public var operation: QueryOperation
    public var subjectPhrases: [String]
    public var outputPhrases: [String]
    public var measure: MeasureIntent
    public var measurePhrase: String?
    public var groupingPhrases: [String]
    public var ranking: RankingIntent?
    public var requestedLimit: Int?
    public var filters: [FilterIntent]
    public var timeIntent: TimeIntent?
    public var customBusinessTerms: [String]
    public var schemaSearchQueries: [String]

    public init(
        operation: QueryOperation = .read,
        subjectPhrases: [String] = [],
        outputPhrases: [String] = [],
        measure: MeasureIntent = .none,
        measurePhrase: String? = nil,
        groupingPhrases: [String] = [],
        ranking: RankingIntent? = nil,
        requestedLimit: Int? = nil,
        filters: [FilterIntent] = [],
        timeIntent: TimeIntent? = nil,
        customBusinessTerms: [String] = [],
        schemaSearchQueries: [String] = []
    ) {
        self.operation = operation
        self.subjectPhrases = subjectPhrases
        self.outputPhrases = outputPhrases
        self.measure = measure
        self.measurePhrase = measurePhrase
        self.groupingPhrases = groupingPhrases
        self.ranking = ranking
        self.requestedLimit = requestedLimit
        self.filters = filters
        self.timeIntent = timeIntent
        self.customBusinessTerms = customBusinessTerms
        self.schemaSearchQueries = schemaSearchQueries
    }
}

public enum QueryOperation: String, Codable, Equatable, Sendable {
    case read
    case insert
    case update
    case delete
}

public enum MeasureIntent: String, Codable, Equatable, Sendable {
    case none
    case countRows
    case countDistinct
    case sum
    case average
    case minimum
    case maximum
    case custom
}

public enum RankingDirection: String, Codable, Equatable, Sendable {
    case ascending
    case descending
}

public struct RankingIntent: Codable, Equatable, Sendable {
    public var direction: RankingDirection
    public var takeFirst: Bool

    public init(direction: RankingDirection, takeFirst: Bool = false) {
        self.direction = direction
        self.takeFirst = takeFirst
    }
}

public struct FilterIntent: Codable, Equatable, Sendable {
    public var phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }
}

public struct TimeIntent: Codable, Equatable, Sendable {
    public var phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }
}

public struct GroundedQueryPlan: Codable, Equatable, Sendable {
    public var intent: QueryIntentFrame
    public var slots: [GroundingSlot]
    public var selectedTables: [String]
    public var selectedJoinPaths: [SchemaJoinPath]
    public var readiness: QueryPlanReadiness
    public var interpretationSummary: String

    public init(
        intent: QueryIntentFrame,
        slots: [GroundingSlot] = [],
        selectedTables: [String] = [],
        selectedJoinPaths: [SchemaJoinPath] = [],
        readiness: QueryPlanReadiness = .ready,
        interpretationSummary: String = ""
    ) {
        self.intent = intent
        self.slots = slots
        self.selectedTables = selectedTables
        self.selectedJoinPaths = selectedJoinPaths
        self.readiness = readiness
        self.interpretationSummary = interpretationSummary
    }
}

public struct GroundingSlotID: RawRepresentable, Codable, Hashable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let subject = GroundingSlotID(rawValue: "subject")
    public static let occurrenceRelation = GroundingSlotID(rawValue: "occurrenceRelation")
    public static let customBusinessTerm = GroundingSlotID(rawValue: "customBusinessTerm")
}

public struct GroundingSlot: Identifiable, Codable, Equatable, Sendable {
    public var id: GroundingSlotID
    public var kind: GroundingSlotKind
    public var phrase: String
    public var required: Bool
    public var candidates: [GroundingCandidate]
    public var selectedCandidate: GroundingCandidate?
    public var state: GroundingState

    public init(
        id: GroundingSlotID,
        kind: GroundingSlotKind,
        phrase: String,
        required: Bool,
        candidates: [GroundingCandidate] = [],
        selectedCandidate: GroundingCandidate? = nil,
        state: GroundingState
    ) {
        self.id = id
        self.kind = kind
        self.phrase = phrase
        self.required = required
        self.candidates = candidates
        self.selectedCandidate = selectedCandidate
        self.state = state
    }
}

public enum GroundingSlotKind: String, Codable, Equatable, Sendable {
    case subjectEntity
    case outputEntity
    case occurrenceRelation
    case measureColumn
    case groupingColumn
    case filterColumn
    case filterValue
    case timeColumn
    case relationshipPath
    case customBusinessTerm
}

public struct GroundingCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var objectIDs: [String]
    public var evidence: [String]

    public init(id: String, label: String, objectIDs: [String] = [], evidence: [String] = []) {
        self.id = id
        self.label = label
        self.objectIDs = objectIDs
        self.evidence = evidence
    }
}

public struct SchemaJoinPath: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var foreignKeys: [ForeignKeyInfo]
    public var summary: String

    public init(id: String, foreignKeys: [ForeignKeyInfo], summary: String) {
        self.id = id
        self.foreignKeys = foreignKeys
        self.summary = summary
    }
}

public enum QueryPlanReadiness: String, Codable, Equatable, Sendable {
    case ready
    case readyWithInterpretation
    case needsClarification
    case unsupported
}

public enum GroundingDecision: Equatable, Sendable {
    case ready
    case readyWithInterpretation(String)
    case needsClarification(PendingClarification)
    case unsupported(String)
}
