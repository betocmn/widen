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
                SELECT customer_id, SUM(total_cents) AS paid_revenue_cents
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
                SELECT c.country, AVG(o.total_cents) AS average_order_value_cents
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.country
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func personEntityRequiresEmailProjectionWhenKnown() {
        let missing = evaluate(
            question: "Which customers have never placed an order?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.name",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT c.id, c.name
                FROM public.customers AS c
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.orders AS o WHERE o.customer_id = c.id
                )
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))

        let covered = evaluate(
            question: "Which customers have never placed an order?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.name",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT c.id, c.email, c.name
                FROM public.customers AS c
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.orders AS o WHERE o.customer_id = c.id
                )
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func scalarPersonAggregateDoesNotRequireEmailProjection() {
        let covered = evaluate(
            question: "How many active users do we have?",
            evidence: evidence(columns: [
                "public.users.id",
                "public.users.email",
                "public.users.status",
            ]),
            sql: """
                SELECT COUNT(id) AS active_user_count
                FROM public.users
                WHERE status = 'active'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func whichPersonCountRankingRequiresEmailProjection() {
        let missing = evaluate(
            question: "Which customer has the highest order count?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                ORDER BY order_count DESC
                LIMIT 1
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func personListWithDroppedIdentifiersRequiresEmailProjection() {
        let missing = evaluate(
            question: "Which customers have never placed an order?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT COUNT(*) AS customer_count
                FROM public.customers AS c
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.orders AS o WHERE o.customer_id = c.id
                )
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func personListWithForeignKeyProjectionRequiresEmailProjection() {
        let missing = evaluate(
            question: "Which customers bought product X?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
                "public.orders.product_name",
            ]),
            sql: """
                SELECT o.customer_id
                FROM public.orders AS o
                WHERE o.product_name = 'Product X'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func groupedPersonMetricPrefersEmailLabelOverName() {
        let missing = evaluate(
            question: "Show total paid revenue per customer",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.name",
                "public.orders.customer_id",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT c.id, c.name, SUM(o.total_cents) AS paid_revenue_cents
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.id, c.name
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
        #expect(missing.missingSignals.contains("use email instead of name for grouped person/customer metric"))

        let covered = evaluate(
            question: "Show total paid revenue per customer",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.name",
                "public.orders.customer_id",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT c.id, c.email, SUM(o.total_cents) AS paid_revenue_cents
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.id, c.email
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func groupedHowManyPerPersonRequiresEmailProjection() {
        let missing = evaluate(
            question: "How many orders per user?",
            evidence: evidence(columns: [
                "public.users.id",
                "public.users.email",
                "public.orders.user_id",
            ]),
            sql: """
                SELECT user_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY user_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func listCustomersWithOrderCountRequiresEmailProjection() {
        let missing = evaluate(
            question: "List customers with their order count",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func whoTopCustomersRequiresEmailProjection() {
        let missing = evaluate(
            question: "Who are our top customers by revenue?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func centsMoneyAggregateMustPreserveUnitAndAlias() {
        let missing = evaluate(
            question: "Average paid order value by customer country",
            evidence: evidence(columns: [
                "public.customers.country",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT c.country, AVG(o.total_cents / 100.0) AS average_paid_order_value
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.country
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("preserve cents unit instead of dividing by 100"))
        #expect(missing.missingSignals.contains("cents-valued aggregate alias"))

        let covered = evaluate(
            question: "Average paid order value by customer country",
            evidence: evidence(columns: [
                "public.customers.country",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT c.country, AVG(o.total_cents) AS average_paid_order_value_cents
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

    @Test func laterContextCurrentDateAnchorRejectsMovingCurrentDate() {
        let missing = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Database was migrated on 2026-06-24. Current date is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func useBeforeUnrelatedContextDateDoesNotSelectMigrationAnchor() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Use the subscriptions table migrated on 2026-06-24. Current date is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-29'
                  AND expires_at < DATE '2026-06-29' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextWindowEndingDateRejectsMovingCurrentDate() {
        let missing = evaluate(
            question: "Subscriptions expiring in the reporting window",
            databaseContext: "Use the reporting window ending 2026-06-24.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at < CURRENT_DATE
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func contextDateBeforeCurrentDateWordingRejectsMovingCurrentDate() {
        let missing = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "2026-06-29 is the current date.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func useSubstringDoesNotSelectUnrelatedContextDateAnchor() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Users table migrated on 2026-06-24. Current date is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-29'
                  AND expires_at < DATE '2026-06-29' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func suffixTodayCueDoesNotSelectPreviousContextDate() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Database migrated on 2026-06-24. Today is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-29'
                  AND expires_at < DATE '2026-06-29' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func unrelatedContextDateDoesNotRejectMovingCurrentDate() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Database was migrated on 2026-06-24.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func anchoredExpiringListRejectsUnrequestedCreatedAtProjection() {
        let missing = evaluate(
            question: "Subscriptions expiring in the 30 days starting 2026-06-24",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.organization_id",
                "public.subscription.status",
                "public.subscription.expires_at",
                "public.subscription.created_at",
            ]),
            sql: """
                SELECT id, organization_id, status, expires_at, created_at
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-24'
                  AND expires_at < DATE '2026-06-24' + INTERVAL '30 days'
                LIMIT 100
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("remove unrequested projection created_at"))

        let covered = evaluate(
            question: "Subscriptions expiring in the 30 days starting 2026-06-24",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.organization_id",
                "public.subscription.status",
                "public.subscription.expires_at",
                "public.subscription.created_at",
            ]),
            sql: """
                SELECT id, organization_id, status, expires_at
                FROM public.subscription
                WHERE status = 'active'
                  AND expires_at >= DATE '2026-06-24'
                  AND expires_at < DATE '2026-06-24' + INTERVAL '30 days'
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func averageByCountryRejectsUnrequestedEntityColumns() {
        let missing = evaluate(
            question: "Average paid order value by customer country",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.name",
                "public.customers.country",
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT c.id, c.name, c.email, c.country,
                       AVG(o.total_cents) AS average_paid_order_value_cents
                FROM public.orders AS o
                JOIN public.customers AS c ON o.customer_id = c.id
                WHERE o.status = 'paid'
                GROUP BY c.id, c.name, c.email, c.country
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("remove unrequested projection id"))
        #expect(missing.missingSignals.contains("remove unrequested projection name"))
        #expect(missing.missingSignals.contains("remove unrequested projection email"))
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

    @Test func seatUsageRequiresSeatCountAlias() {
        let question = "Organizations using more seats than purchased"
        let context = "Seat usage is the count of active organization memberships."
        let evidence = evidence(columns: [
            "public.organization.id",
            "public.organization.seats_purchased",
            "public.organization_membership.organization_id",
            "public.organization_membership.status",
        ])
        let missing = evaluate(
            question: question,
            databaseContext: context,
            evidence: evidence,
            sql: """
                SELECT o.id, o.seats_purchased, COUNT(m.id) AS seat_usage
                FROM public.organization AS o
                JOIN public.organization_membership AS m ON m.organization_id = o.id
                WHERE m.status = 'active'
                GROUP BY o.id, o.seats_purchased
                HAVING COUNT(m.id) > o.seats_purchased
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("seat count alias such as used_seats or seat_count"))

        let covered = evaluate(
            question: question,
            databaseContext: context,
            evidence: evidence,
            sql: """
                SELECT o.id, o.seats_purchased, COUNT(m.id) AS used_seats
                FROM public.organization AS o
                JOIN public.organization_membership AS m ON m.organization_id = o.id
                WHERE m.status = 'active'
                GROUP BY o.id, o.seats_purchased
                HAVING COUNT(m.id) > o.seats_purchased
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

    @Test func quotedStatusPredicateSatisfiesStatusCoverage() {
        let covered = evaluate(
            question: "Show active users",
            evidence: evidence(columns: [
                "public.users.id",
                "public.users.Status",
            ]),
            sql: """
                SELECT u.id
                FROM public.users AS u
                WHERE u."Status" = 'active'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func quotedEqualityStatusPredicateSatisfiesStatusCoverage() {
        let covered = evaluate(
            question: "Show total paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders AS o
                WHERE o."Status" = 'paid'
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
        #expect(missing.missingSignals.contains("count aggregate alias containing count"))
        #expect(missing.missingSignals.contains("descending ORDER BY for top/frequent request"))
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))

        let wrongAlias = evaluate(
            question: question,
            evidence: evidence,
            sql: """
                SELECT c.id, c.name, COUNT(i.id) AS feedback_item_count
                FROM public.feedback_cluster AS c
                JOIN public.feedback_item AS i ON i.cluster_id = c.id
                GROUP BY c.id, c.name
                ORDER BY feedback_item_count DESC
                LIMIT 1
                """
        )

        #expect(wrongAlias.decision == .needsCorrection)
        #expect(wrongAlias.missingSignals.contains("feedback count alias"))

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

    @Test func topAllTimeStillRequiresLimit() {
        let missing = evaluate(
            question: "Top customers of all time",
            evidence: evidence(columns: [
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                ORDER BY order_count DESC
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))
    }

    @Test func allTopNStillRequiresLimit() {
        let missing = evaluate(
            question: "Show all top 10 customers by revenue",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY revenue_cents DESC
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))
    }

    @Test func allSpelledOutTopNStillRequiresLimit() {
        let missing = evaluate(
            question: "Show all top twenty customers by revenue",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY revenue_cents DESC
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))
    }

    @Test func everyEntityRankingDoesNotRequireLimit() {
        let covered = evaluate(
            question: "Show every customer by total spend, most to least",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_spend_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_spend_cents DESC
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func everyArbitraryEntityRankingDoesNotRequireLimit() {
        let covered = evaluate(
            question: "Show every product by total sales, most to least",
            evidence: evidence(columns: [
                "public.sales.product_id",
                "public.sales.total_cents",
            ]),
            sql: """
                SELECT product_id, SUM(total_cents) AS total_sales_cents
                FROM public.sales
                GROUP BY product_id
                ORDER BY total_sales_cents DESC
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func unrelatedContextDoesNotDefineProtectedMetric() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Data is refreshed nightly.",
            evidence: evidence(columns: [
                "public.accounts.id",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func descriptiveProtectedMetricContextDoesNotDefineMetric() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Healthy accounts are shown first on the dashboard.",
            evidence: evidence(columns: [
                "public.accounts.id",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func protectedMetricCueWithoutDefinitionStillClarifies() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Healthy accounts rank first on the dashboard.",
            evidence: evidence(columns: [
                "public.accounts.id",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func protectedMetricDefinitionDoesNotCrossSentenceBoundary() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Healthy accounts are shown first. Paid accounts have status = 'paid'.",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.accounts.status",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                WHERE status = 'paid'
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func contextWithProtectedMetricDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "A healthy account is one with active status.",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.accounts.status",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                WHERE status = 'active'
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextMetricDefinitionWithoutProtectedAdjectiveAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "Use lifetime revenue as the customer ranking metric.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS lifetime_revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY lifetime_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextMetricDefinitionForSubjectAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "Use total revenue as the ranking metric for customers.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextMetricDefinitionForArbitrarySubjectAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are the best products?",
            databaseContext: "Rank products by total revenue.",
            evidence: evidence(columns: [
                "public.sales.product_id",
                "public.sales.total_cents",
            ]),
            sql: """
                SELECT product_id, SUM(total_cents) AS total_revenue_cents
                FROM public.sales
                GROUP BY product_id
                ORDER BY total_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextRankSpendDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "Rank customers by total spend.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_spend_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_spend_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func protectedTermScopedRankDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "Best customers are ranked by total revenue.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func contextWithVerbBeforeProtectedMetricDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Accounts are healthy when status = 'active'.",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.accounts.status",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                WHERE status = 'active'
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func conciseProtectedMetricDefinitionsAllowCoverageChecks() {
        let question = "Which tools have the most wins?"
        let evidence = evidence(columns: [
            "public.tool_run.tool_id",
            "public.tool_run.winner_id",
        ])
        let sql = """
            SELECT tool_id, COUNT(*) AS win_count
            FROM public.tool_run
            WHERE winner_id IS NOT NULL
            GROUP BY tool_id
            ORDER BY win_count DESC
            LIMIT 10
            """

        let colonDefinition = evaluate(
            question: question,
            databaseContext: "wins: winner_id is not null.",
            evidence: evidence,
            sql: sql
        )

        #expect(colonDefinition.decision == .covered)

        let storesDefinition = evaluate(
            question: question,
            databaseContext: "A non-null winner_id stores a win.",
            evidence: evidence,
            sql: sql
        )

        #expect(storesDefinition.decision == .covered)
    }

    @Test func unrelatedProtectedTokenDoesNotBlockScopedMetricDefinition() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "The winner_id column tracks tournament outcomes. Rank customers by total revenue.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func scopedRankingMetricDoesNotDefineUnrelatedProtectedTerm() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Rank accounts by total spend.",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.orders.account_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT account_id, SUM(total_cents) AS total_spend_cents
                FROM public.orders
                GROUP BY account_id
                ORDER BY total_spend_cents DESC
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func entityListByCountryStillRequiresEmailProjection() {
        let missing = evaluate(
            question: "List customers by country with their email",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.country",
            ]),
            sql: """
                SELECT id, country
                FROM public.customers
                ORDER BY country
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func bareCountryPersonEmailRequestRequiresEmailProjection() {
        let missing = evaluate(
            question: "Customers by country with their email",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.country",
            ]),
            sql: """
                SELECT country, COUNT(*) AS customer_count
                FROM public.customers
                GROUP BY country
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func bareTopPersonQueryRequiresEmailProjection() {
        let missing = evaluate(
            question: "Top customers of all time",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                ORDER BY order_count DESC
                LIMIT 10
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func whatPersonStatusQueryRequiresEmailProjection() {
        let missing = evaluate(
            question: "What customers are active?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.status",
            ]),
            sql: """
                SELECT id
                FROM public.customers
                WHERE status = 'active'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func scopedRankingMetricDefinesImportantSubject() {
        let covered = evaluate(
            question: "What is our most important feedback cluster?",
            databaseContext: "Rank feedback clusters by total feedback count.",
            evidence: evidence(columns: [
                "public.feedback_item.cluster_id",
                "public.feedback_cluster.id",
            ]),
            sql: """
                SELECT cluster_id, COUNT(*) AS feedback_count
                FROM public.feedback_item
                GROUP BY cluster_id
                ORDER BY feedback_count DESC
                LIMIT 1
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func nounPhrasePersonRequestRequiresEmailProjection() {
        let missing = evaluate(
            question: "Customers with their order count",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func unrelatedProtectedDefinitionDoesNotSuppressClarification() {
        let missing = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "A non-null winner_id stores a win.",
            evidence: evidence(columns: [
                "public.accounts.id",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
        #expect(missing.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func countStyleProtectedMetricDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Which tools have the most wins?",
            databaseContext: "Wins count evaluations where winner_id is not null.",
            evidence: evidence(columns: [
                "public.tool_run.tool_id",
                "public.tool_run.winner_id",
            ]),
            sql: """
                SELECT tool_id, COUNT(*) AS win_count
                FROM public.tool_run
                WHERE winner_id IS NOT NULL
                GROUP BY tool_id
                ORDER BY win_count DESC
                LIMIT 10
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func qualifiedCurrentDateAnchorRejectsMovingCurrentDate() {
        let missing = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "The current date for this fixture is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func giveMeEveryEntityRankingDoesNotRequireLimit() {
        let covered = evaluate(
            question: "Give me every customer by total spend, most to least",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_spend_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_spend_cents DESC
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func looseAsOfCueDoesNotSelectUnrelatedContextDate() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "As of nightly refresh, the database was migrated on 2026-06-24. Current date is 2026-06-29.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-29'
                  AND expires_at < DATE '2026-06-29' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)

        let missing = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "As of 2026-06-24, subscription data is complete.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func statusPredicateValueMustMatchRequestedStatus() {
        let missing = evaluate(
            question: "Show paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders
                WHERE status = 'failed'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for paid"))
    }

    @Test func statusPredicateDoesNotSubstringMatchRequestedStatus() {
        let missing = evaluate(
            question: "Show paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders AS o
                WHERE o."Status" = 'unpaid'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("predicate for paid"))
    }

    @Test func nullableForeignKeyWithoutPatternIsCoveredByNullFilter() {
        let covered = evaluate(
            question: "Show feedback items without a cluster",
            evidence: evidence(columns: [
                "public.feedback_item.id",
                "public.feedback_item.cluster_id",
            ]),
            sql: """
                SELECT id
                FROM public.feedback_item
                WHERE cluster_id IS NULL
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func nullableForeignKeyWithoutPatternRejectsMissingKeyProjection() {
        let missing = evaluate(
            question: "Show feedback items without a cluster",
            evidence: evidence(columns: [
                "public.feedback_item.id",
                "public.feedback_item.body",
                "public.feedback_item.created_at",
                "public.feedback_item.cluster_id",
            ]),
            sql: """
                SELECT id, body, created_at, cluster_id
                FROM public.feedback_item
                WHERE cluster_id IS NULL
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("remove unrequested projection cluster_id"))
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

    @Test func explicitAllEntityRankingDoesNotRequireLimit() {
        let covered = evaluate(
            question: "Show every product by total sales, most to least",
            evidence: evidence(columns: [
                "public.orders.product_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT product_id, SUM(total_cents) AS total_sales_cents
                FROM public.orders
                GROUP BY product_id
                ORDER BY total_sales_cents DESC
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func topNAcrossAllAccountsStillRequiresLimit() {
        let missing = evaluate(
            question: "Top 10 customers across all accounts",
            evidence: evidence(columns: [
                "public.orders.customer_id",
            ]),
            sql: """
                SELECT customer_id, COUNT(*) AS order_count
                FROM public.orders
                GROUP BY customer_id
                ORDER BY order_count DESC
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("LIMIT for top/frequent request"))
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

    @Test func adjectiveLedPersonListRequiresEmailProjection() {
        let missing = evaluate(
            question: "Active customers",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.email",
                "public.customers.status",
            ]),
            sql: """
                SELECT id
                FROM public.customers
                WHERE status = 'active'
                LIMIT 100
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("email projection for person/customer entity"))
    }

    @Test func allOfTheEntityRankingDoesNotRequireLimit() {
        let covered = evaluate(
            question: "Return all of the customers by total spend, most to least",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS total_spend_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY total_spend_cents DESC
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func prefixLikeStatusPredicateCoversRequestedStatus() {
        let covered = evaluate(
            question: "Show paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders
                WHERE status LIKE 'paid%'
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func rankingMentionWithoutConcreteMetricStillRequiresClarification() {
        let missing = evaluate(
            question: "Who are our best customers?",
            databaseContext: "The customer ranking page shows customer profiles.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
    }

    @Test func contextAnchorAsPhraseProvidesExplicitAnchor() {
        let covered = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Treat the evaluation anchor as 2026-06-24.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= DATE '2026-06-24'
                  AND expires_at < DATE '2026-06-24' + INTERVAL '30 days'
                """
        )

        #expect(covered.decision == .covered)

        let missing = evaluate(
            question: "Subscriptions expiring in the next 30 days",
            databaseContext: "Treat the evaluation anchor as 2026-06-24.",
            evidence: evidence(columns: [
                "public.subscription.id",
                "public.subscription.expires_at",
            ]),
            sql: """
                SELECT id
                FROM public.subscription
                WHERE expires_at >= CURRENT_DATE
                  AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                """
        )

        #expect(missing.decision == .needsCorrection)
        #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
    }

    @Test func getPersonListRequiresEmailProjection() {
        for question in ["Get active customers", "Return customers", "Display users"] {
            let missing = evaluate(
                question: question,
                evidence: evidence(columns: [
                    "public.customers.id",
                    "public.customers.email",
                    "public.customers.status",
                ]),
                sql: """
                    SELECT id
                    FROM public.customers
                    WHERE status = 'active'
                    LIMIT 100
                    """
            )

            #expect(missing.decision == .needsCorrection)
            #expect(missing.missingSignals.contains("email projection for person/customer entity"))
        }
    }

    @Test func conditionBeforeProtectedTermDefinesMetric() {
        let covered = evaluate(
            question: "Which tools have the most wins?",
            databaseContext: "An evaluation with a non-null winner_id is a win.",
            evidence: evidence(columns: [
                "public.tool_run.tool_id",
                "public.tool_run.winner_id",
            ]),
            sql: """
                SELECT tool_id, COUNT(*) AS win_count
                FROM public.tool_run
                WHERE winner_id IS NOT NULL
                GROUP BY tool_id
                ORDER BY win_count DESC
                LIMIT 10
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func anyArrayStatusPredicateCoversRequestedStatus() {
        let covered = evaluate(
            question: "Show paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders
                WHERE status = ANY(ARRAY['paid'])
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func useAsMetricDefinitionWithProtectedTermAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Who are our best customers?",
            databaseContext: "For best customers, use lifetime revenue as the ranking metric.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS lifetime_revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY lifetime_revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func equalsFormAnchorRejectsMovingCurrentDate() {
        for context in ["Current date = 2026-06-29.", "Today = 2026-06-29."] {
            let missing = evaluate(
                question: "Subscriptions expiring in the next 30 days",
                databaseContext: context,
                evidence: evidence(columns: [
                    "public.subscription.id",
                    "public.subscription.expires_at",
                ]),
                sql: """
                    SELECT id
                    FROM public.subscription
                    WHERE expires_at >= CURRENT_DATE
                      AND expires_at < CURRENT_DATE + INTERVAL '30 days'
                    """
            )

            #expect(missing.decision == .needsCorrection)
            #expect(missing.missingSignals.contains("explicit date/time anchor instead of moving current time"))
        }
    }

    @Test func haveMetricDefinitionAllowsCoverageChecks() {
        let covered = evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "Healthy accounts have status = 'active'.",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.accounts.status",
            ]),
            sql: """
                SELECT id
                FROM public.accounts
                WHERE status = 'active'
                LIMIT 100
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func braceArrayStatusPredicateCoversRequestedStatus() {
        let covered = evaluate(
            question: "Show paid revenue",
            evidence: evidence(columns: [
                "public.orders.status",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT SUM(total_cents) AS paid_revenue_cents
                FROM public.orders
                WHERE status = ANY('{paid,refunded}')
                """
        )

        #expect(covered.decision == .covered)
    }

    @Test func incidentalContextOverlapStillRequiresClarification() {
        let missing = evaluate(
            question: "Who are our best customers in the last two weeks?",
            databaseContext: "Rank products by revenue in the last two weeks.",
            evidence: evidence(columns: [
                "public.orders.customer_id",
                "public.orders.total_cents",
            ]),
            sql: """
                SELECT customer_id, SUM(total_cents) AS revenue_cents
                FROM public.orders
                GROUP BY customer_id
                ORDER BY revenue_cents DESC
                LIMIT 100
                """
        )

        #expect(missing.decision == .mustClarify)
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
