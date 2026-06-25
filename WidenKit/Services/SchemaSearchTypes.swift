import Foundation

public protocol SchemaSearching: Sendable {
    func search(
        _ request: SchemaSearchRequest,
        in snapshot: SchemaSearchSnapshot
    ) -> SchemaSearchResponse

    func describe(
        objectIDs: [SchemaObjectID],
        in snapshot: SchemaSearchSnapshot
    ) -> [SchemaObjectDescription]

    func findJoinPaths(
        from: SchemaObjectID,
        to: SchemaObjectID,
        maxHops: Int,
        in snapshot: SchemaSearchSnapshot
    ) -> [SchemaJoinPath]
}

public struct SchemaSearchSnapshot: Equatable, Sendable {
    public var connectionID: UUID
    public var selectedSchemas: [String]
    public var schema: DatabaseSchema

    public init(
        connectionID: UUID,
        selectedSchemas: [String],
        schema: DatabaseSchema
    ) {
        self.connectionID = connectionID
        self.selectedSchemas = selectedSchemas.sorted()
        self.schema = schema
    }
}

public struct SchemaSearchRequest: Equatable, Sendable {
    public var query: String
    public var databaseContext: String
    public var semanticBindingTerms: [String]
    public var limit: Int
    public var stageOneLimit: Int

    public init(
        query: String,
        databaseContext: String = "",
        semanticBindingTerms: [String] = [],
        limit: Int = 8,
        stageOneLimit: Int = 20
    ) {
        self.query = query
        self.databaseContext = databaseContext
        self.semanticBindingTerms = semanticBindingTerms
        self.limit = max(1, limit)
        self.stageOneLimit = max(1, stageOneLimit)
    }
}

public struct SchemaSearchResponse: Equatable, Sendable {
    public var hits: [SchemaSearchHit]
    public var queryTokenCoverage: Double
    public var topToSecondScoreMargin: Double?
    public var noStrongMatch: Bool
    public var exactIdentifierMatch: Bool
    public var queryLatencyMs: Int
    public var indexBuildDurationMs: Int?
    public var indexSerializedSizeBytes: Int?

    public init(
        hits: [SchemaSearchHit],
        queryTokenCoverage: Double,
        topToSecondScoreMargin: Double?,
        noStrongMatch: Bool,
        exactIdentifierMatch: Bool,
        queryLatencyMs: Int,
        indexBuildDurationMs: Int? = nil,
        indexSerializedSizeBytes: Int? = nil
    ) {
        self.hits = hits
        self.queryTokenCoverage = queryTokenCoverage
        self.topToSecondScoreMargin = topToSecondScoreMargin
        self.noStrongMatch = noStrongMatch
        self.exactIdentifierMatch = exactIdentifierMatch
        self.queryLatencyMs = queryLatencyMs
        self.indexBuildDurationMs = indexBuildDurationMs
        self.indexSerializedSizeBytes = indexSerializedSizeBytes
    }
}

public struct SchemaSearchHit: Codable, Equatable, Sendable {
    public var tableObjectID: SchemaObjectID
    public var totalScore: Double
    public var matchedTableTerms: [String]
    public var matchedColumnIDs: [SchemaObjectID]
    public var matchedFields: [SchemaSearchMatchedField]
    public var exactMatchScore: Double
    public var lexicalBM25Score: Double
    public var contextBoost: Double
    public var graphBoost: Double
    public var rank: Int

    public init(
        tableObjectID: SchemaObjectID,
        totalScore: Double,
        matchedTableTerms: [String],
        matchedColumnIDs: [SchemaObjectID],
        matchedFields: [SchemaSearchMatchedField],
        exactMatchScore: Double,
        lexicalBM25Score: Double,
        contextBoost: Double,
        graphBoost: Double,
        rank: Int
    ) {
        self.tableObjectID = tableObjectID
        self.totalScore = totalScore
        self.matchedTableTerms = matchedTableTerms
        self.matchedColumnIDs = matchedColumnIDs
        self.matchedFields = matchedFields
        self.exactMatchScore = exactMatchScore
        self.lexicalBM25Score = lexicalBM25Score
        self.contextBoost = contextBoost
        self.graphBoost = graphBoost
        self.rank = rank
    }
}

