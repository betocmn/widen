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
    public var goldenSQL: String?

    public init(
        decision: TextToSQLEvalDecision,
        requiredTables: [String] = [],
        requiredColumnBindings: [String] = [],
        forbiddenColumnBindings: [String] = [],
        requiredOperations: [TextToSQLEvalOperation] = [],
        goldenSQL: String? = nil
    ) {
        self.decision = decision
        self.requiredTables = requiredTables
        self.requiredColumnBindings = requiredColumnBindings
        self.forbiddenColumnBindings = forbiddenColumnBindings
        self.requiredOperations = requiredOperations
        self.goldenSQL = goldenSQL
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case requiredTables
        case requiredColumnBindings
        case forbiddenColumnBindings
        case requiredOperations
        case goldenSQL
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
        goldenSQL = try container.decodeIfPresent(String.self, forKey: .goldenSQL)
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
