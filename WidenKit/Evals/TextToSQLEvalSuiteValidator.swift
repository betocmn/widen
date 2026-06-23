import Foundation

public enum TextToSQLEvalSuiteValidationError: LocalizedError, Equatable, Sendable {
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            let preview = issues.prefix(12).joined(separator: "\n- ")
            let suffix = issues.count > 12 ? "\n- ...and \(issues.count - 12) more" : ""
            return "Text-to-SQL eval suite validation failed:\n- \(preview)\(suffix)"
        }
    }
}

public enum TextToSQLEvalSuiteValidator {
    public static func validate(
        suite: TextToSQLEvalSuite,
        suiteURL: URL
    ) throws {
        let schemaDirectory = suiteURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("schemas", isDirectory: true)
        try validate(suite: suite, schemaDirectory: schemaDirectory)
    }

    public static func validate(
        suite: TextToSQLEvalSuite,
        schemaDirectory: URL
    ) throws {
        var issues: [String] = []
        validateCaseIDs(suite.cases, issues: &issues)

        let schemas = loadSchemas(
            for: Set(suite.cases.map(\.schemaFixture)),
            schemaDirectory: schemaDirectory,
            issues: &issues
        )

        for evalCase in suite.cases {
            guard let schema = schemas[evalCase.schemaFixture] else { continue }
            validateExpectations(evalCase, schema: schema, issues: &issues)
        }

        if !issues.isEmpty {
            throw TextToSQLEvalSuiteValidationError.invalid(issues)
        }
    }

