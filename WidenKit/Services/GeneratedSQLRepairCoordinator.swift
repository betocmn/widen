import Foundation

public typealias SQLFingerprint = SQLTextFingerprint

public struct SQLTextFingerprint: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var value: String

    public init(_ sql: String) {
        self.value = Self.normalized(sql)
    }

    public var description: String { value }

    private static func normalized(_ sql: String) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chars = Array(trimmed)
        var output = ""
        var index = 0
        var emittedSpace = false

        func append(_ text: String) {
            output.append(text)
            emittedSpace = false
        }

        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                if !output.isEmpty, !emittedSpace {
                    output.append(" ")
                    emittedSpace = true
                }
                index += 1
                continue
            }
            if char == "'" {
                let start = index
                index += 1
                while index < chars.count {
                    if chars[index] == "'" {
                        if chars[safe: index + 1] == "'" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                append(String(chars[start..<min(index, chars.count)]))
                continue
            }
            if char == "\"" {
                let start = index
                index += 1
                while index < chars.count {
                    if chars[index] == "\"" {
                        if chars[safe: index + 1] == "\"" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                append(String(chars[start..<min(index, chars.count)]))
                continue
            }
            if char == "$",
                let endIndex = dollarQuotedStringEnd(in: chars, startingAt: index)
            {
                append(String(chars[index..<endIndex]))
                index = endIndex
                continue
            }

            append(String(char).lowercased())
            index += 1
        }

        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func dollarQuotedStringEnd(in chars: [Character], startingAt start: Int) -> Int? {
        var delimiterEnd = start + 1
        while delimiterEnd < chars.count,
            chars[delimiterEnd].isLetter || chars[delimiterEnd].isNumber || chars[delimiterEnd] == "_"
        {
            delimiterEnd += 1
        }
        guard delimiterEnd < chars.count, chars[delimiterEnd] == "$" else { return nil }
        let delimiter = Array(chars[start...delimiterEnd])
        var index = delimiterEnd + 1
        while index + delimiter.count <= chars.count {
            if Array(chars[index..<(index + delimiter.count)]) == delimiter {
                return index + delimiter.count
            }
            index += 1
        }
        return chars.count
    }
}

public struct SQLStructuralFingerprint: Codable, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public var value: String

    public init(_ sql: String) {
        self.value = Self.normalized(sql)
    }

    public var description: String { value }

    private static func normalized(_ sql: String) -> String {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let stripped = SQLSafetyValidator.strip(sql).text
        let safety = SQLSafetyValidator.validate(sql)
        var relationAliases: [String: String] = [:]
        var baseRelations = Set<String>()

        for relation in analysis.relations where !relation.isDerived {
            let canonicalRelation = canonicalRelationName(relation)
            baseRelations.insert(canonicalRelation)
            relationAliases[relation.name.lowercased()] = canonicalRelation
            relationAliases[relation.displayName.lowercased()] = canonicalRelation
            if let alias = relation.alias {
                relationAliases[alias.lowercased()] = canonicalRelation
            }
        }

        let columnBindings = analysis.columns
            .filter { $0.context == .expression && $0.name != "*" }
            .map { column in
                let owner = column.qualifier
                    .map { relationAliases[$0.lowercased()] ?? $0.lowercased() }
                    ?? "*"
                return "\(owner).\(column.name.lowercased())"
            }
            .sorted()

        let derivedOutputs = analysis.cteOutputColumns
            .flatMap { cteName, columns -> [String] in
                guard let columns else { return [] }
                return columns.map { "\(cteName.name.lowercased()).\($0.name.lowercased())" }
            }
            .sorted()

        let functions = functionNames(in: stripped).sorted()
        let predicateOperators = broadPredicateOperators(in: stripped).sorted()
        let groupingColumns = groupingColumnText(in: stripped)

        return [
            "kind:\(safety.kind.rawValue)",
            "relations:\(baseRelations.sorted().joined(separator: ","))",
            "bindings:\(columnBindings.joined(separator: ","))",
            "derived:\(derivedOutputs.joined(separator: ","))",
            "functions:\(functions.joined(separator: ","))",
            "group:\(groupingColumns)",
            "predicates:\(predicateOperators.joined(separator: ","))",
        ].joined(separator: "|")
    }

    private static func canonicalRelationName(_ relation: SQLRelationReference) -> String {
        if let schema = relation.schema?.lowercased() {
            return "\(schema).\(relation.name.lowercased())"
        }
        return relation.name.lowercased()
    }

    private static func functionNames(in sql: String) -> Set<String> {
        let characters = Array(sql)
        var names = Set<String>()
        var index = 0
        while index < characters.count {
            guard isIdentifierStart(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < characters.count, isIdentifierContinuation(characters[index]) {
                index += 1
            }
            let name = String(characters[start..<index]).lowercased()
            var lookahead = index
            while lookahead < characters.count, characters[lookahead].isWhitespace {
                lookahead += 1
            }
            if characters[safe: lookahead] == "(", !nonFunctionKeywords.contains(name) {
                names.insert(name)
            }
        }
        return names
    }

    private static func broadPredicateOperators(in sql: String) -> Set<String> {
        let lowercased = sql.lowercased()
        var operators = Set<String>()
        for token in ["=", "<>", "!=", "<=", ">=", "<", ">"] where lowercased.contains(token) {
            operators.insert(token)
        }
        for word in [" like ", " ilike ", " in ", " between ", " is "]
        where lowercased.contains(word) {
            operators.insert(word.trimmingCharacters(in: .whitespaces))
        }
        return operators
    }

    private static func groupingColumnText(in sql: String) -> String {
        let lowercased = sql.lowercased()
        guard let groupRange = lowercased.range(of: "group by") else { return "" }
        let afterGroup = sql[groupRange.upperBound...]
        let terminators = [" order by", " having", " limit", " offset", " union", " intersect", " except"]
        let end = terminators
            .compactMap { afterGroup.lowercased().range(of: $0)?.lowerBound }
            .min() ?? afterGroup.endIndex
        return afterGroup[..<end]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static let nonFunctionKeywords: Set<String> = [
        "as", "case", "cast", "delete", "exists", "from", "insert", "join", "limit",
        "on", "order", "select", "update", "values", "where", "with",
    ]

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }
}

public struct RepairConstraints: Equatable, Sendable {
    public var failedSQL: String
    public var diagnostic: DatabaseDiagnostic?
    public var forbiddenIdentifiers: [String]
    public var repairConstraints: [RepairConstraint]
    public var priorFingerprints: [SQLFingerprint]
    public var lastError: String

    public init(
        failedSQL: String,
        diagnostic: DatabaseDiagnostic? = nil,
        forbiddenIdentifiers: [String] = [],
        repairConstraints: [RepairConstraint] = [],
        priorFingerprints: [SQLFingerprint] = [],
        lastError: String
    ) {
        self.failedSQL = failedSQL
        self.diagnostic = diagnostic
        self.forbiddenIdentifiers = forbiddenIdentifiers
        self.repairConstraints = Self.mergedConstraints(
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: repairConstraints
        )
        self.priorFingerprints = priorFingerprints
        self.lastError = lastError
    }

    private static func mergedConstraints(
        forbiddenIdentifiers: [String],
        repairConstraints: [RepairConstraint]
    ) -> [RepairConstraint] {
        var result = repairConstraints
        var seen = Set(result.map { "\($0.kind.rawValue):\($0.identifier.lowercased())" })
        for identifier in forbiddenIdentifiers {
            let key = "\(RepairConstraintKind.forbiddenIdentifier.rawValue):\(identifier.lowercased())"
            if seen.insert(key).inserted {
                result.append(.forbiddenIdentifier(identifier))
            }
        }
        return result
    }
}

public struct SQLRepairAttempt: Equatable, Sendable {
    public var mode: SQLGenerationMode
    public var sql: String?
    public var error: String

    public init(mode: SQLGenerationMode, sql: String? = nil, error: String) {
        self.mode = mode
        self.sql = sql
        self.error = error
    }

    public var label: String {
        switch mode {
        case .repair:
            "Focused repair"
        case .reconstructAfterFailedRepair:
            "Reconstruction"
        case .initial:
            "Initial generation"
        case .followUp:
            "Follow-up generation"
        }
    }
}

public struct SQLRepairCandidateEvaluation: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case accepted
        case clarification
        case rejected(SQLRepairCandidateRejectionReason)
    }

    public var outcome: Outcome
    public var sql: String?
    public var message: String?
    public var validation: SQLValidationResult?
    public var allowsReconstruction: Bool
}

