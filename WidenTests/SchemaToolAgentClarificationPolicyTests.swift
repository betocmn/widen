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

    @Test(arguments: [
        (
            question: "Who are our best customers?",
            clarification: "Which metric should define this request?",
            columns: ["public.customers.id", "public.orders.customer_id"],
            joinPath: "public.orders.customer_id->public.customers.id"
        ),
        (
            question: "Which feedback clusters are important?",
            clarification: "Which metric should define important feedback clusters?",
            columns: ["public.feedback_clusters.id", "public.feedback_items.cluster_id"],
            joinPath: "public.feedback_items.cluster_id->public.feedback_clusters.id"
        ),
        (
            question: "Which accounts are healthy?",
            clarification: "Which metric should define healthy accounts?",
            columns: ["public.accounts.id", "public.account_memberships.account_id"],
            joinPath: "public.account_memberships.account_id->public.accounts.id"
        ),
        (
            question: "Tools with the most wins in the last two weeks",
            clarification: "What should count as one win?",
            columns: [
                "public.preseason_tool.id",
                "public.preseason_match_evaluation.winner_id",
            ],
            joinPath:
                "public.preseason_match_evaluation.winner_id->public.preseason_tool.id"
        ),
    ])
    func protectedMetricCandidateRequiresIntentAndClarificationPolicyAgreement(
        question: String,
        clarification: String,
        columns: [String],
        joinPath: String
    ) throws {
        let relationshipTables = joinPath
            .split(separator: "->")
            .compactMap { endpoint -> String? in
                guard let separator = endpoint.lastIndex(of: ".") else { return nil }
                return String(endpoint[..<separator])
            }
        let evidence = evidence(
            columns: columns,
            joinPaths: [joinPath],
            describedTableIDs: relationshipTables
        )

        for repeatIndex in 1...3 {
            let candidate = try #require(
                SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
                    question: question,
                    databaseContext: "",
                    evidence: evidence,
                    sql: "SELECT 1"
                )
            )

            #expect(repeatIndex >= 1)
            #expect(candidate.question == clarification)
            #expect(candidate.intentCoverage.decision == .mustClarify)
            #expect(candidate.intentCoverage.unresolvedDecisionKinds == [.metric])
            #expect(candidate.clarificationPolicy.decision == .acceptableAmbiguity)
            #expect(candidate.clarificationPolicy.unresolvedDecisionKinds.contains(.metric))
        }
    }

    @Test func protectedMetricCandidateRequiresInspectedEvidence() {
        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: OpenRouterSchemaToolEvidenceSummary(),
            sql: ""
        )

        #expect(candidate == nil)
    }

    @Test func protectedMetricCandidateRequiresRelationalSchemaEvidence() {
        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: evidence(columns: [
                "public.accounts.id",
                "public.accounts.status",
            ]),
            sql: ""
        )

        #expect(candidate == nil)
    }

    @Test func protectedMetricCandidateDefersToDefinedMetricContext() {
        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "A healthy account is one with active status.",
            evidence: evidence(
                columns: [
                    "public.accounts.id",
                    "public.accounts.status",
                    "public.account_memberships.account_id",
                ],
                joinPaths: [
                    "public.account_memberships.account_id->public.accounts.id"
                ],
                describedTableIDs: ["public.accounts", "public.account_memberships"]
            ),
            sql: "SELECT id FROM public.accounts WHERE status = 'active'"
        )

        #expect(candidate == nil)
    }

    @Test func protectedMetricCandidateRejectsInconsistentRelationshipEvidence() {
        let columns = [
            "public.accounts.id",
            "public.account_memberships.account_id",
        ]
        let joinPaths = [
            "public.account_memberships.account_id->public.accounts.id"
        ]

        let undescribedEndpoint = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: evidence(
                columns: columns,
                joinPaths: joinPaths,
                describedTableIDs: ["public.accounts"]
            ),
            sql: ""
        )
        let unexposedEndpoint = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: evidence(
                columns: ["public.accounts.id"],
                joinPaths: joinPaths,
                describedTableIDs: ["public.accounts", "public.account_memberships"]
            ),
            sql: ""
        )

        #expect(undescribedEndpoint == nil)
        #expect(unexposedEndpoint == nil)
    }

    @Test func protectedMetricCandidateRejectsQuestionIrrelevantRelationshipEvidence() {
        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: evidence(
                columns: ["public.entities.id", "public.events.entity_id"],
                joinPaths: ["public.events.entity_id->public.entities.id"],
                describedTableIDs: ["public.entities", "public.events"]
            ),
            sql: ""
        )

        #expect(candidate == nil)
    }

    @Test func protectedMetricCandidateDoesNotTreatSharedSchemaNameAsRelationshipEvidence() {
        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which public accounts are healthy?",
            databaseContext: "",
            evidence: evidence(
                columns: ["public.entities.id", "public.events.entity_id"],
                joinPaths: ["public.events.entity_id->public.entities.id"],
                describedTableIDs: ["public.entities", "public.events"]
            ),
            sql: ""
        )

        #expect(candidate == nil)
    }

    @Test func protectedMetricCandidateAcceptsACompleteSearchedRelationship() {
        let relationshipEvidence = evidence(
            columns: [
                "public.organization.id",
                "public.organization_membership.organization_id",
            ],
            joinPaths: [
                "public.organization_membership.organization_id->public.organization.id"
            ],
            describedTableIDs: [
                "public.organization",
                "public.organization_membership",
            ],
            questionRelevantSearchedTableIDs: [
                "public.organization",
                "public.organization_membership",
            ]
        )

        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: relationshipEvidence,
            sql: ""
        )

        #expect(candidate?.question == "Which metric should define healthy accounts?")
    }

    @Test func protectedMetricCandidateRejectsAnIncompleteSearchedRelationship() {
        let relationshipEvidence = evidence(
            columns: [
                "public.organization.id",
                "public.organization_membership.organization_id",
            ],
            joinPaths: [
                "public.organization_membership.organization_id->public.organization.id"
            ],
            describedTableIDs: [
                "public.organization",
                "public.organization_membership",
            ],
            questionRelevantSearchedTableIDs: ["public.organization"]
        )

        let candidate = SchemaToolAgentProtectedMetricClarificationPolicy.evaluate(
            question: "Which accounts are healthy?",
            databaseContext: "",
            evidence: relationshipEvidence,
            sql: ""
        )

        #expect(candidate == nil)
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
        joinPaths: [String] = [],
        describedTableIDs: [String] = ["public.example"],
        questionRelevantSearchedTableIDs: [String] = []
    ) -> OpenRouterSchemaToolEvidenceSummary {
        OpenRouterSchemaToolEvidenceSummary(
            searched: true,
            questionRelevantSearchedTableIDs: questionRelevantSearchedTableIDs,
            describedTableIDs: describedTableIDs,
            exposedColumnIDs: columns,
            exposedForeignKeyPathIDs: joinPaths,
            inspectedConstraintToolUsed: false,
            inspectedValueToolUsed: false
        )
    }
}