public struct SchemaSearchMatchedField: Codable, Equatable, Hashable, Sendable {
    public var field: SchemaSearchField
    public var term: String
    public var objectID: SchemaObjectID?

    public init(field: SchemaSearchField, term: String, objectID: SchemaObjectID? = nil) {
        self.field = field
        self.term = term
        self.objectID = objectID
    }
}

public enum SchemaSearchField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case exactTableQualified
    case exactTableUnqualified
    case columnName
    case tableComment
    case columnComment
    case keyColumn
    case valueConstraint
    case constraintName
    case connectedTableName
    case connectedColumnPair
    case dataType
    case schemaName
    case foreignKeyNeighbor

    var weight: Double {
        switch self {
        case .exactTableQualified:
            9
        case .exactTableUnqualified, .columnName:
            8
        case .tableComment, .columnComment, .keyColumn:
            5
        case .valueConstraint, .constraintName, .connectedTableName, .connectedColumnPair:
            3
        case .dataType, .schemaName, .foreignKeyNeighbor:
            1
        }
    }
}

public struct SchemaObjectDescription: Codable, Equatable, Sendable {
    public var objectID: SchemaObjectID
    public var kind: SchemaObjectKind
    public var schema: String
    public var table: String?
    public var column: String?
    public var dataType: String?
    public var isNullable: Bool?
    public var comment: String?
    public var columns: [String]
    public var keyConstraints: [SchemaKeyConstraintInfo]
    public var foreignKeyConstraints: [SchemaForeignKeyConstraintInfo]

    public init(
        objectID: SchemaObjectID,
        kind: SchemaObjectKind,
        schema: String,
        table: String? = nil,
        column: String? = nil,
        dataType: String? = nil,
        isNullable: Bool? = nil,
        comment: String? = nil,
        columns: [String] = [],
        keyConstraints: [SchemaKeyConstraintInfo] = [],
        foreignKeyConstraints: [SchemaForeignKeyConstraintInfo] = []
    ) {
        self.objectID = objectID
        self.kind = kind
        self.schema = schema
        self.table = table
        self.column = column
        self.dataType = dataType
        self.isNullable = isNullable
        self.comment = comment
        self.columns = columns
        self.keyConstraints = keyConstraints
        self.foreignKeyConstraints = foreignKeyConstraints
    }
}

public enum SchemaJoinTraversalDirection: String, Codable, Equatable, Hashable, Sendable {
    case forward
    case reverse
}

public struct SchemaJoinPathEdge: Codable, Equatable, Hashable, Sendable {
    public var constraintName: String
    public var fromTableID: SchemaObjectID
    public var toTableID: SchemaObjectID
    public var sourceTableID: SchemaObjectID
    public var targetTableID: SchemaObjectID
    public var columnPairs: [SchemaForeignKeyColumnPair]
    public var traversalDirection: SchemaJoinTraversalDirection

    public init(
        constraintName: String,
        fromTableID: SchemaObjectID,
        toTableID: SchemaObjectID,
        sourceTableID: SchemaObjectID,
        targetTableID: SchemaObjectID,
        columnPairs: [SchemaForeignKeyColumnPair],
        traversalDirection: SchemaJoinTraversalDirection
    ) {
        self.constraintName = constraintName
        self.fromTableID = fromTableID
        self.toTableID = toTableID
        self.sourceTableID = sourceTableID
        self.targetTableID = targetTableID
        self.columnPairs = columnPairs
        self.traversalDirection = traversalDirection
    }
}

public struct SchemaJoinPath: Codable, Equatable, Hashable, Sendable {
    public var edges: [SchemaJoinPathEdge]
    public var hopCount: Int { edges.count }

    public init(edges: [SchemaJoinPathEdge]) {
        self.edges = edges
    }
}
