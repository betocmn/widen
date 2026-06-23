import Foundation

enum GeneratedSQLRepairFailureMode: Sendable {
    case validationOnly
    case execution
}

enum GeneratedSQLRepairSupport {
    static let localModelCallBudget = 3

    static func remainingRepairCalls(after generation: SQLGenerationResult?) -> Int {
        let spentModelCalls = max(1, generation?.generationCallCount ?? 1)
        return max(0, localModelCallBudget - spentModelCalls)
    }

    static func cumulativeModelCallCount(
        after generation: SQLGenerationResult?,
        attempt: Int
    ) -> Int {
        let spentModelCalls = max(1, generation?.generationCallCount ?? 1)
        return spentModelCalls + max(0, attempt)
    }

    static func diagnostic(from error: String) -> DatabaseDiagnostic? {
        let lowercased = error.lowercased()
        if let tableName = firstCapturedValue(
            in: error,
            pattern: #"Schema validation failed: table ([^\s]+) is not in the selected schema"#
        ) {
            return DatabaseDiagnostic(
                kind: .missingRelation,
                sqlState: "42P01",
                message: error,
                tableName: tableName
            )
        }
        if let columnName = firstCapturedValue(
            in: error,
            pattern:
                #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced(?: base)? tables|not on [^.\s]+(?:\.[^.\s]+)?|not an output column of [^.;]+)"#
        ) {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: columnName
            )
        }
        if let columnName = firstCapturedValue(
            in: error,
            pattern:
                #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) must be quoted as "[^"]+""#
        ) {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: columnName
            )
        }
        if lowercased.contains("relation"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(
                kind: .missingRelation,
                sqlState: "42P01",
                message: error,
                tableName: missingRelationIdentifier(in: error)
                    ?? quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("column"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: error,
                columnName: quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("ambiguous") && lowercased.contains("column") {
            return DatabaseDiagnostic(
                kind: .ambiguousColumn,
                sqlState: "42702",
                message: error,
                columnName: quotedIdentifiers(in: error).first
            )
        }
        if lowercased.contains("syntax error") {
            return DatabaseDiagnostic(kind: .syntaxError, sqlState: "42601", message: error)
        }
        if lowercased.contains("aggregate") || lowercased.contains("group by") {
            return DatabaseDiagnostic(kind: .groupingError, sqlState: "42803", message: error)
        }
        if lowercased.contains("type") && lowercased.contains("mismatch") {
            return DatabaseDiagnostic(kind: .datatypeMismatch, sqlState: "42804", message: error)
        }
        if lowercased.contains("function"), lowercased.contains("does not exist") {
            return DatabaseDiagnostic(kind: .undefinedFunction, sqlState: "42883", message: error)
        }
        if lowercased.contains("permission denied") || lowercased.contains("insufficient privilege") {
            return DatabaseDiagnostic(
                kind: .insufficientPrivilege,
                sqlState: "42501",
                message: error
            )
        }
        if lowercased.contains("timed out") || lowercased.contains("statement timeout") {
            return DatabaseDiagnostic(kind: .timedOut, sqlState: "57014", message: error)
        }
        return nil
    }

    static func forbiddenIdentifiers(
        sql: String,
        error: String,
        diagnostic suppliedDiagnostic: DatabaseDiagnostic? = nil,
        schema: DatabaseSchema? = nil
    ) -> [String] {
        let unquotedOnly = Set(
            unquotedIdentifierRepairConstraints(in: error)
                .map { canonicalIdentifier($0.identifier) }
        )
        var identifiers = schemaValidationIdentifiers(in: error)
        let parsedDiagnostic = diagnostic(from: error)
        if let diagnostic = suppliedDiagnostic ?? parsedDiagnostic {
            if let identifier = repairIdentifier(
                for: diagnostic,
                parsedFromError: parsedDiagnostic,
                fallbackError: error
            ) {
                if !unquotedOnly.contains(canonicalIdentifier(identifier)) {
                    identifiers.append(identifier)
                }
            }
        }
        var seen = Set<String>()
        return identifiers
            .filter { shouldForbidIdentifier($0, sql: sql, schema: schema) }
            .filter { seen.insert($0).inserted }
    }

    static func repairConstraints(
        forbiddenIdentifiers: [String],
        error: String
    ) -> [RepairConstraint] {
        var constraints = forbiddenIdentifiers.map(RepairConstraint.forbiddenIdentifier)
        constraints.append(contentsOf: unquotedIdentifierRepairConstraints(in: error))
        var seen = Set<String>()
        return constraints.filter {
            seen.insert("\($0.kind.rawValue):\(canonicalIdentifier($0.identifier))").inserted
        }
    }

    static func missingColumnsCanBeResolvedByJoining(
        sql: String,
        error: String,
        schema: DatabaseSchema
    ) -> Bool {
        let missingColumns = schemaValidationIdentifiers(in: error)
            .filter { !$0.contains(".") }
        guard !missingColumns.isEmpty else { return false }
        return missingColumns.allSatisfy {
            missingColumnCanBeResolvedByJoining($0, sql: sql, schema: schema)
        }
    }

    static func isRetryableGeneratedSQLFailure(_ failure: QueryFailure?) -> Bool {
        guard let failure else { return false }
        if let diagnostic = failure.diagnostic ?? diagnostic(from: failure.message) {
            switch diagnostic.kind {
            case .insufficientPrivilege, .timedOut, .cancelled:
                return false
            default:
                break
            }
            if diagnostic.sqlState == "42501" || diagnostic.sqlState == "57014" {
                return false
            }
            return true
        }
        return isRetryableGeneratedSQLError(failure.message)
    }

    static func repairRejectionMessage(
        _ reason: SQLRepairCandidateRejectionReason
    ) -> String {
        switch reason {
        case .emptySQL:
            "The model did not return corrected SQL."
        case .repeatedFingerprint:
            "The model repeated SQL that already failed."
        case .forbiddenIdentifier(let identifier):
            "The model reused forbidden identifier \(identifier)."
        case .validationFailure:
            "The SQL still failed validation."
        case .unsafeWrite:
            "The model produced a data-modifying query while repairing a read."
        }
    }

    static func repairFailureMessage(
        attempts: [SQLRepairAttempt],
        mode: GeneratedSQLRepairFailureMode
    ) -> String {
        let lastError = attempts.last?.error ?? "Unknown database error."
        let history = attempts
            .map { attempt in
                "- \(attempt.label): \(truncated(attempt.error, to: 220))"
            }
            .joined(separator: "\n")
        let failureReason =
            mode == .validationOnly
            ? "it still failed validation"
            : "the database still rejected it"
        let validationRecoveryGuidance =
            "The rejected SQL and repair attempts are shown above in the chat. "
            + "Add more context so the model can adjust it, or switch to a smarter cloud model and try again."
        let executionRecoveryGuidance =
            "The failed SQL and repair attempts are shown above in the chat. "
            + "The editor was restored to the last valid or original generation. "
            + "Add more context so the model can adjust it, or switch to a smarter cloud model and try again."
        let recoveryGuidance =
            mode == .validationOnly
            ? validationRecoveryGuidance
            : executionRecoveryGuidance
        if attempts.count <= 1 {
            return """
                The generated SQL already used this request's model-call budget, so I did not ask the model to repair it.

                Last error: \(lastError)

                Errors seen:
                \(history)

                \(recoveryGuidance)
                """
        }
        return """
            I tried a focused repair and, when needed, one reconstruction, but \(failureReason).

            Last error: \(lastError)

            Errors seen:
            \(history)

            \(recoveryGuidance)
            """
    }

    private static func repairIdentifier(
        for diagnostic: DatabaseDiagnostic,
        parsedFromError: DatabaseDiagnostic?,
        fallbackError: String
    ) -> String? {
        if let identifier = diagnostic.identifierForRepair {
            return identifier
        }
        guard diagnostic.kind == .missingRelation else { return nil }
        return parsedFromError?.identifierForRepair
            ?? missingRelationIdentifier(in: diagnostic.displayMessage)
            ?? missingRelationIdentifier(in: fallbackError)
    }

    private static func unquotedIdentifierRepairConstraints(in text: String) -> [RepairConstraint] {
        capturedValues(
            in: text,
            pattern:
                #"Schema validation failed: column [A-Za-z_][A-Za-z0-9_$]* must be quoted as "([^"]+)""#
        )
        .map(RepairConstraint.forbiddenUnquotedIdentifier)
    }

    private static func schemaValidationIdentifiers(in text: String) -> [String] {
        var identifiers: [String] = []
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern: #"(?i)column "([^"]+)" does not exist"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern:
                    #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced(?: base)? tables|not on [^.\s]+(?:\.[^.\s]+)?|not an output column of [^.;]+|ambiguous across referenced tables)"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern: #"Schema validation failed: table ([^\s]+) is not in the selected schema"#
            ))
        identifiers.append(
            contentsOf: capturedValues(
                in: text,
                pattern:
                    #"Schema validation failed: qualifier ([A-Za-z_][A-Za-z0-9_$]*) does not resolve to a selected-schema table"#
            ))
        return identifiers
    }

    private static func shouldForbidIdentifier(
        _ identifier: String,
        sql: String,
        schema: DatabaseSchema?
    ) -> Bool {
        guard let schema else { return true }
        let canonical = canonicalIdentifier(identifier)
        if SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: sql)
            .contains(where: { canonicalIdentifier($0) == canonical })
        {
            return true
        }
        guard !identifier.contains(".") else { return true }
        return !missingColumnCanBeResolvedByJoining(identifier, sql: sql, schema: schema)
    }

    private static func missingColumnCanBeResolvedByJoining(
        _ columnName: String,
        sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let referencedTables = resolvedTables(
            from: SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: sql),
            schema: schema
        )
        guard !referencedTables.isEmpty else { return false }
        let reachableTableIDs = reachableTableIDs(from: Set(referencedTables.map(\.id)), schema: schema)
        let foldedColumn = columnName.lowercased()
        return schema.tables.contains { table in
            reachableTableIDs.contains(table.id)
                && table.columns.contains { $0.name.lowercased() == foldedColumn }
        }
    }

    private static func resolvedTables(
        from identifiers: [String],
        schema: DatabaseSchema
    ) -> [TableInfo] {
        identifiers.compactMap { identifier in
            let canonical = canonicalIdentifier(identifier)
            if let table = schema.tables.first(where: {
                canonicalIdentifier($0.qualifiedName) == canonical
            }) {
                return table
            }
            let matches = schema.tables.filter {
                canonicalIdentifier($0.name) == canonical
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private static func reachableTableIDs(
        from tableIDs: Set<String>,
        schema: DatabaseSchema,
        maxHops: Int = 2
    ) -> Set<String> {
        var reachable = tableIDs
        var frontier = tableIDs
        guard maxHops > 0 else { return reachable }
        for _ in 0..<maxHops {
            var next = Set<String>()
            for foreignKey in schema.foreignKeys {
                let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
                let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
                if frontier.contains(sourceID), reachable.insert(targetID).inserted {
                    next.insert(targetID)
                }
                if frontier.contains(targetID), reachable.insert(sourceID).inserted {
                    next.insert(sourceID)
                }
            }
            guard !next.isEmpty else { break }
            frontier = next
        }
        return reachable
    }

    private static func quotedIdentifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func missingRelationIdentifier(in text: String) -> String? {
        firstCapturedValue(
            in: text,
            pattern: #"(?i)\brelation\s+"([^"]+)"\s+does\s+not\s+exist"#
        )
    }

    private static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static func firstCapturedValue(in text: String, pattern: String) -> String? {
        capturedValues(in: text, pattern: pattern).first
    }

    private static func capturedValues(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    private static func isRetryableGeneratedSQLError(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        let nonRepairableFragments = [
            "not connected",
            "could not connect",
            "connection failed",
            "connection refused",
            "connection reset",
            "authentication failed",
            "database not found",
            "permission denied",
            "insufficient privilege",
            "42501",
            "timed out",
            "statement timeout",
            "stopped waiting",
            "canceling statement",
            "cancelled",
            "canceled",
        ]
        guard !nonRepairableFragments.contains(where: { lowercased.contains($0) }) else {
            return false
        }
        return true
    }
}