public enum SQLRepairCandidateRejectionReason: Equatable, Sendable {
    case emptySQL
    case repeatedFingerprint
    case forbiddenIdentifier(String)
    case validationFailure
    case unsafeWrite

    public var isZeroProgressRepair: Bool {
        switch self {
        case .repeatedFingerprint, .forbiddenIdentifier:
            true
        case .emptySQL, .validationFailure, .unsafeWrite:
            false
        }
    }
}

public struct GeneratedSQLRepairCoordinator: Sendable {
    public static let maxModelCalls = 2

    public private(set) var constraints: RepairConstraints
    public private(set) var attempts: [SQLRepairAttempt]
    private let maxModelCalls: Int
    private var modelCallCount = 0
    private var failedCandidateSignatures: [SQLFailedCandidateSignature]

    public init(
        failedSQL: String,
        firstError: String,
        diagnostic: DatabaseDiagnostic?,
        forbiddenIdentifiers: [String],
        repairConstraints: [RepairConstraint] = [],
        maxModelCalls: Int = Self.maxModelCalls
    ) {
        let fingerprint = SQLFingerprint(failedSQL)
        let failureSignature = SQLFailedCandidateSignature(
            sql: failedSQL,
            issueSignatures: SQLRepairIssueSignature.signatures(
                error: firstError,
                diagnostic: diagnostic
            )
        )
        self.constraints = RepairConstraints(
            failedSQL: failedSQL,
            diagnostic: diagnostic,
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: repairConstraints,
            priorFingerprints: [fingerprint],
            lastError: firstError
        )
        self.attempts = [SQLRepairAttempt(mode: .initial, sql: failedSQL, error: firstError)]
        self.maxModelCalls = max(1, maxModelCalls)
        self.failedCandidateSignatures = [failureSignature]
    }

