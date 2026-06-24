import Foundation

public struct TextToSQLEvalSuite: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var cases: [TextToSQLEvalCase]

    public init(name: String, version: String, cases: [TextToSQLEvalCase]) {
        self.name = name
        self.version = version
        self.cases = cases
    }
}

public struct TextToSQLEvalCase: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var schemaFixture: String
    public var question: String
    public var databaseContext: String?
    public var expected: TextToSQLEvalExpectation

    public init(
        id: String,
        schemaFixture: String,
        question: String,
        databaseContext: String? = nil,
        expected: TextToSQLEvalExpectation
    ) {
        self.id = id
        self.schemaFixture = schemaFixture
        self.question = question
        self.databaseContext = databaseContext
        self.expected = expected
    }
}

public struct TextToSQLEvalExpectation: Codable, Equatable, Sendable {
    public var decision: TextToSQLEvalDecision
    public var requiredTables: [String]
    public var requiredColumnBindings: [String]
    public var forbiddenColumnBindings: [String]
    public var requiredOperations: [TextToSQLEvalOperation]
    public var clarificationMustMentionAny: [String]
    public var goldenSQL: String?
    public var semantic: TextToSQLSemanticExpectation?

    public init(
        decision: TextToSQLEvalDecision,
        requiredTables: [String] = [],
        requiredColumnBindings: [String] = [],
        forbiddenColumnBindings: [String] = [],
        requiredOperations: [TextToSQLEvalOperation] = [],
        clarificationMustMentionAny: [String] = [],
        goldenSQL: String? = nil,
        semantic: TextToSQLSemanticExpectation? = nil
    ) {
        self.decision = decision
        self.requiredTables = requiredTables
        self.requiredColumnBindings = requiredColumnBindings
        self.forbiddenColumnBindings = forbiddenColumnBindings
        self.requiredOperations = requiredOperations
        self.clarificationMustMentionAny = clarificationMustMentionAny
        self.goldenSQL = goldenSQL
        self.semantic = semantic
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case requiredTables
        case requiredColumnBindings
        case forbiddenColumnBindings
        case requiredOperations
        case clarificationMustMentionAny
        case goldenSQL
        case semantic
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(TextToSQLEvalDecision.self, forKey: .decision)
        requiredTables = try container.decodeIfPresent([String].self, forKey: .requiredTables) ?? []
        requiredColumnBindings =
            try container.decodeIfPresent([String].self, forKey: .requiredColumnBindings) ?? []
        forbiddenColumnBindings =
            try container.decodeIfPresent([String].self, forKey: .forbiddenColumnBindings) ?? []
        requiredOperations =
            try container.decodeIfPresent([TextToSQLEvalOperation].self, forKey: .requiredOperations) ?? []
        clarificationMustMentionAny =
            try container.decodeIfPresent([String].self, forKey: .clarificationMustMentionAny) ?? []
        goldenSQL = try container.decodeIfPresent(String.self, forKey: .goldenSQL)
        semantic = try container.decodeIfPresent(TextToSQLSemanticExpectation.self, forKey: .semantic)
    }
}

public enum TextToSQLEvalDecision: String, Codable, Equatable, Sendable {
    case sql
    case clarify
}

public enum TextToSQLEvalOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case average
    case count
    case descendingOrder = "descending-order"
    case group
    case join
    case leftJoin = "left-join"
    case limit
    case notExists = "not-exists"
    case nullFilter = "null-filter"
    case relativeTimeFilter = "relative-time-filter"
    case sum
}

public enum TextToSQLResultComparisonMode: String, Codable, CaseIterable, Equatable, Sendable {
    case ordered
    case unordered
    case scalar
    case projectedColumns
}

public struct TextToSQLSemanticColumnExpectation: Codable, Equatable, Sendable {
    public var canonicalName: String
    public var aliases: [String]

    public init(canonicalName: String, aliases: [String] = []) {
        self.canonicalName = canonicalName
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalName
        case aliases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalName = try container.decode(String.self, forKey: .canonicalName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

public struct TextToSQLSemanticNegativeControl: Codable, Equatable, Sendable {
    public var id: String
    public var sql: String
    public var comparisonMode: TextToSQLResultComparisonMode?

    public init(
        id: String,
        sql: String,
        comparisonMode: TextToSQLResultComparisonMode? = nil
    ) {
        self.id = id
        self.sql = sql
        self.comparisonMode = comparisonMode
    }
}

public struct TextToSQLSemanticExpectation: Codable, Equatable, Sendable {
    public var comparisonMode: TextToSQLResultComparisonMode
    public var requiredColumns: [TextToSQLSemanticColumnExpectation]
    public var allowExtraCandidateColumns: Bool
    public var floatTolerance: Double
    public var negativeControls: [TextToSQLSemanticNegativeControl]

    public init(
        comparisonMode: TextToSQLResultComparisonMode,
        requiredColumns: [TextToSQLSemanticColumnExpectation] = [],
        allowExtraCandidateColumns: Bool = false,
        floatTolerance: Double = 0,
        negativeControls: [TextToSQLSemanticNegativeControl] = []
    ) {
        self.comparisonMode = comparisonMode
        self.requiredColumns = requiredColumns
        self.allowExtraCandidateColumns = allowExtraCandidateColumns
        self.floatTolerance = floatTolerance
        self.negativeControls = negativeControls
    }

    private enum CodingKeys: String, CodingKey {
        case comparisonMode
        case requiredColumns
        case allowExtraCandidateColumns
        case floatTolerance
        case negativeControls
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comparisonMode = try container.decode(
            TextToSQLResultComparisonMode.self,
            forKey: .comparisonMode
        )
        requiredColumns =
            try container.decodeIfPresent(
                [TextToSQLSemanticColumnExpectation].self,
                forKey: .requiredColumns
            ) ?? []
        allowExtraCandidateColumns =
            try container.decodeIfPresent(Bool.self, forKey: .allowExtraCandidateColumns) ?? false
        floatTolerance =
            try container.decodeIfPresent(Double.self, forKey: .floatTolerance) ?? 0
        negativeControls =
            try container.decodeIfPresent(
                [TextToSQLSemanticNegativeControl].self,
                forKey: .negativeControls
            ) ?? []
    }
}
