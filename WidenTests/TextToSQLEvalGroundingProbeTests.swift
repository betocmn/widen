import Foundation
import Testing

@testable import WidenKit

/// The held-out grounding probe: new questions over the existing fixture
/// schemas, half of them ambiguous and half answerable with words the lexical
/// grounding pass flags. These checks are free; they send no requests.
@Suite("Text-to-SQL eval grounding probe")
struct TextToSQLEvalGroundingProbeTests {
    @Test func probeSuiteValidatesAgainstTheFixtureSchemas() throws {
        let suite = try Self.suite()

        try TextToSQLEvalSuiteValidator.validate(
            suite: suite,
            suiteURL: Self.suiteURL,
            requireSemanticExpectations: true
        )
        #expect(suite.name == "grounding-probe-v1")
        #expect((16...20).contains(suite.cases.count))
        let answerable = suite.cases.filter { $0.expected.decision == .sql }
        let ambiguous = suite.cases.filter { $0.expected.decision == .clarify }
        #expect(answerable.count == ambiguous.count)
        // Every fixture with a seeded database, and only those.
        #expect(Set(suite.cases.map(\.schemaFixture)) == ["commerce", "preseason", "saas", "support"])
        for fixture in Set(suite.cases.map(\.schemaFixture)) {
            #expect(
                FileManager.default.fileExists(
                    atPath: Self.root.appendingPathComponent("Evals/databases/\(fixture)/setup.json").path
                ),
                "\(fixture)"
            )
        }
    }

    @Test func probeQuestionsAreNewToTheReleaseSuite() throws {
        let probe = try Self.suite()
        let release = try JSONDecoder().decode(
            TextToSQLEvalSuite.self,
            from: Data(contentsOf: Self.root.appendingPathComponent("Evals/suites/text-to-sql-v1.json"))
        )

        #expect(Set(probe.cases.map(\.id)).isDisjoint(with: release.cases.map(\.id)))
        let releaseQuestions = Set(release.cases.map { Self.normalized($0.question) })
        for evalCase in probe.cases {
            #expect(!releaseQuestions.contains(Self.normalized(evalCase.question)), "\(evalCase.id)")
        }
    }

    @Test func lexicalGroundingFlagsEveryAnswerableItem() throws {
        let suite = try Self.suite()

        for evalCase in suite.cases where evalCase.expected.decision == .sql {
            let goldenSQL = try #require(evalCase.expected.goldenSQL, "\(evalCase.id)")
            let review = GeneratedSQLPostprocessor.groundingReview(
                sql: goldenSQL,
                question: evalCase.question,
                schema: try Self.schema(evalCase.schemaFixture),
                databaseContext: evalCase.databaseContext ?? ""
            )
            // Without a judge the grounding pass would withhold the golden
            // SQL itself and ask about a word instead.
            #expect(review?.unresolvedTerms.isEmpty == false, "\(evalCase.id)")
        }
    }

    @Test func ambiguousItemsExpectTheirAmbiguousWordInTheClarification() throws {
        let suite = try Self.suite()

        for evalCase in suite.cases where evalCase.expected.decision == .clarify {
            let questionWords = Set(Self.words(evalCase.question))
            let conceptWords = Set(evalCase.expected.clarificationMustMentionAny.flatMap(Self.words))
            #expect(!questionWords.isDisjoint(with: conceptWords), "\(evalCase.id)")
        }
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let suiteURL = root.appendingPathComponent("Evals/suites/grounding-probe-v1.json")

    private static func suite() throws -> TextToSQLEvalSuite {
        try JSONDecoder().decode(TextToSQLEvalSuite.self, from: Data(contentsOf: suiteURL))
    }

    private static func schema(_ fixture: String) throws -> DatabaseSchema {
        try JSONDecoder().decode(
            DatabaseSchema.self,
            from: Data(contentsOf: root.appendingPathComponent("Evals/schemas/\(fixture)-schema.json"))
        )
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        words(text).joined(separator: " ")
    }
}
