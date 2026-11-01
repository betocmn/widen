import Foundation
import Testing

@testable import WidenKit

/// Pins the model-call budgets a straight provider swap must keep, so any
/// change to how many calls a request may spend is made deliberately.
@Suite("Text-to-SQL call budgets")
struct TextToSQLCallBudgetTests {
    @Test func straightSwapCallBudgetsKeepCurrentDefaults() {
        let agent = OpenRouterSchemaToolSQLAgentConfiguration.default
        #expect(agent == OpenRouterSchemaToolSQLAgentConfiguration())
        #expect(agent.maximumModelTurns == 6)
        #expect(agent.maximumSchemaToolCalls == 6)
        #expect(agent.maximumRepairSchemaToolCalls == 2)
        #expect(agent.maximumHTTPAttempts == 12)
        #expect(agent.maximumMalformedTerminalCorrections == 1)
        #expect(agent.maximumRepeatedToolCorrections == 1)
        #expect(agent.wallClockTimeoutSeconds == 90)

        #expect(OpenRouterRetryPolicy.defaultMaxAttempts == 3)
        #expect(OpenRouterRetryPolicy().maxAttempts == 3)

        #expect(GeneratedSQLRepairSupport.localModelCallBudget == 3)
        #expect(GeneratedSQLRepairSupport.verificationRepairModelCallBudget == 1)
        #expect(GeneratedSQLRepairCoordinator.maxModelCalls == 2)
    }
}
