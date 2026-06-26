import Testing

@testable import WidenKit

@Suite("Text-to-SQL release gate")
struct TextToSQLReleaseGateTests {
    @Test func passingInputSatisfiesAllCriteria() {
        let evaluation = TextToSQLReleaseGate.evaluate(Self.passingInput())
        let allCriteriaPassed = !evaluation.criteria.contains { !$0.passed }

        #expect(evaluation.passed)
        #expect(allCriteriaPassed)
    }

    @Test func resultCountMustBeFullRepeatedSuite() {
        var input = Self.passingInput()
        input.totalResults = 20

        let criterion = Self.criterion("result-count", in: TextToSQLReleaseGate.evaluate(input))

        #expect(criterion?.passed == false)
    }

    @Test func endToEndRateMustMeetThreshold() {
        var input = Self.passingInput()
        input.endToEndPass = TextToSQLReleaseGateCount(count: 53, denominator: 60)

        let failed = Self.criterion("end-to-end", in: TextToSQLReleaseGate.evaluate(input))
        #expect(failed?.passed == false)

        input.endToEndPass = TextToSQLReleaseGateCount(count: 54, denominator: 60)
        let passed = Self.criterion("end-to-end", in: TextToSQLReleaseGate.evaluate(input))
        #expect(passed?.passed == true)
    }

    @Test func safetyMustPassEveryEvaluatedResult() {
        var input = Self.passingInput()
        input.safetyValid = TextToSQLReleaseGateCount(count: 39, denominator: 40)

        let criterion = Self.criterion("safety", in: TextToSQLReleaseGate.evaluate(input))

        #expect(criterion?.passed == false)
    }

    @Test func schemaMustPassEveryEvaluatedResult() {
        var input = Self.passingInput()
        input.schemaValid = TextToSQLReleaseGateCount(count: 39, denominator: 40)

        let criterion = Self.criterion("schema", in: TextToSQLReleaseGate.evaluate(input))

        #expect(criterion?.passed == false)
    }

    @Test func clarificationDecisionAccuracyMustPassEveryClarificationCase() {
        var input = Self.passingInput()
        input.clarificationDecisionPass = TextToSQLReleaseGateCount(count: 8, denominator: 9)

        let criterion = Self.criterion("clarification", in: TextToSQLReleaseGate.evaluate(input))

        #expect(criterion?.passed == false)
    }

    @Test func transportReliabilityMustMeetThreshold() {
        var input = Self.passingInput()
        input.transportSuccess = TextToSQLReleaseGateCount(count: 56, denominator: 60)

        let failed = Self.criterion("transport", in: TextToSQLReleaseGate.evaluate(input))
        #expect(failed?.passed == false)

        input.transportSuccess = TextToSQLReleaseGateCount(count: 57, denominator: 60)
        let passed = Self.criterion("transport", in: TextToSQLReleaseGate.evaluate(input))
        #expect(passed?.passed == true)
    }

    @Test func repeatedNoProgressRepairsMustBeZero() {
        var input = Self.passingInput()
        input.repeatedNoProgressRepairCount = 1

        let criterion = Self.criterion(
            "no-progress-repair",
            in: TextToSQLReleaseGate.evaluate(input)
        )

        #expect(criterion?.passed == false)
    }

    private static func passingInput() -> TextToSQLReleaseGateInput {
        TextToSQLReleaseGateInput(
            totalResults: 60,
            endToEndPass: TextToSQLReleaseGateCount(count: 54, denominator: 60),
            safetyValid: TextToSQLReleaseGateCount(count: 40, denominator: 40),
            schemaValid: TextToSQLReleaseGateCount(count: 40, denominator: 40),
            clarificationDecisionPass: TextToSQLReleaseGateCount(count: 9, denominator: 9),
            transportSuccess: TextToSQLReleaseGateCount(count: 57, denominator: 60),
            repeatedNoProgressRepairCount: 0
        )
    }

    private static func criterion(
        _ id: String,
        in evaluation: TextToSQLReleaseGateEvaluation
    ) -> TextToSQLReleaseGateCriterion? {
        evaluation.criteria.first { $0.id == id }
    }
}
