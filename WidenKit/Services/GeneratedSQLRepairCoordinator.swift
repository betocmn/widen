import Foundation

public struct SQLFingerprint: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
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
        let collapsed = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.lowercased()
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
}

public struct GeneratedSQLRepairCoordinator: Sendable {
    public static let maxModelCalls = 2

    public private(set) var constraints: RepairConstraints
    public private(set) var attempts: [SQLRepairAttempt]
    private var modelCallCount = 0

    public init(
        failedSQL: String,
        firstError: String,
        diagnostic: DatabaseDiagnostic?,
        forbiddenIdentifiers: [String],
        repairConstraints: [RepairConstraint] = []
    ) {
        let fingerprint = SQLFingerprint(failedSQL)
        self.constraints = RepairConstraints(
            failedSQL: failedSQL,
            diagnostic: diagnostic,
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: repairConstraints,
            priorFingerprints: [fingerprint],
            lastError: firstError
        )
        self.attempts = [SQLRepairAttempt(mode: .initial, sql: failedSQL, error: firstError)]
    }

    public var canRequestAnotherModelCall: Bool {
        modelCallCount < Self.maxModelCalls
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
            priorFingerprints: constraints.priorFingerprints.map(\.value)
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

        let sql = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
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
                allowsReconstruction: mode == .repair
            )
        }

        if let forbiddenIdentifier = forbiddenIdentifier(in: sql) {
            return reject(
                mode: mode,
                sql: sql,
                reason: .forbiddenIdentifier(forbiddenIdentifier),
                message:
                    "The model reused forbidden identifier \(forbiddenIdentifier) after it was diagnosed as invalid.",
                allowsReconstruction: mode == .repair
            )
        }

        let validation = GeneratedSQLValidator.validate(sql: sql, schema: schema)
        guard validation.isValid else {
            let message = AppError.validationFailed(validation.errors).localizedDescription
            let safety = SQLSafetyValidator.validate(sql)
            return reject(
                mode: mode,
                sql: sql,
                reason: .validationFailure,
                message: message,
                allowsReconstruction: mode == .repair && safety.kind == .read
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
        allowsReconstruction: Bool
    ) -> SQLRepairCandidateEvaluation {
        if let sql {
            let fingerprint = SQLFingerprint(sql)
            if !constraints.priorFingerprints.contains(fingerprint) {
                constraints.priorFingerprints.append(fingerprint)
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
            referenced.insert(Self.canonicalIdentifier(column.name))
            if let qualifier = column.qualifier {
                referenced.insert(Self.canonicalIdentifier("\(qualifier).\(column.name)"))
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

    private static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