    public var canRequestAnotherModelCall: Bool {
        modelCallCount < maxModelCalls
    }

    public mutating func beginNextAttempt() -> SQLGenerationMode? {
        guard canRequestAnotherModelCall else { return nil }
        defer { modelCallCount += 1 }
        return modelCallCount == 0 ? .repair : .reconstructAfterFailedRepair
    }

    public func repairContext(for mode: SQLGenerationMode) -> SQLRepairContext {
        SQLRepairContext(
            failedSQL: mode == .repair ? constraints.failedSQL : nil,
            diagnostic: constraints.diagnostic,
            forbiddenIdentifiers: constraints.forbiddenIdentifiers,
            repairConstraints: constraints.repairConstraints,
            priorFingerprints: []
        )
    }

    public mutating func evaluateCandidate(
        _ generation: SQLGenerationResult,
        mode: SQLGenerationMode,
        schema: DatabaseSchema,
        allowWrites: Bool
    ) -> SQLRepairCandidateEvaluation {
        if generation.needsClarification {
            let question = generation.clarificationQuestion?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard question?.isEmpty == false else {
                return reject(
                    mode: mode,
                    sql: nil,
                    reason: .emptySQL,
                    message: "The model asked for clarification but did not return a question.",
                    allowsReconstruction: mode == .repair
                )
            }
            return SQLRepairCandidateEvaluation(
                outcome: .clarification,
                sql: nil,
                message: question,
                validation: nil,
                allowsReconstruction: false
            )
        }

        let sql = GeneratedSQLValidator.canonicalize(sql: generation.sql, schema: schema)
        guard !sql.isEmpty else {
            return reject(
                mode: mode,
                sql: nil,
                reason: .emptySQL,
                message: "The model did not return corrected SQL.",
                allowsReconstruction: mode == .repair
            )
        }

        let fingerprint = SQLFingerprint(sql)
        if constraints.priorFingerprints.contains(fingerprint) {
            return reject(
                mode: mode,
                sql: sql,
                reason: .repeatedFingerprint,
                message:
                    "The model repeated SQL that already failed. It must produce a different query or ask a clarification question.",
                allowsReconstruction: false
            )
        }

        if let forbiddenIdentifier = forbiddenIdentifier(in: sql) {
            return reject(
                mode: mode,
                sql: sql,
                reason: .forbiddenIdentifier(forbiddenIdentifier),
                message:
                    "The model reused forbidden identifier \(forbiddenIdentifier) after it was diagnosed as invalid.",
                allowsReconstruction: false
            )
        }

        let safety = SQLSafetyValidator.validate(sql)
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        let validation = GeneratedSQLValidator.combine(
            safety: safety,
            schemaValidation: schemaValidation
        )
        guard validation.isValid else {
            let message = AppError.validationFailed(validation.errors).localizedDescription
            let issueSignatures = SQLRepairIssueSignature.signatures(
                safety: safety,
                schemaValidation: schemaValidation
            )
            if structurallyRepeatsFailedCandidate(sql: sql, issueSignatures: issueSignatures) {
                return reject(
                    mode: mode,
                    sql: sql,
                    reason: .repeatedFingerprint,
                    message:
                        "The model produced SQL with the same structure and validation issue that already failed.",
                    allowsReconstruction: false,
                    issueSignatures: issueSignatures
                )
            }
            return reject(
                mode: mode,
                sql: sql,
                reason: .validationFailure,
                message: message,
                allowsReconstruction: mode == .repair && safety.kind == .read
                    && madeValidationProgress(issueSignatures),
                issueSignatures: issueSignatures
            )
        }

        if validation.kind.isWrite && !allowWrites {
            return reject(
                mode: mode,
                sql: sql,
                reason: .unsafeWrite,
                message:
                    "The model produced a data-modifying query while repairing a read, so I stopped before showing it.",
                allowsReconstruction: false
            )
        }

        constraints.priorFingerprints.append(fingerprint)
        return SQLRepairCandidateEvaluation(
            outcome: .accepted,
            sql: sql,
            message: nil,
            validation: validation,
            allowsReconstruction: false
        )
    }

