import Foundation

public struct TextToSQLEvalRunOptions: Equatable, Sendable {
    public var backend: TextToSQLEvalBackend
    public var model: String?
    public var repeatIndex: Int
    public var defaultRowLimit: Int
    public var promptSize: Int?
    public var recordedPrompt: String?

    public init(
        backend: TextToSQLEvalBackend,
        model: String? = nil,
        repeatIndex: Int = 1,
        defaultRowLimit: Int = 100,
        promptSize: Int? = nil,
        recordedPrompt: String? = nil
    ) {
        self.backend = backend
        self.model = model
        self.repeatIndex = repeatIndex
        self.defaultRowLimit = defaultRowLimit
        self.promptSize = promptSize
        self.recordedPrompt = recordedPrompt
    }
}

public enum TextToSQLEvalCaseRunner {
    public static func run(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generator: any SQLGenerator,
        options: TextToSQLEvalRunOptions
    ) async -> TextToSQLEvalResult {
        let started = Date()
        do {
            let generated = try await generator.generateSQL(
                question: evalCase.question,
                schema: schema,
                context: SQLGenerationContext(),
                config: SQLGenerationConfig(
                    defaultRowLimit: options.defaultRowLimit,
                    databaseContext: evalCase.databaseContext ?? ""
                )
            )
            let enriched = GeneratedSQLPostprocessor.enriched(
                generated,
                question: evalCase.question,
                schema: schema,
                databaseContext: evalCase.databaseContext ?? "",
                allowGroundingClarification: false
            )
            return TextToSQLEvalScorer.score(
                evalCase: evalCase,
                schema: schema,
                generation: enriched,
                options: options,
                latencyMs: elapsedMilliseconds(since: started)
            )
        } catch {
            return failureResult(
                evalCase: evalCase,
                options: options,
                error: error,
                latencyMs: elapsedMilliseconds(since: started)
            )
        }
    }

    private static func isStructuredParseFailureMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unparseable")
            || lower.contains("structured")
            || lower.contains("decoding")
            || lower.contains("decoded")
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    private static func failureResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        error: any Error,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        let status: TextToSQLEvalCaseStatus
        let backendAvailable: Bool
        let transportSuccess: Bool
        let structuredParsed: Bool
        if let appError = error as? AppError {
            switch appError {
            case .modelUnavailable:
                status = .backendUnavailable
                backendAvailable = false
                transportSuccess = false
                structuredParsed = false
            case .modelGenerationFailed(let message)
                where isStructuredParseFailureMessage(message):
                status = .parseFailure
                backendAvailable = true
                transportSuccess = true
                structuredParsed = false
            default:
                status = .transportFailure
                backendAvailable = true
                transportSuccess = false
                structuredParsed = false
            }
        } else {
            status = .transportFailure
            backendAvailable = true
            transportSuccess = false
            structuredParsed = false
        }
        let coverage = evalCase.expected.decision == .sql ? 0.0 : 1.0

        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: backendAvailable,
                transportSuccess: transportSuccess,
                structuredResponseParsed: structuredParsed,
                decisionMatches: false,
                requiredTableCoverage: coverage,
                requiredColumnBindingCoverage: coverage,
                latencyMs: latencyMs,
                promptSize: options.promptSize
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: error.localizedDescription),
            recordedPrompt: options.recordedPrompt
        )
    }
}

