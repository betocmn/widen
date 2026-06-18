import Foundation

public struct SQLSchemaValidationIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct SQLSchemaValidationResult: Equatable, Sendable {
    public var analysis: SQLReferenceAnalysis
    public var issues: [SQLSchemaValidationIssue]
    public var referencedTables: [String]

    public var errors: [String] {
        issues.filter { $0.severity == .error }.map(\.message)
    }

    public var warnings: [String] {
        issues.filter { $0.severity == .warning }.map(\.message)
    }

    public var hasDefiniteErrors: Bool {
        !errors.isEmpty
    }
}

public enum SQLSchemaValidator {
    public static func validate(
        sql: String,
        against schema: DatabaseSchema
    ) -> SQLSchemaValidationResult {
        validate(SQLReferenceAnalyzer.analyze(sql), against: schema)
    }

    public static func validate(
        _ analysis: SQLReferenceAnalysis,
        against schema: DatabaseSchema
    ) -> SQLSchemaValidationResult {
        let schemaIndex = SchemaLookup(schema: schema)
        var issues: [SQLSchemaValidationIssue] = []
        var resolvedRelations: [SQLRelationReference: TableInfo] = [:]
        var aliasToTable: [String: TableInfo] = [:]
        var referencedTables: [String] = []

        for relation in analysis.relations {
            guard let table = schemaIndex.resolve(relation) else {
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: table \(relation.displayName) is not in the selected schema."
                    ))
                continue
            }
            resolvedRelations[relation] = table
            referencedTables.append(table.qualifiedName)
            aliasToTable[table.name.lowercased()] = table
            aliasToTable[table.qualifiedName.lowercased()] = table
            if let alias = relation.alias {
                aliasToTable[alias.lowercased()] = table
            }
        }

        for column in analysis.columns {
            if let qualifier = column.qualifier {
                guard let table = aliasToTable[qualifier.lowercased()] else {
                    if analysis.cteNames.contains(qualifier.lowercased()) {
                        continue
                    }
                    issues.append(
                        SQLSchemaValidationIssue(
                            severity: .error,
                            message: "Schema validation failed: qualifier \(qualifier) does not resolve to a selected-schema table."
                        ))
                    continue
                }
                if !schemaIndex.table(table, containsColumn: column.name) {
                    issues.append(
                        SQLSchemaValidationIssue(
                            severity: .error,
                            message: "Schema validation failed: column \(column.name) is not on \(table.qualifiedName)."
                        ))
                }
                continue
            }

            if analysis.outputAliases.contains(column.name.lowercased()) {
                continue
            }
            let matchingTables = resolvedRelations.values.filter {
                schemaIndex.table($0, containsColumn: column.name)
            }
            switch matchingTables.count {
            case 0:
                if !resolvedRelations.isEmpty {
                    issues.append(
                        SQLSchemaValidationIssue(
                            severity: .error,
                            message: "Schema validation failed: column \(column.name) is not available from the referenced tables."
                        ))
                }
            case 1:
                break
            default:
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables."
                    ))
            }
        }

        if analysis.analysisIncomplete {
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .warning,
                    message: "Schema validation was incomplete for part of this SQL."
                ))
        }

        return SQLSchemaValidationResult(
            analysis: analysis,
            issues: issues,
            referencedTables: Array(Set(referencedTables)).sorted()
        )
    }
}

public enum GeneratedSQLPostprocessor {
    public static func enriched(
        _ generation: SQLGenerationResult,
        question: String,
        schema: DatabaseSchema,
        databaseContext: String
    ) -> SQLGenerationResult {
        guard !generation.needsClarification else { return generation }
        let sql = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return generation }

        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        if let clarification = businessTermClarification(
            question: question,
            schemaValidation: schemaValidation,
            schema: schema,
            databaseContext: databaseContext
        ) {
            return SQLGenerationResult(
                sql: "",
                explanation: "",
                assumptions: [],
                referencedTables: schemaValidation.referencedTables,
                confidence: 0,
                riskLevel: .high,
                needsClarification: true,
                clarificationQuestion: clarification
            )
        }

