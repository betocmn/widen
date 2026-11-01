import Foundation

public enum SchemaToolAppRejectionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case uninspectedObject
    case invalidSQL
    case intentCoverageRejected
    case planConsistencyRejected
    case unsupportedAction
    case malformedTerminal
    case budgetExhausted
    case timedOut
    case clarificationRejected
}

public struct SchemaToolEvidenceSummary: Codable, Equatable, Sendable {
    public var searched: Bool
    public var describedTableIDs: [String]
    public var exposedColumnIDs: [String]
    public var exposedForeignKeyPathIDs: [String]
    public var inspectedConstraintToolUsed: Bool
    public var inspectedValueToolUsed: Bool

    public init(
        searched: Bool = false,
        describedTableIDs: [String] = [],
        exposedColumnIDs: [String] = [],
        exposedForeignKeyPathIDs: [String] = [],
        inspectedConstraintToolUsed: Bool = false,
        inspectedValueToolUsed: Bool = false
    ) {
        self.searched = searched
        self.describedTableIDs = describedTableIDs
        self.exposedColumnIDs = exposedColumnIDs
        self.exposedForeignKeyPathIDs = exposedForeignKeyPathIDs
        self.inspectedConstraintToolUsed = inspectedConstraintToolUsed
        self.inspectedValueToolUsed = inspectedValueToolUsed
    }
}

public struct SchemaToolAgentDiagnostics: Codable, Equatable, Sendable {
    public var logicalTurnCount: Int?
    public var terminalToolSeen: Bool
    public var terminalAction: String?
    public var terminalQueryPlan: String
    public var terminalValidationFailureReason: String?
    public var triedSchemaToolsAfterTerminal: Bool
    public var producedProseInsteadOfTools: Bool
    public var redundantDuplicateToolCallCount: Int
    public var redundantZeroResultSearchCount: Int
    public var redundantJoinPathCallCount: Int
    public var schemaEvidence: SchemaToolEvidenceSummary
    public var appSideRejectionReason: SchemaToolAppRejectionReason?
    public var clarificationCorrectionMode: String
    public var intentCoverageMode: String
    public var clarificationPolicyDecision: String
    public var clarificationPolicyReason: String
    public var overClarificationCorrectionAttempted: Bool
    public var overClarificationCorrectionSucceeded: Bool
    public var databaseContextFactsUsed: [String]
    public var evidenceSufficientForSQL: Bool
    public var unresolvedDecisionKinds: [String]
    public var sqlIntentCoverageDecision: String
    public var sqlIntentCoverageReason: String
    public var sqlIntentCoverageMissingSignals: [String]
    public var sqlIntentCoverageMismatchCategory: String
    public var intentCoverageCorrectionAttempted: Bool
    public var intentCoverageCorrectionSucceeded: Bool
    public var planConsistencyMode: String
    public var planConsistencyDecision: String
    public var planConsistencyReason: String
    public var planConsistencyDivergences: [String]
    public var planConsistencyCorrectionAttempted: Bool
    public var planConsistencyCorrectionSucceeded: Bool

