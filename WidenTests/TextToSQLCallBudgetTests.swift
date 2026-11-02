import Foundation
import Testing

@testable import WidenKit

/// Pins the model-call budgets a request may spend, so any change to them is
/// made deliberately. The agent wall clock moved for Particle-1 (90 s to
/// 180 s) to fit high reasoning. Repair budgets count logical generator
/// invocations, not HTTP attempts, and repair runs get a shorter wall clock.
@Suite("Text-to-SQL call budgets")
struct TextToSQLCallBudgetTests {
    @Test func straightSwapCallBudgetsKeepCurrentDefaults() {
        let agent = SchemaToolSQLAgentConfiguration.default
        #expect(agent == SchemaToolSQLAgentConfiguration())
        #expect(agent.maximumModelTurns == 6)
        #expect(agent.maximumSchemaToolCalls == 6)
        #expect(agent.maximumRepairSchemaToolCalls == 2)
        #expect(agent.maximumHTTPAttempts == 12)
        #expect(agent.maximumMalformedTerminalCorrections == 1)
        #expect(agent.maximumRepeatedToolCorrections == 1)
        #expect(agent.maximumInvalidTerminalSQLCorrections == 1)
        #expect(agent.maximumOverClarificationCorrections == 1)
        #expect(agent.maximumIntentCoverageCorrections == 1)
        #expect(agent.maximumPlanConsistencyCorrections == 1)
        #expect(agent.maximumTerminalRequiredCorrections == 1)
        #expect(agent.wallClockTimeoutSeconds == 180)

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
