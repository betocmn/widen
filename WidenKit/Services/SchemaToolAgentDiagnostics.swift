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
    /// Tool calls whose provider id repeated one from an earlier turn. The
    /// agent namespaces ids per turn, so a reuse is recorded, not rejected.
    /// `nil` when no id was reused, and in sessions saved before it existed.
    public var providerToolCallIDReuseCount: Int?
    /// Terminal arguments that were ignored: unknown keys and a `query_plan`
    /// of the wrong type, summed over the run's terminal calls. Only the
    /// count is kept, never the key names. `nil` when nothing was ignored.
    public var terminalIgnoredArgumentKeyCount: Int?
    /// Tool calls answered with a session-budget error instead of running,
    /// including the calls left over in a batch after the budget ran out.
    /// `nil` when every call fit.
    public var budgetRejectedToolCallCount: Int?
    /// Tool calls whose single result was too large for the per-call byte
    /// budget. The session goes on, so the model can retry with fewer IDs.
    /// `nil` when no result was too large.
    public var resultBudgetToolErrorCount: Int?
    /// `true` once the schema tool session ran out of calls or bytes.
    /// `nil` when it never did.
    public var toolBudgetExhausted: Bool?
    /// `true` once the database inspection session ran out of calls or
    /// bytes. `nil` when it never did, or the run had no inspection.
    public var inspectionBudgetExhausted: Bool?
    /// Why the run forced a final terminal request: `toolBudget`,
    /// `turnBudget`, `terminalRequired` or `timeReserve`. `nil` when it
    /// forced none.
    public var forcedTerminalReason: String?
    /// Forced final requests sent. `nil` when none was.
    public var forcedTerminalRequestCount: Int?
    /// Whether a forced request ended in an accepted terminal answer. `nil`
    /// when the run forced none.
    public var forcedTerminalSucceeded: Bool?
    /// How the forced requests failed: `nonTerminalResponse`,
    /// `requestLimitReached`, `cloudRequestFailure:` and the provider's
    /// failure category, or the agent failure category. `nil` unless they
    /// failed.
    public var forcedTerminalFailure: String?
    /// `enabled` when the run could ask the critic to review its SQL. `nil`
    /// when the critic was off.
    public var criticMode: String?
    /// Critic review requests sent, failed ones included. `nil` when none was.
    public var criticCallCount: Int?
    /// Each review's verdict after validation, `accept`, `revise` or
    /// `clarify`, or `error` for a review that failed. `nil` when none ran.
    public var criticVerdicts: [String]?
    /// Revisions the critic sent back to the agent. `nil` when none was.
    public var criticRevisionCount: Int?
    /// How the critic step ended for the run's SQL, such as `accepted`,
    /// `revisedAccepted`, `failedOpen`, a `skipped…` reason or a
    /// `…ReleasedPrevious` outcome that kept the SQL from before a revision.
    /// `nil` when the run's answer never reached the critic step.
    public var criticFinalOutcome: String?
    /// The kinds of the issues revisions sent back, at most 12. `nil` when
    /// there were none.
    public var criticIssueKinds: [String]?
    /// Why the last failed review failed: `invalidJSON`, `invalidShape`,
    /// `cloudRequestFailure:` and the provider's failure category, or the
    /// agent failure category. `nil` unless a review failed.
    public var criticFailureReason: String?
    /// Whether a review request carried inspected data values, for privacy
    /// audits. `nil` when no review request was sent.
    public var criticSharedDataValues: Bool?

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
        planConsistencyCorrectionSucceeded: Bool = false,
        providerToolCallIDReuseCount: Int? = nil,
        terminalIgnoredArgumentKeyCount: Int? = nil,
        budgetRejectedToolCallCount: Int? = nil,
        resultBudgetToolErrorCount: Int? = nil,
        toolBudgetExhausted: Bool? = nil,
        inspectionBudgetExhausted: Bool? = nil,
        forcedTerminalReason: String? = nil,
        forcedTerminalRequestCount: Int? = nil,
        forcedTerminalSucceeded: Bool? = nil,
        forcedTerminalFailure: String? = nil,
        criticMode: String? = nil,
        criticCallCount: Int? = nil,
        criticVerdicts: [String]? = nil,
        criticRevisionCount: Int? = nil,
        criticFinalOutcome: String? = nil,
        criticIssueKinds: [String]? = nil,
        criticFailureReason: String? = nil,
        criticSharedDataValues: Bool? = nil
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
        self.providerToolCallIDReuseCount = providerToolCallIDReuseCount
        self.terminalIgnoredArgumentKeyCount = terminalIgnoredArgumentKeyCount
        self.budgetRejectedToolCallCount = budgetRejectedToolCallCount
        self.resultBudgetToolErrorCount = resultBudgetToolErrorCount
        self.toolBudgetExhausted = toolBudgetExhausted
        self.inspectionBudgetExhausted = inspectionBudgetExhausted
        self.forcedTerminalReason = forcedTerminalReason
        self.forcedTerminalRequestCount = forcedTerminalRequestCount
        self.forcedTerminalSucceeded = forcedTerminalSucceeded
        self.forcedTerminalFailure = forcedTerminalFailure
        self.criticMode = criticMode
        self.criticCallCount = criticCallCount
        self.criticVerdicts = criticVerdicts
        self.criticRevisionCount = criticRevisionCount
        self.criticFinalOutcome = criticFinalOutcome
        self.criticIssueKinds = criticIssueKinds
        self.criticFailureReason = criticFailureReason
        self.criticSharedDataValues = criticSharedDataValues
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
        case providerToolCallIDReuseCount
        case terminalIgnoredArgumentKeyCount
        case budgetRejectedToolCallCount
        case resultBudgetToolErrorCount
        case toolBudgetExhausted
        case inspectionBudgetExhausted
        case forcedTerminalReason
        case forcedTerminalRequestCount
        case forcedTerminalSucceeded
        case forcedTerminalFailure
        case criticMode
        case criticCallCount
        case criticVerdicts
        case criticRevisionCount
        case criticFinalOutcome
        case criticIssueKinds
        case criticFailureReason
        case criticSharedDataValues
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
        providerToolCallIDReuseCount = try? container.decodeIfPresent(
            Int.self,
            forKey: .providerToolCallIDReuseCount
        )
        terminalIgnoredArgumentKeyCount = try? container.decodeIfPresent(
            Int.self,
            forKey: .terminalIgnoredArgumentKeyCount
        )
        budgetRejectedToolCallCount = try? container.decodeIfPresent(
            Int.self,
            forKey: .budgetRejectedToolCallCount
        )
        resultBudgetToolErrorCount = try? container.decodeIfPresent(
            Int.self,
            forKey: .resultBudgetToolErrorCount
        )
        toolBudgetExhausted = try? container.decodeIfPresent(
            Bool.self,
            forKey: .toolBudgetExhausted
        )
        inspectionBudgetExhausted = try? container.decodeIfPresent(
            Bool.self,
            forKey: .inspectionBudgetExhausted
        )
        forcedTerminalReason = try? container.decodeIfPresent(
            String.self,
            forKey: .forcedTerminalReason
        )
        forcedTerminalRequestCount = try? container.decodeIfPresent(
            Int.self,
            forKey: .forcedTerminalRequestCount
        )
        forcedTerminalSucceeded = try? container.decodeIfPresent(
            Bool.self,
            forKey: .forcedTerminalSucceeded
        )
        forcedTerminalFailure = try? container.decodeIfPresent(
            String.self,
            forKey: .forcedTerminalFailure
        )
        criticMode = try? container.decodeIfPresent(String.self, forKey: .criticMode)
        criticCallCount = try? container.decodeIfPresent(Int.self, forKey: .criticCallCount)
        criticVerdicts = try? container.decodeIfPresent([String].self, forKey: .criticVerdicts)
        criticRevisionCount = try? container.decodeIfPresent(Int.self, forKey: .criticRevisionCount)
        criticFinalOutcome = try? container.decodeIfPresent(String.self, forKey: .criticFinalOutcome)
        criticIssueKinds = try? container.decodeIfPresent([String].self, forKey: .criticIssueKinds)
        criticFailureReason = try? container.decodeIfPresent(String.self, forKey: .criticFailureReason)
        criticSharedDataValues = try? container.decodeIfPresent(
            Bool.self,
            forKey: .criticSharedDataValues
        )
    }
}
