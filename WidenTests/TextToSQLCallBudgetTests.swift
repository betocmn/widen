import Foundation
import Testing

@testable import WidenKit

/// Pins the model-call budgets a straight provider swap must keep, so any
/// change to how many calls a request may spend is made deliberately. Only the
/// agent wall clock moved for Particle-1 (90 s to 180 s), to fit high reasoning.
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
        #expect(agent.wallClockTimeoutSeconds == 180)

        #expect(ChatCompletionRetryPolicy.defaultMaxAttempts == 3)
        #expect(ChatCompletionRetryPolicy().maxAttempts == 3)

        #expect(GeneratedSQLRepairSupport.cloudModelCallBudget == 3)
        #expect(GeneratedSQLRepairSupport.verificationRepairModelCallBudget == 1)
        #expect(GeneratedSQLRepairCoordinator.maxModelCalls == 2)
    }
}
