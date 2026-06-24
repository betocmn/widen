import Foundation

struct LocalSchemaSearchIndex: Codable, Sendable {
    static let formatVersion = 1
    static let scorerVersion = "schema-search-bm25-v1"

    var formatVersion: Int
    var tokenizerVersion: String
    var scorerVersion: String
    var schemaFingerprint: String
    var selectedSchemas: [String]
    var documents: [SchemaSearchDocument]
    var documentFrequency: [String: Int]
    var averageDocumentLength: Double
    var foreignKeyConstraints: [SchemaForeignKeyConstraintInfo]
    var buildDurationMs: Int
    var serializedSizeBytes: Int?

    static func build(
        snapshot: SchemaSearchSnapshot,
        fingerprint: String,
        buildDurationMs: Int = 0
    ) -> LocalSchemaSearchIndex {
        let started = ContinuousClock.now
        var documents: [SchemaSearchDocument] = []
        let relationships = snapshot.schema.effectiveForeignKeyConstraints
        let relationshipsByTable = Dictionary(grouping: relationships.flatMap { relationship in
            [
                (key: "\(relationship.sourceSchema).\(relationship.sourceTable)", value: relationship),
                (key: "\(relationship.targetSchema).\(relationship.targetTable)", value: relationship),
            ]
        }, by: \.key).mapValues { $0.map(\.value) }

        for table in snapshot.schema.tables.sorted(by: tableSort) {
            documents.append(
                SchemaSearchDocument(
                    table: table,
                    relationships: relationshipsByTable[table.qualifiedName] ?? []
                )
            )
        }

        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document.terms.map(\.term)) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let averageLength = documents.isEmpty
            ? 0
            : documents.map(\.length).reduce(0, +) / Double(documents.count)
        let elapsed = schemaSearchMilliseconds(started.duration(to: .now))

        return LocalSchemaSearchIndex(
            formatVersion: formatVersion,
            tokenizerVersion: SchemaSearchTokenizer.version,
            scorerVersion: scorerVersion,
            schemaFingerprint: fingerprint,
            selectedSchemas: snapshot.selectedSchemas.sorted(),
            documents: documents,
            documentFrequency: documentFrequency,
            averageDocumentLength: averageLength,
            foreignKeyConstraints: relationships,
            buildDurationMs: buildDurationMs > 0 ? buildDurationMs : elapsed,
            serializedSizeBytes: nil
        )
    }

    private static func tableSort(_ lhs: TableInfo, _ rhs: TableInfo) -> Bool {
        if lhs.schema == rhs.schema {
            return lhs.name < rhs.name
        }
        return lhs.schema < rhs.schema
    }
}

func schemaSearchMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    return Int(milliseconds)
}

struct SchemaSearchDocument: Codable, Equatable, Sendable {
    var tableID: SchemaObjectID
    var schema: String
    var tableName: String
    var qualifiedName: String
    var exactAliases: [String]
    var lowercasedAliases: [String]
    var columnIDs: [SchemaObjectID]
    var columnNamesByID: [String: String]
    var terms: [SchemaSearchDocumentTerm]
    var length: Double