    private static func validateCaseIDs(
        _ cases: [TextToSQLEvalCase],
        issues: inout [String]
    ) {
        var seen: [String: Int] = [:]
        for evalCase in cases {
            let trimmed = evalCase.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append("Case IDs must be nonempty.")
                continue
            }
            seen[trimmed, default: 0] += 1
        }
        for (id, count) in seen where count > 1 {
            issues.append("Case ID \(id) appears \(count) times.")
        }
    }

    private static func loadSchemas(
        for fixtures: Set<String>,
        schemaDirectory: URL,
        issues: inout [String]
    ) -> [String: DatabaseSchema] {
        fixtures.reduce(into: [:]) { result, fixture in
            let trimmed = fixture.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append("schemaFixture must be nonempty.")
                return
            }

            let url = schemaDirectory.appendingPathComponent("\(fixture)-schema.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                issues.append("Schema fixture \(fixture) does not exist at \(url.path).")
                return
            }
            do {
                let data = try Data(contentsOf: url)
                result[fixture] = try JSONDecoder().decode(DatabaseSchema.self, from: data)
            } catch {
                issues.append("Schema fixture \(fixture) failed to decode: \(error.localizedDescription)")
            }
        }
    }

    private static func validateExpectations(
        _ evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        issues: inout [String]
    ) {
        let expected = evalCase.expected
        validateBindingsDoNotOverlap(evalCase, issues: &issues)

        switch expected.decision {
        case .clarify:
            validateClarificationCase(evalCase, issues: &issues)
        case .sql:
            validateSQLCase(evalCase, schema: schema, issues: &issues)
        }
    }

    private static func validateClarificationCase(
        _ evalCase: TextToSQLEvalCase,
        issues: inout [String]
    ) {
        let expected = evalCase.expected
        if expected.goldenSQL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            issues.append("\(evalCase.id) is a clarification case but has goldenSQL.")
        }
        if !expected.requiredTables.isEmpty {
            issues.append("\(evalCase.id) is a clarification case but has requiredTables.")
        }
        if !expected.requiredColumnBindings.isEmpty {
            issues.append("\(evalCase.id) is a clarification case but has requiredColumnBindings.")
        }
        if !expected.forbiddenColumnBindings.isEmpty {
            issues.append("\(evalCase.id) is a clarification case but has forbiddenColumnBindings.")
        }
        if !expected.requiredOperations.isEmpty {
            issues.append("\(evalCase.id) is a clarification case but has requiredOperations.")
        }
        if expected.clarificationMustMentionAny.isEmpty {
            issues.append("\(evalCase.id) is a clarification case but has no clarification concepts.")
        }
    }

    private static func validateSQLCase(
        _ evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        issues: inout [String]
    ) {
        let expected = evalCase.expected
        for table in expected.requiredTables where tableInfo(named: table, in: schema) == nil {
            issues.append("\(evalCase.id) requires missing table \(table).")
        }
        for binding in expected.requiredColumnBindings
            where column(namedBy: binding, in: schema) == nil
        {
            issues.append("\(evalCase.id) requires missing column binding \(binding).")
        }

        guard let goldenSQL = expected.goldenSQL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !goldenSQL.isEmpty
        else {
            issues.append("\(evalCase.id) is a SQL case but has no goldenSQL.")
            return
        }

        let safety = SQLSafetyValidator.validate(goldenSQL)
        if !safety.isValid {
            issues.append(
                "\(evalCase.id) goldenSQL is not safety-valid: \(safety.errors.joined(separator: " "))"
            )
        }

        let schemaValidation = SQLSchemaValidator.validate(sql: goldenSQL, against: schema)
        if schemaValidation.hasDefiniteErrors {
            issues.append(
                "\(evalCase.id) goldenSQL is not schema-valid: \(schemaValidation.errors.joined(separator: " "))"
            )
        }

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: schema,
            generation: SQLGenerationResult(
                sql: goldenSQL,
                explanation: "Golden SQL",
                assumptions: [],
                referencedTables: [],
                confidence: 1,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            ),
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 0
        )
        if result.status != .passed {
            let diagnostics = [
                result.diagnostics.missingTables.isEmpty
                    ? nil
                    : "missing tables: \(result.diagnostics.missingTables.joined(separator: ", "))",
                result.diagnostics.missingColumnBindings.isEmpty
                    ? nil
                    : "missing columns: \(result.diagnostics.missingColumnBindings.joined(separator: ", "))",
                result.diagnostics.missingOperations.isEmpty
                    ? nil
                    : "missing operations: \(result.diagnostics.missingOperations.map(\.rawValue).joined(separator: ", "))",
                result.metrics.forbiddenBindingViolations.isEmpty
                    ? nil
                    : "forbidden bindings: \(result.metrics.forbiddenBindingViolations.joined(separator: ", "))",
            ]
            .compactMap { $0 }
            .joined(separator: "; ")
            issues.append(
                "\(evalCase.id) goldenSQL does not score as passed: \(result.status.rawValue)\(diagnostics.isEmpty ? "" : " (\(diagnostics))")"
            )
        }
    }

    private static func validateBindingsDoNotOverlap(
        _ evalCase: TextToSQLEvalCase,
        issues: inout [String]
    ) {
        let required = Set(evalCase.expected.requiredColumnBindings.map(normalizedIdentifier))
        let forbidden = Set(evalCase.expected.forbiddenColumnBindings.map(normalizedIdentifier))
        let overlap = required.intersection(forbidden)
        if !overlap.isEmpty {
            issues.append(
                "\(evalCase.id) has overlapping required and forbidden bindings: \(overlap.sorted().joined(separator: ", "))"
            )
        }
    }

    private struct ColumnBinding {
        var tableName: String
        var columnName: String
    }

    private static func column(namedBy binding: String, in schema: DatabaseSchema) -> ColumnInfo? {
        guard let parsed = parseColumnBinding(binding),
            let table = tableInfo(named: parsed.tableName, in: schema)
        else { return nil }
        return table.columns.first { $0.name == parsed.columnName }
    }

    private static func tableInfo(named name: String, in schema: DatabaseSchema) -> TableInfo? {
        let normalized = normalizedIdentifier(name)
        return schema.tables.first { normalizedIdentifier($0.qualifiedName) == normalized }
    }

    private static func parseColumnBinding(_ binding: String) -> ColumnBinding? {
        let parts = binding.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return ColumnBinding(
            tableName: "\(parts[0]).\(parts[1])",
            columnName: parts[2].replacingOccurrences(of: "\"", with: "")
        )
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