public enum TextToSQLEvalScorer {
    public static func score(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generation: SQLGenerationResult,
        options: TextToSQLEvalRunOptions,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        let expected = evalCase.expected
        let actualDecision: TextToSQLEvalDecision =
            generation.needsClarification ? .clarify : .sql
        let decisionMatches = actualDecision == expected.decision

        if expected.decision == .clarify {
            let quality = clarificationQuality(generation.clarificationQuestion)
            let status: TextToSQLEvalCaseStatus = decisionMatches && quality ? .passed : .wrongDecision
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: status,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: decisionMatches,
                    clarificationQuality: quality,
                    latencyMs: latencyMs,
                    modelCallCount: generation.generationCallCount,
                    promptSize: options.promptSize
                ),
                diagnostics: TextToSQLEvalDiagnostics(),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                recordedPrompt: options.recordedPrompt
            )
        }

        guard decisionMatches else {
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: .wrongDecision,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: false,
                    requiredTableCoverage: 0,
                    requiredColumnBindingCoverage: 0,
                    clarificationQuality: clarificationQuality(generation.clarificationQuestion),
                    latencyMs: latencyMs,
                    modelCallCount: generation.generationCallCount,
                    promptSize: options.promptSize
                ),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                recordedPrompt: options.recordedPrompt
            )
        }

        let safety = SQLSafetyValidator.validate(generation.sql)
        guard safety.isValid else {
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: .invalidSQL,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: true,
                    safetyValid: false,
                    schemaValid: nil,
                    requiredTableCoverage: 0,
                    requiredColumnBindingCoverage: 0,
                    latencyMs: latencyMs,
                    modelCallCount: generation.generationCallCount,
                    promptSize: options.promptSize
                ),
                diagnostics: TextToSQLEvalDiagnostics(safetyErrors: safety.errors),
                generatedSQL: generation.sql.nilIfBlank,
                referencedTables: generation.referencedTables,
                recordedPrompt: options.recordedPrompt
            )
        }

        let schemaValidation = SQLSchemaValidator.validate(sql: generation.sql, against: schema)
        let referencedTables = Set(schemaValidation.referencedTables.map(normalizeBinding))
        let missingTables = expected.requiredTables.filter {
            !referencedTables.contains(normalizeBinding($0))
        }
        let referencedColumnBindings = referencedColumns(in: generation.sql, schema: schema)
        let referencedColumnSet = Set(referencedColumnBindings.map(normalizeBinding))
        let missingColumnBindings = expected.requiredColumnBindings.filter {
            !referencedColumnSet.contains(normalizeBinding($0))
        }
        let forbiddenBindingViolations = expected.forbiddenColumnBindings.filter {
            referencedColumnSet.contains(normalizeBinding($0))
        }
        let operations = detectedOperations(in: generation.sql)
        let missingOperations = expected.requiredOperations.filter { !operations.contains($0) }

        let tableCoverage = coverage(
            total: expected.requiredTables.count,
            missing: missingTables.count
        )
        let columnCoverage = coverage(
            total: expected.requiredColumnBindings.count,
            missing: missingColumnBindings.count
        )
        let schemaValid = !schemaValidation.hasDefiniteErrors
        let status: TextToSQLEvalCaseStatus
        if !schemaValid {
            status = .wrongSchemaObjects
        } else if missingTables.isEmpty,
            missingColumnBindings.isEmpty,
            forbiddenBindingViolations.isEmpty,
            missingOperations.isEmpty
        {
            status = .passed
        } else {
            status = .wrongSchemaObjects
        }

        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: true,
                structuredResponseParsed: true,
                decisionMatches: true,
                safetyValid: true,
                schemaValid: schemaValid,
                requiredTableCoverage: tableCoverage,
                requiredColumnBindingCoverage: columnCoverage,
                forbiddenBindingViolations: forbiddenBindingViolations,
                latencyMs: latencyMs,
                modelCallCount: generation.generationCallCount,
                promptSize: options.promptSize
            ),
            diagnostics: TextToSQLEvalDiagnostics(
                missingTables: missingTables,
                missingColumnBindings: missingColumnBindings,
                missingOperations: missingOperations,
                schemaErrors: schemaValidation.errors
            ),
            generatedSQL: generation.sql.nilIfBlank,
            clarificationQuestion: generation.clarificationQuestion,
            referencedTables: schemaValidation.referencedTables,
            referencedColumnBindings: referencedColumnBindings,
            recordedPrompt: options.recordedPrompt
        )
    }

    private static func coverage(total: Int, missing: Int) -> Double {
        guard total > 0 else { return 1 }
        return Double(total - missing) / Double(total)
    }

    private static func clarificationQuality(_ value: String?) -> Bool {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return false }
        let lower = text.lowercased()
        return lower.contains("?")
            || lower.contains("define")
            || lower.contains("which")
            || lower.contains("what")
            || lower.contains("clarif")
    }

    private static func detectedOperations(in sql: String) -> Set<TextToSQLEvalOperation> {
        let lower = sql.lowercased()
        var result = Set<TextToSQLEvalOperation>()
        if matches(#"\bcount\s*\("#, in: lower) {
            result.insert(.count)
        }
        if matches(#"\bavg\s*\("#, in: lower) {
            result.insert(.average)
        }
        if matches(#"\bsum\s*\("#, in: lower) {
            result.insert(.sum)
        }
        if matches(#"\bgroup\s+by\b"#, in: lower) {
            result.insert(.group)
        }
        if matches(#"\bjoin\b"#, in: lower) {
            result.insert(.join)
        }
        if matches(#"\bleft\s+(outer\s+)?join\b"#, in: lower) {
            result.insert(.leftJoin)
            result.insert(.join)
        }
        if matches(#"\bnot\s+exists\b"#, in: lower) {
            result.insert(.notExists)
        }
        if matches(#"\bis\s+null\b"#, in: lower) {
            result.insert(.nullFilter)
        }
        if matches(#"\border\s+by\b"#, in: lower), matches(#"\bdesc\b"#, in: lower) {
            result.insert(.descendingOrder)
        }
        if matches(#"\blimit\s+\d+\b"#, in: lower) {
            result.insert(.limit)
        }
        if matches(#"\binterval\b"#, in: lower)
            || matches(#"\bcurrent_date\b"#, in: lower)
            || matches(#"\bcurrent_timestamp\b"#, in: lower)
            || lower.contains("now()")
        {
            result.insert(.relativeTimeFilter)
        }
        return result
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func referencedColumns(in sql: String, schema: DatabaseSchema) -> [String] {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let relationAliases = relationAliasMap(analysis: analysis, schema: schema)
        let referencedTables = SQLSchemaValidator.validate(sql: sql, against: schema)
            .referencedTables
        let referencedTableInfos = schema.tables.filter { table in
            referencedTables.contains(table.qualifiedName)
        }
        var bindings: [String] = []

        for column in analysis.columns {
            if column.name == "*" {
                appendStarBindings(
                    qualifier: column.qualifier,
                    relationAliases: relationAliases,
                    referencedTables: referencedTableInfos,
                    into: &bindings
                )
            } else if let qualifier = column.qualifier,
                let table = relationAliases[normalizeBinding(qualifier)]
            {
                appendBinding(for: column, table: table, into: &bindings)
            } else if let qualifier = column.qualifier,
                let table = tableMatchingQualifier(qualifier, in: referencedTableInfos)
            {
                appendBinding(for: column, table: table, into: &bindings)
            } else if column.qualifier == nil {
                let matches = referencedTableInfos.filter {
                    columnNamed(column.name, isQuoted: column.isQuoted, existsIn: $0)
                }
                if matches.count == 1, let table = matches.first {
                    appendBinding(for: column, table: table, into: &bindings)
                }
            }
        }
        if containsUnqualifiedSelectStar(sql) {
            for table in referencedTableInfos {
                appendAllBindings(for: table, into: &bindings)
            }
        }

        var seen = Set<String>()
        return bindings.filter { seen.insert(normalizeBinding($0)).inserted }.sorted()
    }

    private static func appendStarBindings(
        qualifier: String?,
        relationAliases: [String: TableInfo],
        referencedTables: [TableInfo],
        into bindings: inout [String]
    ) {
        if let qualifier,
            let table = relationAliases[normalizeBinding(qualifier)]
        {
            appendAllBindings(for: table, into: &bindings)
            return
        }

        for table in referencedTables {
            appendAllBindings(for: table, into: &bindings)
        }
    }

    private static func relationAliasMap(
        analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema
    ) -> [String: TableInfo] {
        var result: [String: TableInfo] = [:]
        for relation in analysis.relations where !relation.isDerived {
            guard let table = table(for: relation, in: schema) else { continue }
            result[normalizeBinding(table.name)] = table
            result[normalizeBinding(table.qualifiedName)] = table
            if let alias = relation.alias {
                result[normalizeBinding(alias)] = table
            }
        }
        return result
    }

    private static func table(for relation: SQLRelationReference, in schema: DatabaseSchema) -> TableInfo? {
        schema.tables.first { table in
            let schemaMatches =
                relation.schema == nil
                || normalizeBinding(relation.schema ?? "") == normalizeBinding(table.schema)
            return schemaMatches && normalizeBinding(relation.name) == normalizeBinding(table.name)
        }
    }

    private static func tableMatchingQualifier(
        _ qualifier: String,
        in tables: [TableInfo]
    ) -> TableInfo? {
        let normalized = normalizeBinding(qualifier)
        return tables.first {
            normalizeBinding($0.name) == normalized || normalizeBinding($0.qualifiedName) == normalized
        }
    }

    private static func appendBinding(
        for column: SQLColumnReference,
        table: TableInfo,
        into bindings: inout [String]
    ) {
        guard let actual = table.columns.first(where: {
            columnMatches(column.name, isQuoted: column.isQuoted, actualName: $0.name)
        }) else { return }
        bindings.append("\(table.qualifiedName).\(actual.name)")
    }

    private static func appendAllBindings(for table: TableInfo, into bindings: inout [String]) {
        for column in table.columns {
            bindings.append("\(table.qualifiedName).\(column.name)")
        }
    }

    private static func containsUnqualifiedSelectStar(_ sql: String) -> Bool {
        matches(#"(?is)\bselect\s+(distinct\s+)?\*\s+\bfrom\b"#, in: sql)
    }

    private static func columnNamed(
        _ name: String,
        isQuoted: Bool,
        existsIn table: TableInfo
    ) -> Bool {
        table.columns.contains { columnMatches(name, isQuoted: isQuoted, actualName: $0.name) }
    }

    private static func columnMatches(
        _ reference: String,
        isQuoted: Bool,
        actualName: String
    ) -> Bool {
        if isQuoted {
            return reference == actualName
        }
        return reference.lowercased() == actualName.lowercased()
    }

    private static func normalizeBinding(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