    init(table: TableInfo, relationships: [SchemaForeignKeyConstraintInfo]) {
        self.tableID = .table(schema: table.schema, name: table.name)
        self.schema = table.schema
        self.tableName = table.name
        self.qualifiedName = table.qualifiedName
        self.exactAliases = Array(
            SchemaSearchTokenizer.identifierAliases(schema: table.schema, table: table.name)
        ).sorted()
        self.lowercasedAliases = Array(Set(exactAliases.map { $0.lowercased() })).sorted()
        self.columnIDs = table.columns.map {
            .column(schema: $0.tableSchema, table: $0.tableName, name: $0.name)
        }
        self.columnNamesByID = Dictionary(
            uniqueKeysWithValues: table.columns.map {
                (
                    SchemaObjectID.column(
                        schema: $0.tableSchema,
                        table: $0.tableName,
                        name: $0.name
                    ).stableString,
                    $0.name
                )
            }
        )

        var builder = SchemaSearchDocumentBuilder()
        builder.addIdentifier(table.qualifiedName, field: .exactTableQualified, objectID: tableID)
        builder.addIdentifier(table.name, field: .exactTableUnqualified, objectID: tableID)
        builder.addText(table.schema, field: .schemaName, objectID: .schema(table.schema))
        builder.addText(
            SchemaSearchTokenizer.sanitizedComment(table.comment),
            field: .tableComment,
            objectID: tableID
        )

        for column in table.columns {
            let columnID = SchemaObjectID.column(
                schema: column.tableSchema,
                table: column.tableName,
                name: column.name
            )
            builder.addIdentifier(column.name, field: .columnName, objectID: columnID)
            builder.addText(column.dataType, field: .dataType, objectID: columnID)
            builder.addText(
                SchemaSearchTokenizer.sanitizedComment(column.comment),
                field: .columnComment,
                objectID: columnID
            )
            for constraint in column.valueConstraints ?? [] {
                for value in constraint.values {
                    builder.addText(value, field: .valueConstraint, objectID: columnID)
                }
                if let name = constraint.constraintName {
                    builder.addIdentifier(name, field: .constraintName, objectID: columnID)
                }
                if let expression = constraint.expression {
                    builder.addText(expression, field: .valueConstraint, objectID: columnID)
                }
            }
        }

        for key in table.keyConstraints {
            let keyID = SchemaObjectID.keyConstraint(
                schema: key.schema,
                table: key.table,
                name: key.constraintName
            )
            builder.addIdentifier(key.constraintName, field: .constraintName, objectID: keyID)
            for column in key.columns {
                builder.addIdentifier(column, field: .keyColumn, objectID: keyID)
            }
        }

        for relationship in relationships {
            let relationshipID = SchemaObjectID.foreignKeyConstraint(
                schema: relationship.sourceSchema,
                table: relationship.sourceTable,
                name: relationship.constraintName
            )
            builder.addIdentifier(
                relationship.constraintName,
                field: .constraintName,
                objectID: relationshipID
            )
            let otherTable = relationship.sourceSchema == table.schema
                && relationship.sourceTable == table.name
                ? (relationship.targetSchema, relationship.targetTable)
                : (relationship.sourceSchema, relationship.sourceTable)
            builder.addIdentifier(otherTable.1, field: .connectedTableName, objectID: relationshipID)
            builder.addText(otherTable.0, field: .foreignKeyNeighbor, objectID: relationshipID)
            for pair in relationship.columnPairs {
                builder.addIdentifier(
                    "\(pair.sourceColumn) \(pair.targetColumn)",
                    field: .connectedColumnPair,
                    objectID: relationshipID
                )
            }
        }

        self.terms = builder.terms.sorted()
        self.length = min(Double(max(terms.count, 1)), 120)
    }

    func termCounts() -> [String: [SchemaSearchField: Double]] {
        var counts: [String: [SchemaSearchField: Double]] = [:]
        for term in terms {
            counts[term.term, default: [:]][term.field, default: 0] += 1
        }
        return counts
    }

    func origins(for term: String) -> [SchemaSearchDocumentTerm] {
        terms.filter { $0.term == term }
    }
}

struct SchemaSearchDocumentTerm: Codable, Equatable, Hashable, Sendable, Comparable {
    var term: String
    var field: SchemaSearchField
    var objectID: SchemaObjectID?

    static func < (lhs: SchemaSearchDocumentTerm, rhs: SchemaSearchDocumentTerm) -> Bool {
        if lhs.term == rhs.term {
            if lhs.field.rawValue == rhs.field.rawValue {
                return (lhs.objectID?.stableString ?? "") < (rhs.objectID?.stableString ?? "")
            }
            return lhs.field.rawValue < rhs.field.rawValue
        }
        return lhs.term < rhs.term
    }
}

private struct SchemaSearchDocumentBuilder {
    private var seen = Set<SchemaSearchDocumentTerm>()
    private(set) var terms: [SchemaSearchDocumentTerm] = []

    mutating func addIdentifier(
        _ text: String,
        field: SchemaSearchField,
        objectID: SchemaObjectID?
    ) {
        addTerms(
            SchemaSearchTokenizer.indexTokens(in: text),
            field: field,
            objectID: objectID
        )
    }

    mutating func addText(
        _ text: String,
        field: SchemaSearchField,
        objectID: SchemaObjectID?
    ) {
        guard !text.isEmpty else { return }
        addTerms(
            SchemaSearchTokenizer.indexTokens(in: text),
            field: field,
            objectID: objectID
        )
    }

    private mutating func addTerms(
        _ values: [String],
        field: SchemaSearchField,
        objectID: SchemaObjectID?
    ) {
        for value in values {
            let term = SchemaSearchDocumentTerm(term: value, field: field, objectID: objectID)
            if seen.insert(term).inserted {
                terms.append(term)
            }
        }
    }
}

extension DatabaseSchema {
    var effectiveForeignKeyConstraints: [SchemaForeignKeyConstraintInfo] {
        let grouped = foreignKeyConstraints.isEmpty
            ? DatabaseSchema.groupForeignKeys(foreignKeys)
            : foreignKeyConstraints
        return grouped.sorted {
            if $0.sourceSchema == $1.sourceSchema {
                if $0.sourceTable == $1.sourceTable {
                    if $0.targetSchema == $1.targetSchema {
                        if $0.targetTable == $1.targetTable {
                            return $0.constraintName < $1.constraintName
                        }
                        return $0.targetTable < $1.targetTable
                    }
                    return $0.targetSchema < $1.targetSchema
                }
                return $0.sourceTable < $1.sourceTable
            }
            return $0.sourceSchema < $1.sourceSchema
        }
    }
}
