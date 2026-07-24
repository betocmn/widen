import Foundation
import Testing

@testable import WidenKit

@Suite("Schema tool agent plan consistency policy")
struct SchemaToolAgentPlanConsistencyPolicyTests {

    // MARK: - Structured plan decoding

    @Test func decodesFullConformingPlan() throws {
        let plan = try #require(decodePlan("""
            {
              "grain": "one row per tool",
              "joins": [
                {"table": "public.preseason_tool", "role": "entity"},
                {"table": "public.preseason_match_config", "role": "wins source"}
              ],
              "filters": ["verified tools only"],
              "projection": [
                {"expression": "t.id", "alias": ""},
                {"expression": "t.name"}
              ],
              "aggregation": [
                {"function": "COUNT", "column": "m.id", "alias": "wins"}
              ],
              "grouping": ["t.id", "t.name"],
              "ordering": ["wins DESC"],
              "limit": 5,
              "date_anchors": ["last 30 days from CURRENT_DATE"]
            }
            """))

        #expect(plan.grain == "one row per tool")
        #expect(plan.joins.count == 2)
        #expect(plan.joins[0].table == "public.preseason_tool")
        #expect(plan.projection.count == 2)
        #expect(plan.aggregation == [
            .init(function: "COUNT", column: "m.id", alias: "wins")
        ])
        #expect(plan.limit == 5)
        #expect(plan.sectionLabels == [
            "grain", "joins", "filters", "projection", "aggregation",
            "grouping", "ordering", "limit", "date anchors",
        ])
    }

    @Test func decodesMinimalPlanWithOnlyProjection() throws {
        let plan = try #require(decodePlan("""
            {"projection": [{"expression": "u.email"}]}
            """))
        #expect(plan.projection == [.init(expression: "u.email", alias: "")])
        #expect(plan.sectionLabels == ["projection"])
    }

    @Test func rejectsUnknownTopLevelKey() {
        #expect(decodePlan(#"{"projection": [], "notes": "x"}"#) == nil)
    }

    @Test func rejectsWrongFieldTypes() {
        #expect(decodePlan(#"{"grain": 3}"#) == nil)
        #expect(decodePlan(#"{"joins": [{"table": 1, "role": "r"}]}"#) == nil)
        #expect(decodePlan(#"{"limit": "five"}"#) == nil)
        #expect(decodePlan(#"{"projection": ["bare string"]}"#) == nil)
    }

    @Test func rejectsOutOfBoundsValues() {
        #expect(decodePlan(#"{"limit": 0}"#) == nil)
        #expect(decodePlan(#"{"limit": 1000001}"#) == nil)
        let tooMany = (0..<17).map { #"{"table": "t\#($0)", "role": "r"}"# }
            .joined(separator: ",")
        #expect(decodePlan(#"{"joins": [\#(tooMany)]}"#) == nil)
        let longText = String(repeating: "a", count: 201)
        #expect(decodePlan(#"{"grain": "\#(longText)"}"#) == nil)
    }

    @Test func rejectsEmptyAndNonObjectPlans() {
        #expect(decodePlan(#"{}"#) == nil)
        #expect(decodePlan(#""prose plan""#) == nil)
        #expect(decodePlan(#"[1, 2]"#) == nil)
        #expect(decodePlan(#"{"joins": [{"table": "", "role": "r"}]}"#) == nil)
        #expect(decodePlan(#"{"aggregation": [{"function": "COUNT", "alias": ""}]}"#) == nil)
    }

    // MARK: - Projection consistency

    @Test func acceptsMatchingProjectionAndAliases() {
        let result = evaluate(
            sql: """
                SELECT t.id, t.name, COUNT(m.id) AS wins
                FROM public.preseason_tool t
                JOIN public.preseason_match_config m ON m.tool_id = t.id
                GROUP BY t.id, t.name
                ORDER BY wins DESC
                LIMIT 5
                """,
            plan: plan(
                joins: ["public.preseason_tool", "public.preseason_match_config"],
                projection: [("t.id", ""), ("t.name", "")],
                aggregation: [("COUNT", "wins")],
                grouping: ["t.id", "t.name"],
                ordering: ["wins DESC"],
                limit: 5
            )
        )
        #expect(result.decision == .consistent)
        #expect(result.divergences.isEmpty)
    }

    @Test func flagsPlanColumnMissingFromSQL() {
        let result = evaluate(
            sql: "SELECT c.name FROM public.customers c",
            plan: plan(projection: [("c.name", ""), ("c.email", "")])
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains { $0.contains("email") && $0.contains("plan projects") })
    }

    @Test func flagsSQLColumnMissingFromPlan() {
        let result = evaluate(
            sql: "SELECT c.name, c.signup_date FROM public.customers c",
            plan: plan(projection: [("c.name", "")])
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains {
            $0.contains("signup_date") && $0.contains("plan projection does not list")
        })
    }

    @Test func matchesAliasedExpressionByAlias() {
        let result = evaluate(
            sql: "SELECT AVG(o.total_cents) AS average_order_value_cents FROM public.orders o",
            plan: plan(
                projection: [],
                aggregation: [("AVG", "average_order_value_cents")]
            )
        )
        #expect(result.decision == .consistent)
    }

    @Test func flagsUnaliasedAggregateAgainstPlannedAlias() {
        let result = evaluate(
            sql: "SELECT COUNT(*) FROM public.orders",
            plan: plan(aggregation: [("COUNT", "order_count")])
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains { $0.contains("order_count") })
    }

    @Test func projectionComparisonIgnoresQuotingAndCase() {
        let result = evaluate(
            sql: #"SELECT r."StartedAt" AS "StartedAt" FROM public.runs r"#,
            plan: plan(projection: [(#"r."StartedAt""#, "startedat")])
        )
        #expect(result.decision == .consistent)
    }

    @Test func distinctProjectionMatchesPlanColumn() {
        let result = evaluate(
            sql: "SELECT DISTINCT c.country FROM public.customers c",
            plan: plan(joins: ["public.customers"], projection: [("c.country", "")])
        )
        #expect(result.decision == .consistent)
    }

    @Test func skipsProjectionRuleWhenPlanHasNoProjection() {
        let result = evaluate(
            sql: "SELECT c.name, c.email FROM public.customers c",
            plan: plan(grouping: [], ordering: [], limit: nil, grain: "one row per customer")
        )
        #expect(result.decision == .consistent)
    }

    @Test func subqueryColumnsDoNotPolluteProjectionComparison() {
        let result = evaluate(
            sql: """
                SELECT u.email
                FROM public.app_user u
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.organization_membership m WHERE m.user_id = u.id
                )
                """,
            plan: plan(
                joins: ["public.app_user", "public.organization_membership"],
                projection: [("u.email", "")]
            )
        )
        #expect(result.decision == .consistent)
    }

    // MARK: - Aggregation rule

    @Test func flagsMissingAggregateFunctionCall() {
        let result = evaluate(
            sql: "SELECT o.total_cents AS revenue_cents FROM public.orders o",
            plan: plan(aggregation: [("SUM", "revenue_cents")])
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains { $0.contains("sum(") })
    }

    // MARK: - Join and evidence rules

    @Test func flagsPlanJoinTableAbsentFromSQL() {
        let result = evaluate(
            sql: "SELECT c.name FROM public.customers c",
            plan: plan(
                joins: ["public.customers", "public.orders"],
                projection: [("c.name", "")]
            )
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains { $0.contains("orders") && $0.contains("not referenced") })
    }

    @Test func flagsPlanJoinTableNotInspected() {
        let result = evaluate(
            sql: "SELECT c.name FROM public.customers c JOIN public.orders o ON o.customer_id = c.id",
            plan: plan(
                joins: ["public.customers", "public.orders"],
                projection: [("c.name", "")]
            ),
            inspected: ["public.customers"]
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.contains { $0.contains("orders") && $0.contains("not inspected") })
    }

    @Test func acceptsUnqualifiedInspectedTableSpelling() {
        let result = evaluate(
            sql: "SELECT c.name FROM customers c",
            plan: plan(joins: ["customers"], projection: [("c.name", "")]),
            inspected: ["public.customers"]
        )
        #expect(result.decision == .consistent)
    }

    // MARK: - Clause rules

    @Test func flagsMissingGroupByAndOrderBy() {
        let grouped = evaluate(
            sql: "SELECT c.country FROM public.customers c",
            plan: plan(joins: ["public.customers"], grouping: ["c.country"])
        )
        #expect(grouped.decision == .divergent)
        #expect(grouped.divergences.contains { $0.contains("GROUP BY") })

        let ordered = evaluate(
            sql: "SELECT c.country FROM public.customers c",
            plan: plan(joins: ["public.customers"], ordering: ["c.country"])
        )
        #expect(ordered.decision == .divergent)
        #expect(ordered.divergences.contains { $0.contains("ORDER BY") })
    }

    @Test func groupByInsideSubqueryDoesNotSatisfyTopLevelRule() {
        let result = evaluate(
            sql: """
                SELECT s.total FROM (
                    SELECT COUNT(*) AS total FROM public.orders GROUP BY customer_id
                ) s
                """,
            plan: plan(grouping: ["customer_id"])
        )
        #expect(result.decision == .divergent)
    }

    @Test func flagsLimitMismatchAndMissingLimit() {
        let mismatch = evaluate(
            sql: "SELECT t.name FROM public.preseason_tool t LIMIT 10",
            plan: plan(joins: ["public.preseason_tool"], projection: [("t.name", "")], limit: 5)
        )
        #expect(mismatch.decision == .divergent)
        #expect(mismatch.divergences.contains { $0.contains("limit 5") && $0.contains("LIMIT 10") })

        let missing = evaluate(
            sql: "SELECT t.name FROM public.preseason_tool t",
            plan: plan(joins: ["public.preseason_tool"], projection: [("t.name", "")], limit: 5)
        )
        #expect(missing.decision == .divergent)
        #expect(missing.divergences.contains { $0.contains("no top-level LIMIT") })
    }

    @Test func limitInsideStringLiteralIsIgnored() {
        let result = evaluate(
            sql: "SELECT t.name FROM public.preseason_tool t WHERE t.note = 'limit 9' LIMIT 5",
            plan: plan(joins: ["public.preseason_tool"], projection: [("t.name", "")], limit: 5)
        )
        #expect(result.decision == .consistent)
    }

    // MARK: - Divergence reporting

    @Test func reportsEveryDivergenceWithFirstAsReason() {
        let result = evaluate(
            sql: "SELECT c.name FROM public.customers c",
            plan: plan(
                joins: ["public.customers", "public.orders"],
                projection: [("c.email", "")],
                grouping: ["c.country"],
                limit: 3
            )
        )
        #expect(result.decision == .divergent)
        #expect(result.divergences.count >= 4)
        #expect(result.reason == result.divergences[0])
    }

    // MARK: - Helpers

    private func decodePlan(_ json: String) -> SchemaToolAgentStructuredQueryPlan? {
        guard
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        else { return nil }
        return SchemaToolAgentStructuredQueryPlan.decode(from: value)
    }

    private func plan(
        joins: [String] = [],
        projection: [(String, String)] = [],
        aggregation: [(String, String)] = [],
        grouping: [String] = [],
        ordering: [String] = [],
        limit: Int? = nil,
        grain: String = ""
    ) -> SchemaToolAgentStructuredQueryPlan {
        SchemaToolAgentStructuredQueryPlan(
            grain: grain,
            joins: joins.map { .init(table: $0, role: "join") },
            projection: projection.map { .init(expression: $0.0, alias: $0.1) },
            aggregation: aggregation.map { .init(function: $0.0, alias: $0.1) },
            grouping: grouping,
            ordering: ordering,
            limit: limit
        )
    }

    private func evaluate(
        sql: String,
        plan: SchemaToolAgentStructuredQueryPlan,
        inspected: Set<String> = []
    ) -> SchemaToolAgentPlanConsistencyResult {
        SchemaToolAgentPlanConsistencyPolicy.evaluate(
            sql: sql,
            plan: plan,
            inspectedTableNames: Set(inspected.map {
                SchemaToolAgentPlanConsistencyPolicy.normalizedIdentifier($0)
            })
        )
    }
}
