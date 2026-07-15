import Testing

@testable import WidenKit

@Suite("Schema tool agent clarification policy")
struct SchemaToolAgentClarificationPolicyTests {
    @Test func genericClarificationIsRejected() {
        let result = evaluate(
            question: "Show users",
            clarification: "Can you clarify?",
            evidence: evidence(columns: ["public.users.id", "public.users.name"])
        )

        #expect(result.decision == .genericClarification)
        #expect(result.evidenceSufficientForSQL == false)
    }

    @Test func clarificationAskingForDatabaseContextFactIsRejected() {
        let result = evaluate(
            question: "Show total paid revenue per customer",
            databaseContext: "Paid revenue means orders where status = 'paid'.",
            clarification: "Which status defines paid revenue?",
            evidence: evidence(columns: [
                "public.orders.id",
                "public.orders.status",
                "public.orders.customer_id",
            ])
        )

        #expect(result.decision == .asksForAlreadyKnownEvidence)
        #expect(result.databaseContextFactsUsed.contains("filter"))
        #expect(result.databaseContextFactsUsed.contains("metric"))
    }

    @Test func databaseContextDefinitionsAreAuthoritative() {
        let cases = [
            (
                question: "Which tools have the most wins in the last two weeks?",
                context: "Each evaluation with non-null winner_id records one win. Use evaluation createdAt.",
                clarification: "Should wins count rows where winner_id is not null?",
                columns: [
                    "public.evaluations.winner_id",
                    "public.evaluations.createdAt",
                    "public.tools.id",
                ]
            ),
            (
                question: "Active users by organization",
                context: "An active user is a user with active membership and last_seen_at after 2026-01-01.",
                clarification: "Which status defines active users?",
                columns: [
                    "public.users.id",
                    "public.users.last_seen_at",
                    "public.memberships.active",
                ]
            ),
            (
                question: "Seat usage by organization",
                context: "Seat usage is the count of active organization memberships.",
                clarification: "What metric defines seat usage?",
                columns: [
                    "public.organization_memberships.id",
                    "public.organization_memberships.active",
                    "public.organization_memberships.organization_id",
                ]
            ),
            (
                question: "Paid revenue by customer",
                context: "Paid revenue means orders where status = 'paid'.",
                clarification: "Which status defines paid revenue?",
                columns: [
                    "public.orders.id",
                    "public.orders.status",
                    "public.orders.customer_id",
                ]
            ),
        ]

        for testCase in cases {
            let result = evaluate(
                question: testCase.question,
                databaseContext: testCase.context,
                clarification: testCase.clarification,
                evidence: evidence(columns: testCase.columns)
            )

            #expect(result.decision == .asksForAlreadyKnownEvidence)
        }
    }

    @Test func metricAmbiguityIsAcceptedWhenContextDoesNotDefineMetric() {
        let result = evaluate(
            question: "Who are our best customers?",
            clarification: "Which metric should define best customers?",
            evidence: evidence(columns: [
                "public.customers.id",
                "public.customers.name",
                "public.orders.total_cents",
            ])
        )

        #expect(result.decision == .acceptableAmbiguity)
        #expect(result.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func winsAmbiguityIsNotResolvedByPlausibleWinnerSchema() {
        let result = evaluate(
            question: "Tools with the most wins in the last two weeks",
            clarification: "Should wins count rows where winner_id is not null?",
            evidence: evidence(columns: [
                "public.preseason_match_evaluation.winner_id",
                "public.preseason_match_evaluation.createdAt",
                "public.preseason_tool.id",
            ])
        )

        #expect(result.decision == .acceptableAmbiguity)
        #expect(result.evidenceSufficientForSQL == false)
        #expect(result.unresolvedDecisionKinds.contains(.metric))
    }

    @Test func relationshipAmbiguityIsAcceptedWhenMultipleJoinPathsRemain() {
        let result = evaluate(
            question: "Show revenue by account",
            clarification: "Which relationship path should join orders to accounts?",
            evidence: evidence(
                columns: [
                    "public.orders.id",
                    "public.orders.account_id",
                    "public.accounts.id",
                ],
                joinPaths: [
                    "public.orders.account_id->public.accounts.id",
                    "public.orders.billing_account_id->public.accounts.id",
                ]
            )
        )

        #expect(result.decision == .acceptableAmbiguity)
        #expect(result.unresolvedDecisionKinds.contains(.relationship))
    }

    @Test func statusAmbiguityIsAcceptedWhenNoInspectedStatusEvidenceExists() {
        let result = evaluate(
            question: "Show active users",
            clarification: "Which status value defines active users?",
            evidence: evidence(columns: [
                "public.users.id",
                "public.users.name",
            ])
        )

        #expect(result.decision == .acceptableAmbiguity)
        #expect(result.unresolvedDecisionKinds.contains(.statusOrFilter))
    }

    @Test func explicitPaidPhraseIsAnswerableWhenStatusColumnIsKnown() {
        let result = evaluate(
            question: "Show total paid revenue per customer",
            clarification: "Which status value defines paid revenue?",
            evidence: evidence(columns: [
                "public.orders.id",
                "public.orders.status",
                "public.orders.customer_id",
            ])
        )

        #expect(result.decision == .shouldAnswerWithSQL)
        #expect(result.evidenceSufficientForSQL)
    }

    @Test func withoutPatternIsAnswerableWhenJoinEvidenceExists() {
        let result = evaluate(
            question: "Which customers have never placed an order?",
            clarification: "Which relationship should I use?",
            evidence: evidence(
                columns: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                joinPaths: ["public.orders.customer_id->public.customers.id"]
            )
        )

        #expect(result.decision == .shouldAnswerWithSQL)
        #expect(result.evidenceSufficientForSQL)
    }

    @Test func explicitDateWindowIsAnswerableWhenOneTimestampColumnIsKnown() {
        let result = evaluate(
            question: "Average first-response time over the last 30 days",
            clarification: "Which date should define the time window?",
            evidence: evidence(columns: [
                "public.tickets.id",
                "public.tickets.first_response_at",
            ])
        )

        #expect(result.decision == .shouldAnswerWithSQL)
        #expect(result.evidenceSufficientForSQL)
    }

    private func evaluate(
        question: String,
        databaseContext: String = "",
        clarification: String,
        evidence: OpenRouterSchemaToolEvidenceSummary
    ) -> SchemaToolAgentClarificationPolicyResult {
        SchemaToolAgentClarificationPolicy.evaluate(
            originalQuestion: question,
            databaseContext: databaseContext,
            evidence: evidence,
            terminalAction: "clarify",
            terminalClarificationQuestion: clarification
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
