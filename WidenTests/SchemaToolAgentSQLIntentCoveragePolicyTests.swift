import Testing

@testable import WidenKit

@Suite("Schema tool agent SQL intent coverage policy")
struct SchemaToolAgentSQLIntentCoveragePolicyTests {
    @Test func paidRevenueRequiresPaidStatusPredicate() {
        let question = "Total paid revenue by customer"
        let missing = evaluate(
            question: question,
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS paid_revenue
                FROM public.orders
                GROUP BY customer_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for paid"))

        let covered = evaluate(
            question: question,
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS paid_revenue
                FROM public.orders
                WHERE status = 'paid'
                GROUP BY customer_id
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func missingRowsRequiresAntiJoin() {
        let question = "Which customers have never placed an order?"
        let missing = evaluate(
            question: question,
            evidence: evidence(
                columns: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                joinPaths: ["public.orders.customer_id->public.customers.id"]
            ),
            sql: """
                SELECT c.id
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("anti-join or NOT EXISTS for missing rows"))

        let covered = evaluate(
            question: question,
            evidence: evidence(
                columns: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                joinPaths: ["public.orders.customer_id->public.customers.id"]
            ),
            sql: """
                SELECT c.id
                FROM public.customers AS c
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.orders AS o WHERE o.customer_id = c.id
                )
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func averageOrderValueByCountryRequiresPaidFilterAndGroup() {
        let question = "Average paid order value by country"
        let evidence = evidence(columns: [
            "public.customers.country",
            "public.orders.customer_id",
            "public.orders.status",
            "public.orders.total_cents",
        ])
        let missing = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT c.country, AVG(o.total_cents) AS average_order_value
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                GROUP BY c.country
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for paid"))

        let covered = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT c.country, AVG(o.total_cents) AS average_order_value
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.country
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func explicitStartingDateRejectsMovingCurrentDate() {
        let question = "Subscriptions expiring in the 30 days starting 2026-06-24"
        let evidence = evidence(columns: [
            "public.subscription.id",
            "public.subscription.expires_at",
        ])
        let missing = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.semanticMismatchCategory == "moving current-time used for anchored question")

        let covered = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-24'
                  AND expires_at < DATE '2026-06-24' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func activeUsersByOrgRequiresContextPredicates() {
        let question = "Active users by organization"
        let context = "An active user is a user with active membership and last_seen_at on or after 2026-06-01."
        let evidence = evidence(columns: [
            "public.app_user.id",
            "public.app_user.last_seen_at",
            "public.organization_membership.user_id",
            "public.organization_membership.organization_id",
            "public.organization_membership.active",
        ])
        let missing = evaluate(
            question: question,
            databaseContext: context,
            evidence: evidence,
            sql: """
                SELECT m.organization_id, COUNT(*) AS active_users
                FROM public.app_user AS u
                JOIN public.organization_membership AS m ON m.user_id = u.id
                GROUP BY m.organization_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("active membership predicate from database context"))
        #expect(missing.missingSignals.contains("last_seen_at predicate from database context"))

        let covered = evaluate(
            question: question,
            databaseContext: context,
            evidence: evidence,
            sql: """
                SELECT m.organization_id, COUNT(*) AS active_users
                FROM public.app_user AS u
                JOIN public.organization_membership AS m ON m.user_id = u.id
                WHERE m.active = TRUE
                  AND u.last_seen_at >= DATE '2026-06-01'
                GROUP BY m.organization_id
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func unresolvedByAssigneeRequiresUnresolvedPredicate() {
        let question = "Unresolved tickets by assignee"
        let evidence = evidence(columns: [
            "public.support_ticket.assignee_id",
            "public.support_ticket.status",
        ])
        let missing = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT assignee_id, COUNT(*) AS tickets
                FROM public.support_ticket
                GROUP BY assignee_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for unresolved"))

        let covered = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT assignee_id, COUNT(*) AS unresolved_tickets
                FROM public.support_ticket
                WHERE status = 'unresolved'
                GROUP BY assignee_id
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func frequentClusterRequiresCountOrderLimit() {
        let question = "What is the most frequent feedback cluster?"
        let evidence = evidence(columns: [
            "public.feedback_item.cluster_id",
            "public.feedback_cluster.id",
            "public.feedback_cluster.name",
        ])
        let missing = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT c.id, c.name
                FROM public.feedback_cluster AS c
                JOIN public.feedback_item AS i ON i.cluster_id = c.id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("aggregate count for top/frequent request"))
        #expect(missing.missingSignals.contains("descending ORDER BY for top/frequent request"))
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))

        let covered = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT c.id, c.name, COUNT(*) AS feedback_count
                FROM public.feedback_cluster AS c
                JOIN public.feedback_item AS i ON i.cluster_id = c.id
                GROUP BY c.id, c.name
                ORDER BY feedback_count DESC
                LIMIT 1
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func mostRecentDoesNotRequireAggregateTopCount() {
        let covered = evaluate(
            question: "Show the 10 most recent orders",
            evidence: evidence(columns: [
                "public.orders.id",
                "public.orders.created_at",
            ]),
            sql: """
                SELECT id, created_at
                FROM public.orders
                ORDER BY created_at DESC
                LIMIT 10
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func verifiedToolsRequireVerifiedBooleanPredicate() {
        let question = "Show verified tools"
        let evidence = evidence(columns: [
            "public.preseason_tool.id",
            "public.preseason_tool.name",
            "public.preseason_tool.is_verified",
        ])
        let missing = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT id, name
                FROM public.preseason_tool
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for verified"))

        let covered = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT id, name
                FROM public.preseason_tool
                WHERE is_verified = TRUE
                """
        )

        #expect(covered.decision == .covered)
    }

    private func evaluate(
        question: String,
        databaseContext: String = "",
        evidence: OpenRouterSchemaToolEvidenceSummary,
        sql: String
    ) -> SchemaToolAgentSQLIntentCoverageResult {
        SchemaToolAgentSQLIntentCoveragePolicy.evaluate(
            question: question,
            databaseContext: databaseContext,
            evidence: evidence,
            sql: sql
        )
    }

    private func evidence(
        columns: [String],
        joinPaths: [String] = []
    ) -> OpenRouterSchemaToolEvidenceSummary {
        OpenRouterSchemaToolEvidenceSummary(
            searched: true,
            describedTableIDs: ["public.example"],
            exposedColumnIDs: columns,
            exposedForeignKeyPathIDs: joinPaths,
            inspectedConstraintToolUsed: false,
            inspectedValueToolUsed: false
        )
    }
}