    public mutating func recordExecutionFailure(
        mode: SQLGenerationMode,
        sql: String,
        error: String,
        diagnostic: DatabaseDiagnostic?,
        forbiddenIdentifiers: [String],
        repairConstraints: [RepairConstraint] = []
    ) {
        attempts.append(SQLRepairAttempt(mode: mode, sql: sql, error: error))
        constraints.failedSQL = sql
        constraints.lastError = error
        if let diagnostic {
            constraints.diagnostic = diagnostic
        }
        appendForbiddenIdentifiers(forbiddenIdentifiers)
        appendRepairConstraints(repairConstraints)
    }

    private mutating func reject(
        mode: SQLGenerationMode,
        sql: String?,
        reason: SQLRepairCandidateRejectionReason,
        message: String,
        allowsReconstruction: Bool,
        issueSignatures: Set<SQLRepairIssueSignature> = []
    ) -> SQLRepairCandidateEvaluation {
        if let sql {
            let fingerprint = SQLFingerprint(sql)
            if !constraints.priorFingerprints.contains(fingerprint) {
                constraints.priorFingerprints.append(fingerprint)
            }
            if !issueSignatures.isEmpty {
                failedCandidateSignatures.append(
                    SQLFailedCandidateSignature(sql: sql, issueSignatures: issueSignatures)
                )
            }
        }
        attempts.append(SQLRepairAttempt(mode: mode, sql: sql, error: message))
        constraints.lastError = message
        return SQLRepairCandidateEvaluation(
            outcome: .rejected(reason),
            sql: sql,
            message: message,
            validation: nil,
            allowsReconstruction: allowsReconstruction
        )
    }

