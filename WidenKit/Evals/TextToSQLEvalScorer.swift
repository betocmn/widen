import Foundation

public struct TextToSQLEvalRunOptions: Equatable, Sendable {
    public var backend: TextToSQLEvalBackend
    public var model: String?
    public var repeatIndex: Int
    public var defaultRowLimit: Int
    public var estimatedInitialPromptCharacters: Int?
    public var estimatedInitialPrompt: String?

    public init(
        backend: TextToSQLEvalBackend,
        model: String? = nil,
        repeatIndex: Int = 1,
        defaultRowLimit: Int = 100,
        estimatedInitialPromptCharacters: Int? = nil,
        estimatedInitialPrompt: String? = nil
    ) {
        self.backend = backend
        self.model = model
        self.repeatIndex = repeatIndex
        self.defaultRowLimit = defaultRowLimit
        self.estimatedInitialPromptCharacters = estimatedInitialPromptCharacters
        self.estimatedInitialPrompt = estimatedInitialPrompt
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
            let run = try await TextToSQLPipeline(generator: generator).run(
                TextToSQLRequest(
                    question: evalCase.question,
                    schema: schema,
                    config: SQLGenerationConfig(
                        defaultRowLimit: options.defaultRowLimit,
                        databaseContext: evalCase.databaseContext ?? ""
                    ),
                    allowGroundingClarification: false
                )
            )
            switch run.finalDecision {
            case .sql(let generation), .clarification(let generation):
                return TextToSQLEvalScorer.score(
                    evalCase: evalCase,
                    schema: schema,
                    generation: generation,
                    options: options,
                    latencyMs: elapsedMilliseconds(since: started),
                    trace: run.trace
                )
            case .failed(let failure):
                return pipelineFailureResult(
                    evalCase: evalCase,
                    options: options,
                    failure: failure,
                    latencyMs: elapsedMilliseconds(since: started),
                    trace: run.trace
                )
            }
        } catch is CancellationError {
            return failureResult(
                evalCase: evalCase,
                options: options,
                error: CancellationError(),
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

    private static func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    private static func failureResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        error: any Error,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        let typed = SQLGenerationFailure.typed(error)
        let status = typed.map(status(for:)) ?? .transportFailure
        let backendAvailable = typed.map { $0.pipelineCategory != .backendUnavailable } ?? true
        let transportSuccess = typed.map {
            $0.pipelineCategory != .transport
                && $0.pipelineCategory != .backendUnavailable
        } ?? false
        let structuredParsed = false
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
                latencyMs: latencyMs,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: error.localizedDescription),
            estimatedInitialPrompt: options.estimatedInitialPrompt
        )
    }

    private static func pipelineFailureResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        failure: TextToSQLPipelineFailure,
        latencyMs: Int,
        trace: TextToSQLTrace
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status(for: failure.category),
            metrics: TextToSQLEvalMetrics(
                backendAvailable: failure.category != .backendUnavailable,
                transportSuccess: failure.category != .transport
                    && failure.category != .backendUnavailable,
                structuredResponseParsed: structuredResponseParsed(for: failure.category),
                decisionMatches: false,
                safetyValid: failure.category == .safetyValidation ? false : nil,
                schemaValid: (
                    failure.category == .schemaValidation
                        || failure.category == .repeatedNoProgressRepair
                ) ? false : nil,
                latencyMs: latencyMs,
                modelCallCount: trace.modelCalls == 0 ? nil : trace.modelCalls,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: failure.localizedDescription),
            estimatedInitialPrompt: options.estimatedInitialPrompt,
            trace: trace
        )
    }

    private static func status(for failure: SQLGenerationFailure) -> TextToSQLEvalCaseStatus {
        status(for: failure.pipelineCategory)
    }

    private static func status(for category: TextToSQLFailureCategory) -> TextToSQLEvalCaseStatus {
        switch category {
        case .backendUnavailable:
            .backendUnavailable
        case .transport:
            .transportFailure
        case .contextWindow:
            .contextWindowFailure
        case .structuredResponseParsing:
            .parseFailure
        case .modelGeneration, .cancellation, .emptySQL:
            .generationFailure
        case .safetyValidation:
            .invalidSQL
        case .schemaValidation, .repeatedNoProgressRepair:
            .wrongSchemaObjects
        }
    }

    private static func structuredResponseParsed(for category: TextToSQLFailureCategory) -> Bool {
        switch category {
        case .safetyValidation, .schemaValidation, .repeatedNoProgressRepair, .emptySQL:
            true
        case .backendUnavailable, .transport, .contextWindow, .structuredResponseParsing,
            .modelGeneration, .cancellation:
            false
        }
    }
}