        var copy = generation
        copy.referencedTables = schemaValidation.referencedTables
        return copy
    }

    public static func businessTermClarification(
        question: String,
        schemaValidation: SQLSchemaValidationResult,
        schema: DatabaseSchema,
        databaseContext: String
    ) -> String? {
        let questionTokens = Set(SchemaIndex.tokens(in: question))
        guard !questionTokens.intersection(highRiskBusinessTerms).isEmpty else { return nil }
        let contextTokens = Set(SchemaIndex.tokens(in: databaseContext))
        if !contextTokens.intersection(highRiskBusinessTerms.union(supportingBusinessTokens)).isEmpty {
            return nil
        }

        let referencedTableIDs = Set(schemaValidation.referencedTables)
        let referencedTables = schema.tables.filter { referencedTableIDs.contains($0.qualifiedName) }
        let schemaTokens = Set(referencedTables.flatMap { table in
            SchemaIndex.tokens(in: table.name)
                + table.columns.flatMap { SchemaIndex.tokens(in: $0.name) }
        })
        guard schemaTokens.intersection(supportingBusinessTokens).isEmpty else { return nil }

        if questionTokens.contains("win") {
            return
                "I found match or tool fields, but the selected schema does not define which tool won. What table, column, or condition represents a win?"
        }
        return
            "I need the database-specific definition for this metric before I can write SQL safely. What table, column, or condition defines it?"
    }

    private static let highRiskBusinessTerms: Set<String> = [
        "win", "wins", "winner", "revenue", "active", "churn", "conversion", "success",
        "owner", "retained", "best",
    ]

    private static let supportingBusinessTokens: Set<String> = [
        "winner", "winning", "won", "win", "wins", "result", "outcome", "verdict",
        "score", "rank", "revenue", "amount", "active", "status", "success",
    ]
}

public enum GeneratedSQLValidator {
    public static func validate(sql: String, schema: DatabaseSchema) -> SQLValidationResult {
        combine(
            safety: SQLSafetyValidator.validate(sql),
            schemaValidation: SQLSchemaValidator.validate(sql: sql, against: schema)
        )
    }

    public static func combine(
        safety: SQLValidationResult,
        schemaValidation: SQLSchemaValidationResult
    ) -> SQLValidationResult {
        guard safety.isValid else { return safety }
        let errors = safety.errors + schemaValidation.errors
        return SQLValidationResult(
            isValid: errors.isEmpty,
            normalizedSQL: errors.isEmpty ? safety.normalizedSQL : nil,
            errors: errors,
            warnings: safety.warnings + schemaValidation.warnings,
            hasLimit: safety.hasLimit,
            kind: safety.kind,
            requiresConfirmation: safety.requiresConfirmation
        )
    }
}

private struct SchemaLookup {
    private var tablesByQualifiedName: [String: TableInfo] = [:]
    private var tablesByName: [String: [TableInfo]] = [:]
    private var columnsByTableID: [String: Set<String>] = [:]

    init(schema: DatabaseSchema) {
        for table in schema.tables {
            tablesByQualifiedName[table.qualifiedName.lowercased()] = table
            tablesByName[table.name.lowercased(), default: []].append(table)
            columnsByTableID[table.id] = Set(table.columns.map { $0.name.lowercased() })
        }
    }

    func resolve(_ relation: SQLRelationReference) -> TableInfo? {
        if let schema = relation.schema {
            return tablesByQualifiedName["\(schema).\(relation.name)".lowercased()]
        }
        let matches = tablesByName[relation.name.lowercased()] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func table(_ table: TableInfo, containsColumn column: String) -> Bool {
        columnsByTableID[table.id]?.contains(column.lowercased()) == true
    }
}
