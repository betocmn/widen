import Foundation
import Testing

@testable import WidenKit

/// The SQL the grounding postprocessor withheld: which results a semantic
/// run compares, the guards it passes first, and the reported counts. None of
/// it may change a result's status.
@Suite("Text-to-SQL eval withheld SQL")
struct TextToSQLEvalWithheldSQLTests {
    @Test func onlyResultsThatExpectedSQLAreCompared() {
        let sql = "SELECT id FROM public.customers WHERE status = 'active' LIMIT 100"
        let withheld = Self.result(decisionMatches: false).recordingWithheldSQL(sql)

        #expect(
            TextToSQLEvalWithheldSQL.scoring(
                for: withheld,
                evalCase: Self.evalCase(.sql),
                schema: Self.schema()
            ) == .compare(sql: sql)
        )
        // Withholding was the right answer when the case expects a
        // clarification, so there is nothing to compare.
        #expect(
            TextToSQLEvalWithheldSQL.scoring(
                for: withheld,
                evalCase: Self.evalCase(.clarify),
                schema: Self.schema()
            ) == .skipped
        )
        // A result that withheld nothing has nothing to compare, even when
        // it answered with SQL.
        let answered = TextToSQLEvalResult(
            caseID: "commerce.active-customers",
            backend: .cloud,
            repeatIndex: 1,
            status: .passed,
            metrics: Self.metrics(decisionMatches: true),
            generatedSQL: sql
        )
        #expect(
            TextToSQLEvalWithheldSQL.scoring(
                for: answered,
                evalCase: Self.evalCase(.sql),
                schema: Self.schema()
            ) == .skipped
        )
        #expect(Self.result(decisionMatches: false).recordingWithheldSQL("  \n") == Self.result(decisionMatches: false))
    }

    @Test func withheldSQLPassesTheGuardsThePipelineAppliesBeforeItIsCompared() {
        func scoring(_ sql: String) -> TextToSQLEvalWithheldSQL.Scoring {
            TextToSQLEvalWithheldSQL.scoring(
                for: Self.result(decisionMatches: false).recordingWithheldSQL(sql),
                evalCase: Self.evalCase(.sql),
                schema: Self.schema()
            )
        }

        // The same quote repair the pipeline applies.
        #expect(
            scoring("SELECT createdAt FROM public.customers LIMIT 100")
                == .compare(sql: #"SELECT "createdAt" FROM public.customers LIMIT 100"#)
        )
        // Unknown columns, unsafe statements and writes are never executed.
        #expect(scoring("SELECT missing FROM public.customers LIMIT 100") == .rejectedByGuards)
        #expect(
            scoring("SELECT id FROM public.customers; DROP TABLE public.customers")
                == .rejectedByGuards
        )
        #expect(scoring("DELETE FROM public.customers WHERE id = 1") == .rejectedByGuards)
        #expect(
            scoring("UPDATE public.customers SET status = 'active' WHERE id = 1")
                == .rejectedByGuards
        )
    }

    @Test func theWithheldSQLComparisonNeverChangesTheResult() {
        var result = Self.result(decisionMatches: false).recordingWithheldSQL(
            "SELECT id FROM public.customers LIMIT 100"
        )
        result.metrics.endToEndPassed = false
        result.metrics.semanticStatus = .notApplicable

        let expectedPassed: [TextToSQLSemanticStatus: Bool?] = [
            .passed: true,
            .resultMismatch: false,
            .candidateExecutionFailure: false,
            .resultLimitExceeded: false,
            // The comparison could not judge the withheld SQL.
            .goldenFixtureFailure: nil,
            .semanticEnvironmentUnavailable: nil,
            .fixtureInvalid: nil,
            .notApplicable: nil,
        ]
        #expect(Set(expectedPassed.keys) == Set(TextToSQLSemanticStatus.allCases))
        for (status, passed) in expectedPassed {
            let scored = result.withWithheldSQLSemantic(status: status)
            #expect(scored.metrics.withheldSQLSemanticStatus == status)
            #expect(scored.metrics.withheldSQLSemanticPassed == passed, "\(status)")

            var unchanged = scored
            unchanged.metrics.withheldSQLSemanticStatus = nil
            unchanged.metrics.withheldSQLSemanticPassed = nil
            #expect(unchanged == result, "\(status)")
            #expect(scored.status == .wrongDecision)
            #expect(scored.metrics.endToEndPassed == false)
            #expect(scored.metrics.semanticStatus == .notApplicable)
        }
    }

    @Test func anExecutionReadsLikeTheResultsOwnComparison() {
        let rows = TextToSQLSemanticQueryResult(columns: [], rows: [])
        func comparison(equivalent: Bool) -> TextToSQLSemanticComparisonResult {
            TextToSQLSemanticComparisonResult(
                equivalent: equivalent,
                mismatchCategory: equivalent ? nil : "rowValues",
                goldenRowCount: 1,
                candidateRowCount: 1,
                goldenDigest: "a",
                candidateDigest: equivalent ? "a" : "b"
            )
        }
        let cases: [(TextToSQLSemanticExecutionOutput, TextToSQLSemanticStatus)] = [
            (
                TextToSQLSemanticExecutionOutput(
                    goldenResult: rows,
                    candidateResult: rows,
                    comparison: comparison(equivalent: true),
                    latencyMs: 1
                ),
                .passed
            ),
            (
                TextToSQLSemanticExecutionOutput(
                    goldenResult: rows,
                    candidateResult: rows,
                    comparison: comparison(equivalent: false),
                    latencyMs: 1
                ),
                .resultMismatch
            ),
            (
                TextToSQLSemanticExecutionOutput(
                    goldenResult: rows,
                    candidateError: "column does not exist",
                    latencyMs: 1
                ),
                .candidateExecutionFailure
            ),
            (TextToSQLSemanticExecutionOutput(goldenError: "golden failed", latencyMs: 1), .goldenFixtureFailure),
            (
                TextToSQLSemanticExecutionOutput(
                    goldenResult: rows,
                    candidateError: "too many rows",
                    resultLimitExceeded: true,
                    latencyMs: 1
                ),
                .resultLimitExceeded
            ),
        ]
        for (output, status) in cases {
            #expect(TextToSQLEvalWithheldSQL.semanticStatus(for: output) == status)
        }
    }

    @Test func summaryCountsWithheldComparedAndPassingSQL() throws {
        func withheld(
            expectedSQL: Bool,
            status: TextToSQLSemanticStatus? = nil
        ) -> TextToSQLEvalResult {
            let result = Self.result(decisionMatches: !expectedSQL)
                .recordingWithheldSQL("SELECT id FROM public.customers LIMIT 100")
            return status.map { result.withWithheldSQLSemantic(status: $0) } ?? result
        }
        let results = [
            withheld(expectedSQL: true, status: .passed),
            withheld(expectedSQL: true, status: .resultMismatch),
            withheld(expectedSQL: true, status: .candidateExecutionFailure),
            withheld(expectedSQL: true, status: .semanticEnvironmentUnavailable),
            withheld(expectedSQL: false),
            Self.result(decisionMatches: true),
        ]

        let summary = try #require(TextToSQLEvalWithheldSQLSummary(results: results))
        #expect(summary.withheldResults == 5)
        #expect(summary.expectedSQLResults == 4)
        #expect(summary.scoredResults == 3)
        #expect(summary.semanticPassed == 1)
        #expect(
            summary.semanticStatusCounts == [
                "passed": 1,
                "resultMismatch": 1,
                "candidateExecutionFailure": 1,
                "semanticEnvironmentUnavailable": 1,
            ]
        )
        #expect(TextToSQLEvalWithheldSQLSummary.markdownRows(summary) == [
            "| SQL withheld by grounding | 5 |",
            "| Withheld SQL where SQL was expected | 4 of 5 (80.0%) |",
            "| Withheld SQL semantic passes | 1 of 3 (33.3%) |",
            "| Withheld SQL semantic statuses | candidateExecutionFailure 1, passed 1, resultMismatch 1, semanticEnvironmentUnavailable 1 |",
        ])
        #expect(
            try JSONDecoder().decode(
                TextToSQLEvalWithheldSQLSummary.self,
                from: JSONEncoder().encode(summary)
            ) == summary
        )

        #expect(TextToSQLEvalWithheldSQLSummary(results: [Self.result(decisionMatches: true)]) == nil)
        #expect(TextToSQLEvalWithheldSQLSummary(results: []) == nil)
        #expect(TextToSQLEvalWithheldSQLSummary.markdownRows(nil).allSatisfy { $0.hasSuffix("| - |") })
    }

    @Test func resultsWrittenBeforeWithheldSQLDecodeWithoutIt() throws {
        let line = """
            {"caseID":"commerce.customer-paid-revenue","backend":"cloud","model":"particle-1",\
            "repeatIndex":1,"status":"wrongDecision","metrics":{"backendAvailable":true,\
            "transportSuccess":true,"structuredResponseParsed":true,"decisionMatches":false,\
            "forbiddenBindingViolations":[],"latencyMs":18234,"semanticExecutionAttempted":false,\
            "endToEndPassed":false,"semanticStatus":"notApplicable"},\
            "diagnostics":{"missingTables":[],"missingColumnBindings":[],"missingOperations":[],\
            "safetyErrors":[],"schemaErrors":[]},\
            "clarificationQuestion":"What column, condition, or table defines \\"revenue\\" for this question?",\
            "referencedTables":["public.customers","public.orders"],"referencedColumnBindings":[]}
            """
        let result = try JSONDecoder().decode(TextToSQLEvalResult.self, from: Data(line.utf8))

        #expect(result.status == .wrongDecision)
        #expect(result.withheldSQL == nil)
        #expect(result.metrics.groundingWithheldSQL == nil)
        #expect(result.metrics.withheldSQLSemanticStatus == nil)
        #expect(result.metrics.withheldSQLSemanticPassed == nil)
        #expect(TextToSQLEvalWithheldSQLSummary(results: [result]) == nil)

        // run.json files written before the summary decode with nil: the
        // field is optional and EvalRunSummary keeps synthesized decoding.
        let runner = try Self.source("WidenEval/EvalRunner.swift")
        let summaryStart = try #require(runner.range(of: "struct EvalRunSummary: Codable {"))
        let summaryEnd = try #require(
            runner.range(of: "struct LatencySummary: Codable {", range: summaryStart.upperBound..<runner.endIndex)
        )
        let summary = String(runner[summaryStart.upperBound..<summaryEnd.lowerBound])
        #expect(summary.contains("    var withheldSQL: TextToSQLEvalWithheldSQLSummary?\n"))
        #expect(!summary.contains("init(from decoder"))
        #expect(runner.contains("withheldSQL: TextToSQLEvalWithheldSQLSummary(results: results)"))
    }

    @Test func semanticRunsCompareWithheldSQLAfterTheResultsOwnAnnotation() throws {
        let runner = try Self.source("WidenEval/EvalRunner.swift")

        #expect(
            runner.contains(
                """
                                        result = await semanticPreparation.annotate(
                                            staticResult,
                                            evalCase: evalCase,
                                            schema: schema
                                        )
                """
            )
        )
        let annotateStart = try #require(runner.range(of: "        func annotate(\n"))
        let annotate = String(runner[annotateStart.upperBound...].prefix(400))
        #expect(annotate.contains("let annotated = await annotateAnswer(result, evalCase: evalCase)"))
        #expect(
            annotate.contains(
                "return await scoringWithheldSQL(annotated, evalCase: evalCase, schema: schema)"
            )
        )

        let scoringStart = try #require(runner.range(of: "private func scoringWithheldSQL("))
        let scoringEnd = try #require(
            runner.range(
                of: "private func prepareSemanticDatabases(",
                range: scoringStart.upperBound..<runner.endIndex
            )
        )
        let scoring = String(runner[scoringStart.upperBound..<scoringEnd.lowerBound])
        #expect(
            scoring.contains(
                "switch TextToSQLEvalWithheldSQL.scoring(for: result, evalCase: evalCase, schema: schema) {"
            )
        )
        #expect(scoring.contains("candidateSQL: withheldSQL,"))
        #expect(scoring.contains("return result.withWithheldSQLSemantic(status: .candidateExecutionFailure)"))
        // Only the withheld SQL's own metrics are written.
        #expect(!scoring.contains("withSemantic("))
        #expect(!scoring.contains(".status ="))
        #expect(!scoring.contains("endToEndPassed"))

        #expect(
            TextToSQLEvalSourceManifest.scorerSourcePaths(includesSchemaToolAgent: false)
                .contains("WidenKit/Evals/TextToSQLEvalWithheldSQL.swift")
        )
    }

    @Test func reportersShowTheWithheldSQLCountsUngated() throws {
        let evalReporter = try Self.source("WidenEval/EvalReporter.swift")
        let summaryStart = try #require(evalReporter.range(of: "private static func summarySection("))
        let summaryEnd = try #require(
            evalReporter.range(
                of: "private static func statusCountSection(",
                range: summaryStart.upperBound..<evalReporter.endIndex
            )
        )
        #expect(
            evalReporter[summaryStart.upperBound..<summaryEnd.lowerBound].contains(
                "lines += TextToSQLEvalWithheldSQLSummary.markdownRows(summary.withheldSQL)"
            )
        )

        let gateReporter = try Self.source("WidenEval/ReleaseGateReporter.swift")
        let sectionStart = try #require(gateReporter.range(of: "private static func reportedUsageSection("))
        let sectionEnd = try #require(
            gateReporter.range(
                of: "private static func historicalRegressionSection(",
                range: sectionStart.upperBound..<gateReporter.endIndex
            )
        )
        let section = String(gateReporter[sectionStart.upperBound..<sectionEnd.lowerBound])
        #expect(section.contains("\"## Reported (not gated)\","))
        #expect(section.contains("TextToSQLEvalWithheldSQLSummary(results: results)"))

        // The gate reads statuses and its own counts, never the withheld SQL.
        let gate = try Self.source("WidenKit/Evals/TextToSQLReleaseGate.swift")
        #expect(!gate.contains("withheld"))
        #expect(!gateReporter.contains("withheldSQLSemantic"))
    }

    private static func result(decisionMatches: Bool) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: "commerce.active-customers",
            backend: .cloud,
            repeatIndex: 1,
            status: decisionMatches ? .passed : .wrongDecision,
            metrics: metrics(decisionMatches: decisionMatches),
            clarificationQuestion: "What column, condition, or table defines \"active\" for this question?"
        )
    }

    private static func metrics(decisionMatches: Bool) -> TextToSQLEvalMetrics {
        TextToSQLEvalMetrics(
            backendAvailable: true,
            transportSuccess: true,
            structuredResponseParsed: true,
            decisionMatches: decisionMatches,
            latencyMs: 1
        )
    }

    private static func evalCase(_ decision: TextToSQLEvalDecision) -> TextToSQLEvalCase {
        TextToSQLEvalCase(
            id: "commerce.active-customers",
            schemaFixture: "commerce",
            question: "Show active customers",
            expected: TextToSQLEvalExpectation(decision: decision)
        )
    }

    private static func schema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        column("id", type: "integer", ordinal: 1),
                        column("status", type: "text", ordinal: 2),
                        column("createdAt", type: "timestamp with time zone", ordinal: 3),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private static func column(_ name: String, type: String, ordinal: Int) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: "customers",
            name: name,
            dataType: type,
            isNullable: false,
            ordinalPosition: ordinal
        )
    }

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