    public init(
        logicalTurnCount: Int? = nil,
        terminalToolSeen: Bool = false,
        terminalAction: String? = nil,
        terminalQueryPlan: String = "",
        terminalValidationFailureReason: String? = nil,
        triedSchemaToolsAfterTerminal: Bool = false,
        producedProseInsteadOfTools: Bool = false,
        redundantDuplicateToolCallCount: Int = 0,
        redundantZeroResultSearchCount: Int = 0,
        redundantJoinPathCallCount: Int = 0,
        schemaEvidence: SchemaToolEvidenceSummary = SchemaToolEvidenceSummary(),
        appSideRejectionReason: SchemaToolAppRejectionReason? = nil,
        clarificationCorrectionMode: String = "",
        intentCoverageMode: String = "",
        clarificationPolicyDecision: String = "",
        clarificationPolicyReason: String = "",
        overClarificationCorrectionAttempted: Bool = false,
        overClarificationCorrectionSucceeded: Bool = false,
        databaseContextFactsUsed: [String] = [],
        evidenceSufficientForSQL: Bool = false,
        unresolvedDecisionKinds: [String] = [],
        sqlIntentCoverageDecision: String = "",
        sqlIntentCoverageReason: String = "",
        sqlIntentCoverageMissingSignals: [String] = [],
        sqlIntentCoverageMismatchCategory: String = "",
        intentCoverageCorrectionAttempted: Bool = false,
        intentCoverageCorrectionSucceeded: Bool = false,
        planConsistencyMode: String = "",
        planConsistencyDecision: String = "",
        planConsistencyReason: String = "",
        planConsistencyDivergences: [String] = [],
        planConsistencyCorrectionAttempted: Bool = false,
        planConsistencyCorrectionSucceeded: Bool = false
    ) {
        self.logicalTurnCount = logicalTurnCount
        self.terminalToolSeen = terminalToolSeen
        self.terminalAction = terminalAction
        self.terminalQueryPlan = terminalQueryPlan
        self.terminalValidationFailureReason = terminalValidationFailureReason
        self.triedSchemaToolsAfterTerminal = triedSchemaToolsAfterTerminal
        self.producedProseInsteadOfTools = producedProseInsteadOfTools
        self.redundantDuplicateToolCallCount = redundantDuplicateToolCallCount
        self.redundantZeroResultSearchCount = redundantZeroResultSearchCount
        self.redundantJoinPathCallCount = redundantJoinPathCallCount
        self.schemaEvidence = schemaEvidence
        self.appSideRejectionReason = appSideRejectionReason
        self.clarificationCorrectionMode = clarificationCorrectionMode
        self.intentCoverageMode = intentCoverageMode
        self.clarificationPolicyDecision = clarificationPolicyDecision
        self.clarificationPolicyReason = clarificationPolicyReason
        self.overClarificationCorrectionAttempted = overClarificationCorrectionAttempted
        self.overClarificationCorrectionSucceeded = overClarificationCorrectionSucceeded
        self.databaseContextFactsUsed = databaseContextFactsUsed
        self.evidenceSufficientForSQL = evidenceSufficientForSQL
        self.unresolvedDecisionKinds = unresolvedDecisionKinds
        self.sqlIntentCoverageDecision = sqlIntentCoverageDecision
        self.sqlIntentCoverageReason = sqlIntentCoverageReason
        self.sqlIntentCoverageMissingSignals = sqlIntentCoverageMissingSignals
        self.sqlIntentCoverageMismatchCategory = sqlIntentCoverageMismatchCategory
        self.intentCoverageCorrectionAttempted = intentCoverageCorrectionAttempted
        self.intentCoverageCorrectionSucceeded = intentCoverageCorrectionSucceeded
        self.planConsistencyMode = planConsistencyMode
        self.planConsistencyDecision = planConsistencyDecision
        self.planConsistencyReason = planConsistencyReason
        self.planConsistencyDivergences = planConsistencyDivergences
        self.planConsistencyCorrectionAttempted = planConsistencyCorrectionAttempted
        self.planConsistencyCorrectionSucceeded = planConsistencyCorrectionSucceeded
    }