    private mutating func appendForbiddenIdentifiers(_ identifiers: [String]) {
        var existing = Set(constraints.forbiddenIdentifiers.map(Self.canonicalIdentifier))
        var existingConstraints = Set(
            constraints.repairConstraints.map { "\($0.kind.rawValue):\(Self.canonicalIdentifier($0.identifier))" }
        )
        for identifier in identifiers where existing.insert(Self.canonicalIdentifier(identifier)).inserted {
            constraints.forbiddenIdentifiers.append(identifier)
            let constraint = RepairConstraint.forbiddenIdentifier(identifier)
            let key = "\(constraint.kind.rawValue):\(Self.canonicalIdentifier(identifier))"
            if existingConstraints.insert(key).inserted {
                constraints.repairConstraints.append(constraint)
            }
        }
    }

    private mutating func appendRepairConstraints(_ repairConstraints: [RepairConstraint]) {
        var existing = Set(
            constraints.repairConstraints.map { "\($0.kind.rawValue):\(Self.canonicalIdentifier($0.identifier))" }
        )
        for constraint in repairConstraints {
            let key = "\(constraint.kind.rawValue):\(Self.canonicalIdentifier(constraint.identifier))"
            if existing.insert(key).inserted {
                constraints.repairConstraints.append(constraint)
            }
        }
    }

    private func forbiddenIdentifier(in sql: String) -> String? {
        let hardForbidden = constraints.repairConstraints
            .filter { $0.kind == .forbiddenIdentifier }
            .map { (original: $0.identifier, canonical: Self.canonicalIdentifier($0.identifier)) }
            .filter { !$0.canonical.isEmpty }
        let unquotedForbidden = constraints.repairConstraints
            .filter { $0.kind == .forbiddenUnquotedIdentifier }
            .map { (original: $0.identifier, canonical: Self.canonicalIdentifier($0.identifier)) }
            .filter { !$0.canonical.isEmpty }
        guard !hardForbidden.isEmpty || !unquotedForbidden.isEmpty else { return nil }

        let analysis = SQLReferenceAnalyzer.analyze(sql)
        var referenced = Set<String>()
        for relation in analysis.relations {
            referenced.insert(Self.canonicalIdentifier(relation.name))
            referenced.insert(Self.canonicalIdentifier(relation.displayName))
        }
        for column in analysis.columns {
            if let qualifier = column.qualifier {
                referenced.insert(Self.canonicalIdentifier("\(qualifier).\(column.name)"))
            } else {
                referenced.insert(Self.canonicalIdentifier(column.name))
            }
        }

        for entry in hardForbidden where referenced.contains(entry.canonical) {
            return entry.original
        }
        for entry in unquotedForbidden {
            if analysis.columns.contains(where: {
                !$0.isQuoted && Self.canonicalIdentifier($0.name) == entry.canonical
            }) {
                return entry.original
            }
        }
        return nil
    }

    private func structurallyRepeatsFailedCandidate(
        sql: String,
        issueSignatures: Set<SQLRepairIssueSignature>
    ) -> Bool {
        guard !issueSignatures.isEmpty else { return false }
        let structural = SQLStructuralFingerprint(sql)
        return failedCandidateSignatures.contains {
            $0.structuralFingerprint == structural
                && !$0.issueSignatures.isDisjoint(with: issueSignatures)
        }
    }