public enum TextToSQLEvalScorer {
    public static func score(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generation: SQLGenerationResult,
        options: TextToSQLEvalRunOptions,
        latencyMs: Int,
        trace: TextToSQLTrace? = nil
    ) -> TextToSQLEvalResult {
        let expected = evalCase.expected
        let actualDecision: TextToSQLEvalDecision =
            generation.needsClarification ? .clarify : .sql
        let decisionMatches = actualDecision == expected.decision
        let modelCallCount = trace?.modelCalls == 0
            ? generation.generationCallCount
            : (trace?.modelCalls ?? generation.generationCallCount)

        if expected.decision == .clarify {
            let quality = clarificationQuality(
                generation.clarificationQuestion,
                mustMentionAny: expected.clarificationMustMentionAny
            )
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
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
                ),
                diagnostics: TextToSQLEvalDiagnostics(),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
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
                    clarificationQuality: clarificationQuality(
                        generation.clarificationQuestion,
                        mustMentionAny: expected.clarificationMustMentionAny
                    ),
                    latencyMs: latencyMs,
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
                ),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
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
                    latencyMs: latencyMs,
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
                ),
                diagnostics: TextToSQLEvalDiagnostics(safetyErrors: safety.errors),
                generatedSQL: generation.sql.nilIfBlank,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
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
        let missingOperations = missingOperations(
            for: expected,
            detected: operations,
            sql: generation.sql,
            schema: schema
        )

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
                modelCallCount: modelCallCount,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
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
            estimatedInitialPrompt: options.estimatedInitialPrompt,
            trace: trace
        )
    }

    private static func coverage(total: Int, missing: Int) -> Double {
        guard total > 0 else { return 1 }
        return Double(total - missing) / Double(total)
    }

    private static func clarificationQuality(
        _ value: String?,
        mustMentionAny configuredConcepts: [String]
    ) -> Bool {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return false }
        let candidateTokens = Set(normalizedTokens(in: text))
        guard !candidateTokens.isEmpty else { return false }
        return configuredConcepts.contains { concept in
            let conceptTokens = normalizedTokens(in: concept)
            return !conceptTokens.isEmpty && conceptTokens.contains { candidateTokens.contains($0) }
        }
    }

    private static func normalizedTokens(in value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
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
        if matches(#"\blimit\s+\d+\b"#, in: lower)
            || matches(#"\bfetch\s+(first|next)(\s+\d+)?\s+rows?\s+only\b"#, in: lower)
        {
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

    private static func missingOperations(
        for expected: TextToSQLEvalExpectation,
        detected operations: Set<TextToSQLEvalOperation>,
        sql: String,
        schema: DatabaseSchema
    ) -> [TextToSQLEvalOperation] {
        expected.requiredOperations.filter {
            !operationSatisfied(
                $0,
                expected: expected,
                detected: operations,
                sql: sql,
                schema: schema
            )
        }
    }

    private static func operationSatisfied(
        _ operation: TextToSQLEvalOperation,
        expected: TextToSQLEvalExpectation,
        detected operations: Set<TextToSQLEvalOperation>,
        sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let expectsAntiJoin =
            expected.requiredOperations.contains(.leftJoin)
            && expected.requiredOperations.contains(.nullFilter)
        if expectsAntiJoin, operations.contains(.notExists) {
            if operation == .leftJoin || operation == .nullFilter {
                return true
            }
        }

        if operation == .nullFilter,
            expected.requiredOperations.contains(.leftJoin),
            operations.contains(.leftJoin)
        {
            return nullFilterTargetsLeftJoinedRelation(in: sql, schema: schema)
        }

        return operations.contains(operation)
    }

    private static func nullFilterTargetsLeftJoinedRelation(
        in sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let leftJoinedTables = leftJoinedTableKeys(analysis: analysis, sql: sql, schema: schema)
        guard !leftJoinedTables.isEmpty else { return false }

        let relationAliases = relationAliasMap(analysis: analysis, schema: schema)
        let referencedTables = SQLSchemaValidator.validate(sql: sql, against: schema)
            .referencedTables
        let referencedTableInfos = schema.tables.filter { table in
            referencedTables.contains(table.qualifiedName)
        }

        return analysis.columns.contains { column in
            columnIsNullFiltered(column, in: sql)
                && resolvedTables(
                    for: column,
                    relationAliases: relationAliases,
                    referencedTables: referencedTableInfos
                )
                .contains {
                    leftJoinedTables.contains(normalizeBinding($0.qualifiedName))
                }
        }
    }

    private static func leftJoinedTableKeys(
        analysis: SQLReferenceAnalysis,
        sql: String,
        schema: DatabaseSchema
    ) -> Set<String> {
        var keys = Set<String>()
        for relation in analysis.relations where !relation.isDerived {
            guard let offset = relation.startOffset,
                relationHasLeftJoinPrefix(offset: offset, in: sql),
                let table = table(for: relation, in: schema)
            else { continue }
            keys.insert(normalizeBinding(table.qualifiedName))
        }
        return keys
    }

    private static func relationHasLeftJoinPrefix(offset: Int, in sql: String) -> Bool {
        let characters = Array(sql)
        guard offset >= 0, offset <= characters.count else { return false }
        let lowerBound = max(0, offset - 80)
        let prefix = String(characters[lowerBound..<offset])
        return matches(#"(?is)\bleft\s+(outer\s+)?join\s*$"#, in: prefix)
    }

    private static func columnIsNullFiltered(_ column: SQLColumnReference, in sql: String) -> Bool {
        guard let endOffset = column.endOffset else { return false }
        let characters = Array(sql)
        guard endOffset >= 0, endOffset <= characters.count else { return false }
        let lookaheadEnd = min(characters.count, endOffset + 32)
        let suffix = String(characters[endOffset..<lookaheadEnd])
        return matches(#"(?is)^\s+is\s+null\b"#, in: suffix)
    }

    private static func resolvedTables(
        for column: SQLColumnReference,
        relationAliases: [String: TableInfo],
        referencedTables: [TableInfo]
    ) -> [TableInfo] {
        if let qualifier = column.qualifier,
            let table = relationAliases[normalizeBinding(qualifier)]
        {
            return [table]
        }
        if let qualifier = column.qualifier,
            let table = tableMatchingQualifier(qualifier, in: referencedTables)
        {
            return [table]
        }
        guard column.qualifier == nil else { return [] }
        let matches = referencedTables.filter {
            columnNamed(column.name, isQuoted: column.isQuoted, existsIn: $0)
        }
        return matches.count == 1 ? matches : []
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
