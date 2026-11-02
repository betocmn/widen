import Foundation
import Testing

@testable import WidenKit

/// Pins the model-call budgets a request may spend, so any change to them is
/// made deliberately. The agent wall clock moved for Particle-1 (90 s to
/// 180 s) to fit high reasoning. Repair budgets count logical generator
/// invocations, not HTTP attempts, and repair runs get a shorter wall clock.
/// The extra-calls layer doubles the agent's turn, schema-call and correction
/// budgets for Particle-1 and adds up to two forced final requests;
/// reverting the layer restores six calls and no forced requests.
@Suite("Text-to-SQL call budgets")
struct TextToSQLCallBudgetTests {
    @Test func particleAgentBudgetsMatchTheExtraCallsLayer() {
        let agent = SchemaToolSQLAgentConfiguration.default
        #expect(agent == SchemaToolSQLAgentConfiguration())
        #expect(agent.maximumModelTurns == 12)
        #expect(agent.maximumSchemaToolCalls == 12)
        #expect(agent.maximumRepairSchemaToolCalls == 4)
        #expect(agent.maximumHTTPAttempts == 30)
        #expect(agent.maximumMalformedTerminalCorrections == 2)
        #expect(agent.maximumRepeatedToolCorrections == 2)
        #expect(agent.maximumInvalidTerminalSQLCorrections == 2)
        #expect(agent.maximumOverClarificationCorrections == 1)
        #expect(agent.maximumIntentCoverageCorrections == 1)
        #expect(agent.maximumPlanConsistencyCorrections == 1)
        #expect(agent.maximumTerminalRequiredCorrections == 1)
        #expect(agent.wallClockTimeoutSeconds == 180)
        #expect(agent.forcedTerminalMode == .terminalToolOnly)
        #expect(agent.maximumForcedTerminalRequests == 2)
        #expect(agent.forcedTerminalTimeReserveSeconds == 45)

        let schemaTools = SchemaToolPolicy.cloudAgent
        #expect(schemaTools.maximumResultBytes == 16_000)
        #expect(schemaTools.maximumSessionResultBytes == 64_000)

        // Inspection sends user data values, so its budgets stay put.
        let inspection = DatabaseInspectionPolicy(allowLocalDataInspection: true)
        #expect(inspection.maximumCallCount == 4)
        #expect(inspection.maximumResultBytes == 8_000)
        #expect(inspection.maximumSessionResultBytes == 20_000)

        #expect(ChatCompletionRetryPolicy.defaultMaxAttempts == 3)
        #expect(ChatCompletionRetryPolicy().maxAttempts == 3)

        #expect(GeneratedSQLRepairCoordinator.maxModelCalls == 2)
    }

    @Test func repairBudgetsCountLogicalGeneratorInvocations() {
        let policy = TextToSQLRepairPolicy.default
        #expect(policy == TextToSQLRepairPolicy())
        #expect(policy.maximumGeneratorInvocationsPerRequest == 5)
        #expect(policy.maximumValidationRepairs == 2)
        #expect(policy.maximumVerificationRepairs == 1)
        #expect(policy.maximumExecutionRepairs == 2)
        #expect(policy.repairStartCutoffSeconds == 300)

        let agent = SchemaToolSQLAgentConfiguration.default
        #expect(agent.repairWallClockTimeoutSeconds == 120)
        #expect(agent.wallClockTimeoutSeconds(for: .initial) == 180)
        #expect(agent.wallClockTimeoutSeconds(for: .followUp) == 180)
        #expect(agent.wallClockTimeoutSeconds(for: .repair) == 120)
        #expect(agent.wallClockTimeoutSeconds(for: .reconstructAfterFailedRepair) == 120)
    }

    @Test func repairPolicyIgnoresHTTPInflatedCallCounts() {
        let policy = TextToSQLRepairPolicy.default
        // A generation saved by an older build has no invocation count. Its
        // call count mixed in HTTP attempts, so it counts as one invocation.
        let legacy = Self.generation(generationCallCount: 9, generatorInvocationCount: nil)
        #expect(TextToSQLRepairPolicy.spentInvocations(after: legacy) == 1)
        #expect(TextToSQLRepairPolicy.spentInvocations(after: nil) == 1)
        #expect(policy.remainingRepairs(cap: 2, after: legacy) == 2)
        #expect(policy.remainingRepairs(cap: 1, after: legacy) == 1)

        let afterTwoRepairs = Self.generation(generationCallCount: 30, generatorInvocationCount: 3)
        #expect(TextToSQLRepairPolicy.spentInvocations(after: afterTwoRepairs) == 3)
        #expect(policy.remainingRepairs(cap: 2, after: afterTwoRepairs) == 2)

        let afterThreeRepairs = Self.generation(generationCallCount: 4, generatorInvocationCount: 4)
        #expect(policy.remainingRepairs(cap: 2, after: afterThreeRepairs) == 1)

        let spent = Self.generation(generationCallCount: 1, generatorInvocationCount: 5)
        #expect(policy.remainingRepairs(cap: 2, after: spent) == 0)
        let overspent = Self.generation(generationCallCount: 1, generatorInvocationCount: 9)
        #expect(policy.remainingRepairs(cap: 2, after: overspent) == 0)
    }

    @Test func repairPolicyStopsStartingRepairsAtTheCutoff() {
        let policy = TextToSQLRepairPolicy.default
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(policy.allowsRepairStart(requestStartedAt: started, now: started))
        #expect(
            policy.allowsRepairStart(requestStartedAt: started, now: started.addingTimeInterval(299))
        )
        #expect(
            !policy.allowsRepairStart(requestStartedAt: started, now: started.addingTimeInterval(300))
        )
    }

    private static func generation(
        generationCallCount: Int?,
        generatorInvocationCount: Int?
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "SELECT 1",
            explanation: "Constant.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            generationCallCount: generationCallCount,
            generatorInvocationCount: generatorInvocationCount
        )
    }
}