    private func madeValidationProgress(_ issueSignatures: Set<SQLRepairIssueSignature>) -> Bool {
        guard !issueSignatures.isEmpty else { return false }
        return !failedCandidateSignatures.contains {
            !$0.issueSignatures.isDisjoint(with: issueSignatures)
        }
    }

    private static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

private struct SQLFailedCandidateSignature: Equatable, Sendable {
    var structuralFingerprint: SQLStructuralFingerprint
    var issueSignatures: Set<SQLRepairIssueSignature>

    init(sql: String, issueSignatures: Set<SQLRepairIssueSignature>) {
        self.structuralFingerprint = SQLStructuralFingerprint(sql)
        self.issueSignatures = issueSignatures
    }
}

private struct SQLRepairIssueSignature: Hashable, Sendable {
    var value: String

    static func signatures(
        safety: SQLValidationResult,
        schemaValidation: SQLSchemaValidationResult
    ) -> Set<SQLRepairIssueSignature> {
        var signatures = Set<SQLRepairIssueSignature>()
        for issue in schemaValidation.issues where issue.severity == .error {
            let identifier = issue.identifier.map(canonicalIdentifier) ?? ""
            let suggested = issue.suggestedIdentifier.map(canonicalIdentifier) ?? ""
            let kind = normalizedKind(issue.kind)
            let value =
                kind == "requiresQuotedIdentifier"
                ? "\(kind):\(identifier):\(suggested)"
                : "\(kind):\(identifier)"
            signatures.insert(
                SQLRepairIssueSignature(value: value)
            )
        }
        for error in safety.errors {
            signatures.insert(SQLRepairIssueSignature(value: "safety:\(canonicalIdentifier(error))"))
        }
        return signatures
    }

    private static func normalizedKind(_ kind: SQLSchemaValidationIssue.Kind) -> String {
        switch kind {
        case .missingColumn, .missingBaseColumn, .missingDerivedColumn, .columnNotProjectedByCTE:
            "missingColumn"
        default:
            String(describing: kind)
        }
    }

    static func signatures(
        error: String,
        diagnostic: DatabaseDiagnostic?
    ) -> Set<SQLRepairIssueSignature> {
        var signatures = Set<SQLRepairIssueSignature>()
        if let diagnostic {
            let identifier = diagnostic.identifierForRepair.map(canonicalIdentifier) ?? ""
            signatures.insert(SQLRepairIssueSignature(value: "\(diagnostic.kind.rawValue):\(identifier)"))
        }
        for match in capturedValues(
            in: error,
            pattern: #"Schema validation failed: table ([^\s]+) is not in the selected schema"#
        ) {
            signatures.insert(SQLRepairIssueSignature(value: "missingRelation:\(canonicalIdentifier(match))"))
        }
        for match in capturedValues(
            in: error,
            pattern: #"(?i)\brelation\s+"([^"]+)"\s+does\s+not\s+exist"#
        ) {
            signatures.insert(SQLRepairIssueSignature(value: "missingRelation:\(canonicalIdentifier(match))"))
        }
        for match in capturedValues(
            in: error,
            pattern:
                #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced(?: base)? tables|not on [^.\s]+(?:\.[^.\s]+)?|not an output column of [^.;]+|ambiguous across referenced tables)"#
        ) {
            signatures.insert(SQLRepairIssueSignature(value: "missingColumn:\(canonicalIdentifier(match))"))
        }
        for match in capturedValues(
            in: error,
            pattern: #"(?i)column "([^"]+)" does not exist"#
        ) {
            signatures.insert(SQLRepairIssueSignature(value: "missingColumn:\(canonicalIdentifier(match))"))
        }
        if signatures.isEmpty {
            signatures.insert(SQLRepairIssueSignature(value: "error:\(canonicalIdentifier(error))"))
        }
        return signatures
    }

    private static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
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
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