    private enum CodingKeys: String, CodingKey {
        case logicalTurnCount
        case terminalToolSeen
        case terminalAction
        case terminalQueryPlan
        case terminalValidationFailureReason
        case triedSchemaToolsAfterTerminal
        case producedProseInsteadOfTools
        case redundantDuplicateToolCallCount
        case redundantZeroResultSearchCount
        case redundantJoinPathCallCount
        case schemaEvidence
        case appSideRejectionReason
        case clarificationCorrectionMode
        case intentCoverageMode
        case clarificationPolicyDecision
        case clarificationPolicyReason
        case overClarificationCorrectionAttempted
        case overClarificationCorrectionSucceeded
        case databaseContextFactsUsed
        case evidenceSufficientForSQL
        case unresolvedDecisionKinds
        case sqlIntentCoverageDecision
        case sqlIntentCoverageReason
        case sqlIntentCoverageMissingSignals
        case sqlIntentCoverageMismatchCategory
        case intentCoverageCorrectionAttempted
        case intentCoverageCorrectionSucceeded
        case planConsistencyMode
        case planConsistencyDecision
        case planConsistencyReason
        case planConsistencyDivergences
        case planConsistencyCorrectionAttempted
        case planConsistencyCorrectionSucceeded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logicalTurnCount = try container.decodeIfPresent(Int.self, forKey: .logicalTurnCount)
        terminalToolSeen = try container.decodeIfPresent(Bool.self, forKey: .terminalToolSeen) ?? false
        terminalAction = try container.decodeIfPresent(String.self, forKey: .terminalAction)
        terminalQueryPlan = try container.decodeIfPresent(String.self, forKey: .terminalQueryPlan) ?? ""
        terminalValidationFailureReason = try container.decodeIfPresent(
            String.self,
            forKey: .terminalValidationFailureReason
        )
        triedSchemaToolsAfterTerminal = try container.decodeIfPresent(
            Bool.self,
            forKey: .triedSchemaToolsAfterTerminal
        ) ?? false
        producedProseInsteadOfTools = try container.decodeIfPresent(
            Bool.self,
            forKey: .producedProseInsteadOfTools
        ) ?? false
        redundantDuplicateToolCallCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantDuplicateToolCallCount
        ) ?? 0
        redundantZeroResultSearchCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantZeroResultSearchCount
        ) ?? 0
        redundantJoinPathCallCount = try container.decodeIfPresent(
            Int.self,
            forKey: .redundantJoinPathCallCount
        ) ?? 0
        schemaEvidence = try container.decodeIfPresent(
            SchemaToolEvidenceSummary.self,
            forKey: .schemaEvidence
        ) ?? SchemaToolEvidenceSummary()
        appSideRejectionReason = try container.decodeIfPresent(
            SchemaToolAppRejectionReason.self,
            forKey: .appSideRejectionReason
        )
        clarificationCorrectionMode = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationCorrectionMode
        ) ?? ""
        intentCoverageMode = try container.decodeIfPresent(
            String.self,
            forKey: .intentCoverageMode
        ) ?? ""
        clarificationPolicyDecision = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationPolicyDecision
        ) ?? ""
        clarificationPolicyReason = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationPolicyReason
        ) ?? ""
        overClarificationCorrectionAttempted = try container.decodeIfPresent(
            Bool.self,
            forKey: .overClarificationCorrectionAttempted
        ) ?? false
        overClarificationCorrectionSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .overClarificationCorrectionSucceeded
        ) ?? false
        databaseContextFactsUsed = try container.decodeIfPresent(
            [String].self,
            forKey: .databaseContextFactsUsed
        ) ?? []
        evidenceSufficientForSQL = try container.decodeIfPresent(
            Bool.self,
            forKey: .evidenceSufficientForSQL
        ) ?? false
        unresolvedDecisionKinds = try container.decodeIfPresent(
            [String].self,
            forKey: .unresolvedDecisionKinds
        ) ?? []
        sqlIntentCoverageDecision = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageDecision
        ) ?? ""
        sqlIntentCoverageReason = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageReason
        ) ?? ""
        sqlIntentCoverageMissingSignals = try container.decodeIfPresent(
            [String].self,
            forKey: .sqlIntentCoverageMissingSignals
        ) ?? []
        sqlIntentCoverageMismatchCategory = try container.decodeIfPresent(
            String.self,
            forKey: .sqlIntentCoverageMismatchCategory
        ) ?? ""
        intentCoverageCorrectionAttempted = try container.decodeIfPresent(
            Bool.self,
            forKey: .intentCoverageCorrectionAttempted
        ) ?? false
        intentCoverageCorrectionSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .intentCoverageCorrectionSucceeded
        ) ?? false
        planConsistencyMode = try container.decodeIfPresent(
            String.self,
            forKey: .planConsistencyMode
        ) ?? ""
        planConsistencyDecision = try container.decodeIfPresent(
            String.self,
            forKey: .planConsistencyDecision
        ) ?? ""
        planConsistencyReason = try container.decodeIfPresent(
            String.self,
            forKey: .planConsistencyReason
        ) ?? ""
        planConsistencyDivergences = try container.decodeIfPresent(
            [String].self,
            forKey: .planConsistencyDivergences
        ) ?? []
        planConsistencyCorrectionAttempted = try container.decodeIfPresent(
            Bool.self,
            forKey: .planConsistencyCorrectionAttempted
        ) ?? false
        planConsistencyCorrectionSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .planConsistencyCorrectionSucceeded
        ) ?? false
    }
}
