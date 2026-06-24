import Foundation
import Testing

@testable import WidenKit

@Suite("Text-to-SQL semantic comparator")
struct TextToSQLSemanticComparatorTests {
    @Test func unorderedComparisonPreservesDuplicateRows() {
        let expectation = TextToSQLSemanticExpectation(comparisonMode: .unordered)
        let golden = result(columns: ["id"], rows: [[1], [1], [2]])
        let matching = result(columns: ["id"], rows: [[2], [1], [1]])
        let missingDuplicate = result(columns: ["id"], rows: [[2], [1]])

        #expect(
            TextToSQLSemanticComparator.compare(
                golden: golden,
                candidate: matching,
                expectation: expectation
            ).equivalent
        )
        let mismatch = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: missingDuplicate,
            expectation: expectation
        )
        #expect(!mismatch.equivalent)
        #expect(mismatch.mismatchCategory == "rowCountMismatch")
    }

    @Test func orderedComparisonRequiresOrder() {
        let expectation = TextToSQLSemanticExpectation(comparisonMode: .ordered)
        let golden = result(columns: ["id"], rows: [[1], [2]])
        let candidate = result(columns: ["id"], rows: [[2], [1]])

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(!comparison.equivalent)
        #expect(comparison.mismatchCategory == "orderedRowMismatch")
    }

    @Test func unorderedComparisonUsesNonGreedyToleranceMatching() {
        let expectation = TextToSQLSemanticExpectation(
            comparisonMode: .unordered,
            floatTolerance: 1
        )
        let golden = TextToSQLSemanticQueryResult(
            columns: ["value"],
            rows: [[.float(0)], [.float(2)]]
        )
        let candidate = TextToSQLSemanticQueryResult(
            columns: ["value"],
            rows: [[.float(1)], [.float(0)]]
        )

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(comparison.equivalent)
    }

    @Test func scalarComparisonUsesFloatTolerance() {
        let expectation = TextToSQLSemanticExpectation(
            comparisonMode: .scalar,
            floatTolerance: 0.01
        )
        let golden = TextToSQLSemanticQueryResult(columns: ["score"], rows: [[.float(1.0)]])
        let candidate = TextToSQLSemanticQueryResult(columns: ["score"], rows: [[.float(1.005)]])

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(comparison.equivalent)
    }

    @Test func projectedColumnsSupportAliasesAndConfiguredExtraColumns() {
        let expectation = TextToSQLSemanticExpectation(
            comparisonMode: .projectedColumns,
            requiredColumns: [
                TextToSQLSemanticColumnExpectation(canonicalName: "id"),
                TextToSQLSemanticColumnExpectation(
                    canonicalName: "total",
                    aliases: ["total_cents", "sum"]
                ),
            ],
            allowExtraCandidateColumns: true
        )
        let golden = result(columns: ["id", "total"], rows: [[1, 42]])
        let candidate = result(columns: ["sum", "ignored", "id"], rows: [[42, 99, 1]])

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(comparison.equivalent)
    }

    @Test func projectedColumnsFailOnAmbiguousRequiredColumn() {
        let expectation = TextToSQLSemanticExpectation(
            comparisonMode: .projectedColumns,
            requiredColumns: [
                TextToSQLSemanticColumnExpectation(canonicalName: "id", aliases: ["identifier"])
            ]
        )
        let golden = result(columns: ["id"], rows: [[1]])
        let candidate = result(columns: ["id", "identifier"], rows: [[1, 1]])

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(!comparison.equivalent)
        #expect(comparison.mismatchCategory == "ambiguousCandidateColumn")
    }

    @Test func normalizesUUIDCasingJSONKeyOrderDatesAndIntervals() {
        let expectation = TextToSQLSemanticExpectation(comparisonMode: .ordered)
        let golden = TextToSQLSemanticQueryResult(
            columns: ["uuid", "payload", "day", "duration"],
            rows: [[
                .uuid("d2710e16-eb07-4fd6-a87e-b1be41c9bd3d"),
                .json(TextToSQLSemanticValue.canonicalJSON("{\"b\":2,\"a\":1}")!),
                .date("2026-06-23"),
                .interval(months: 1, days: 2, microseconds: 3),
            ]]
        )
        let candidate = TextToSQLSemanticQueryResult(
            columns: ["uuid", "payload", "day", "duration"],
            rows: [[
                .string("D2710E16-EB07-4FD6-A87E-B1BE41C9BD3D"),
                .json(TextToSQLSemanticValue.canonicalJSON("{\"a\":1,\"b\":2}")!),
                .date("2026-06-23"),
                .interval(months: 1, days: 2, microseconds: 3),
            ]]
        )

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(comparison.equivalent)
        #expect(comparison.goldenDigest.count == 64)
        #expect(comparison.candidateDigest.count == 64)
    }

    @Test func timestampWithTimezoneDoesNotEqualLocalTimestamp() {
        let expectation = TextToSQLSemanticExpectation(comparisonMode: .ordered)
        let golden = TextToSQLSemanticQueryResult(
            columns: ["created_at"],
            rows: [[.timestampWithTimeZone("2026-06-23T10:00:00.000000Z")]]
        )
        let candidate = TextToSQLSemanticQueryResult(
            columns: ["created_at"],
            rows: [[.timestampWithoutTimeZone("2026-06-23 10:00:00.000000")]]
        )

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(!comparison.equivalent)
        #expect(comparison.mismatchCategory == "orderedRowMismatch")
    }

    @Test func unsupportedTypesFailComparisonExplicitly() {
        let expectation = TextToSQLSemanticExpectation(comparisonMode: .ordered)
        let golden = TextToSQLSemanticQueryResult(columns: ["value"], rows: [[.unsupported("POINT")]])
        let candidate = TextToSQLSemanticQueryResult(columns: ["value"], rows: [[.unsupported("POINT")]])

        let comparison = TextToSQLSemanticComparator.compare(
            golden: golden,
            candidate: candidate,
            expectation: expectation
        )

        #expect(!comparison.equivalent)
        #expect(comparison.mismatchCategory == "comparatorUnsupportedType")
    }

    private func result(columns: [String], rows: [[Int]]) -> TextToSQLSemanticQueryResult {
        TextToSQLSemanticQueryResult(
            columns: columns,
            rows: rows.map { row in row.map { .number(Decimal($0)) } }
        )
    }
}
