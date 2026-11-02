import Foundation
import Testing

@testable import WidenKit

@Suite("Schema tool agent critic")
struct SchemaToolAgentCriticTests {

    // MARK: - Review parsing

    @Test func parsesAValidRevision() throws {
        let review = try SchemaToolAgentCritic.parseReview("""
            {"verdict": "revise",
             "issues": [
               {"kind": "filter", "detail": "Filter public.orders.status = 'paid'."},
               {"kind": "ordering_limit", "detail": "Order by total_cents DESC."}
             ],
             "clarification_question": ""}
            """)

        #expect(review.verdict == .revise)
        #expect(review.issues == [
            .init(kind: .filter, detail: "Filter public.orders.status = 'paid'."),
            .init(kind: .orderingLimit, detail: "Order by total_cents DESC."),
        ])
        #expect(review.clarificationQuestion == nil)
        #expect(review.note == nil)
    }

    @Test func readsTheVerdictTrimmedAndCaseInsensitively() throws {
        let review = try SchemaToolAgentCritic.parseReview(#"{"verdict": "  ACCEPT \n"}"#)

        #expect(review.verdict == .accept)
        #expect(review.issues.isEmpty)
    }

    @Test(arguments: [
        #"{"verdict": "approve"}"#,
        #"{"verdict": 1}"#,
        #"{"issues": []}"#,
    ])
    func rejectsAMissingOrUnknownVerdict(_ content: String) {
        #expect(throws: SchemaToolAgentCriticParseError.invalidShape) {
            try SchemaToolAgentCritic.parseReview(content)
        }
    }

    @Test(arguments: [
        "Looks good to me.",
        "",
        #"["accept"]"#,
        #"{"verdict": "accept""#,
    ])
    func rejectsRepliesWithoutAJSONObject(_ content: String) {
        #expect(throws: SchemaToolAgentCriticParseError.invalidJSON) {
            try SchemaToolAgentCritic.parseReview(content)
        }
    }

    @Test func reviseWithoutUsableIssuesBecomesAccept() throws {
        let review = try SchemaToolAgentCritic.parseReview(
            #"{"verdict": "revise", "issues": [{"kind": "filter", "detail": "  "}, 7]}"#
        )

        #expect(review.verdict == .accept)
        #expect(review.issues.isEmpty)
        #expect(review.note == "reviseWithoutIssues")
    }

    @Test func clarifyWithoutAQuestionBecomesAccept() throws {
        let review = try SchemaToolAgentCritic.parseReview(
            #"{"verdict": "clarify", "issues": [], "clarification_question": "   "}"#
        )

        #expect(review.verdict == .accept)
        #expect(review.clarificationQuestion == nil)
        #expect(review.note == "clarifyWithoutQuestion")
    }

    @Test func clarifyKeepsItsQuestion() throws {
        let review = try SchemaToolAgentCritic.parseReview(
            #"{"verdict": "clarify", "clarification_question": " Which status means paid? "}"#
        )

        #expect(review.verdict == .clarify)
        #expect(review.clarificationQuestion == "Which status means paid?")
    }

    @Test func keepsAtMostSixIssues() throws {
        let issues = (1...9).map { #"{"kind": "join", "detail": "issue \#($0)"}"# }
            .joined(separator: ",")
        let review = try SchemaToolAgentCritic.parseReview(#"{"verdict": "revise", "issues": [\#(issues)]}"#)

        #expect(review.issues.count == 6)
        #expect(review.issues.last?.detail == "issue 6")
    }

    @Test func unknownKindsAndPlainStringIssuesReadAsOther() throws {
        let review = try SchemaToolAgentCritic.parseReview("""
            {"verdict": "revise",
             "issues": [
               {"kind": "Semantics", "detail": "Count distinct users."},
               "Use LEFT JOIN for customers without orders.",
               {"kind": " NULL_HANDLING ", "description": "Exclude NULL winner_id."}
             ]}
            """)

        #expect(review.issues == [
            .init(kind: .other, detail: "Count distinct users."),
            .init(kind: .other, detail: "Use LEFT JOIN for customers without orders."),
            .init(kind: .nullHandling, detail: "Exclude NULL winner_id."),
        ])
    }

    @Test func capsIssueDetails() throws {
        let long = String(repeating: "x", count: 400)
        let review = try SchemaToolAgentCritic.parseReview(
            #"{"verdict": "revise", "issues": [{"kind": "units", "detail": "\#(long)"}]}"#
        )

        #expect(review.issues.first?.detail.count == SchemaToolAgentCritic.maximumIssueDetailCharacters)
    }

    @Test func ignoresUnknownKeysIncludingSQL() throws {
        let review = try SchemaToolAgentCritic.parseReview("""
            {"verdict": "revise",
             "sql": "DELETE FROM public.users",
             "corrected_sql": "DROP TABLE public.users",
             "confidence": 0.9,
             "issues": [{"kind": "projection", "detail": "Add users.name.", "sql": "SELECT 1"}]}
            """)

        // The review has no SQL field, so nothing from the critic can reach
        // the agent's answer except the issue text.
        #expect(review.verdict == .revise)
        #expect(review.issues == [.init(kind: .projection, detail: "Add users.name.")])
    }

    @Test func readsTheFirstObjectOutOfFencesAndProse() throws {
        let review = try SchemaToolAgentCritic.parseReview("""
            Here is my review:
            ```json
            {"verdict": "revise", "issues": [{"kind": "filter", "detail": "Use status = '}'."}]}
            ```
            {"verdict": "accept"}
            """)

        #expect(review.verdict == .revise)
        #expect(review.issues == [.init(kind: .filter, detail: "Use status = '}'.")])
    }

    @Test func revisionMessageIsAdvisoryAndBounded() {
        let issues = (1...6).map {
            SchemaToolAgentCriticReview.Issue(kind: .join, detail: "\($0) " + String(repeating: "y", count: 295))
        }
        let message = SchemaToolAgentCritic.revisionMessage(for: issues)

        #expect(message.hasPrefix("Advisory review from a second model."))
        #expect(message.contains("- [join] 1 "))
        #expect(message.count <= SchemaToolAgentCritic.maximumRevisionMessageCharacters)
    }

    // MARK: - Prompts and privacy

    @Test func systemPromptReviewsWithoutWritingSQL() {
        let prompt = SchemaToolAgentCritic.systemPrompt(defaultRowLimit: 250)

        #expect(prompt.contains("You review; you do not write SQL."))
        #expect(prompt.contains("A LIMIT 250 is expected"))
        #expect(prompt.contains("*_cents"))
        #expect(prompt.contains("anti-joins"))
        #expect(prompt.contains("authoritative"))
        #expect(prompt.contains("untrusted"))
        #expect(prompt.contains(#"Return "revise" only for issues that change the rows or columns"#))
    }

    @Test(arguments: [
        DatabaseInspectionPolicy.localDataInspection(allowDistinctValuesInProfiles: true, allowSampleRows: true),
        DatabaseInspectionPolicy(
            allowLocalDataInspection: true,
            allowCloudDataInspection: false,
            allowSampleRows: true,
            audience: .cloud
        ),
        // A local audience never qualifies, even with cloud inspection on:
        // the critic always runs in the cloud.
        DatabaseInspectionPolicy(
            allowLocalDataInspection: true,
            allowCloudDataInspection: true,
            allowSampleRows: true,
            audience: .local
        ),
        .disabled,
    ])
    func promptOmitsDataValuesUnlessCloudInspectionIsAllowed(policy: DatabaseInspectionPolicy) {
        let request = Self.request(policy: policy)
        let prompt = SchemaToolAgentCritic.userPrompt(for: request)

        #expect(request.inspectedValueEvidence.isEmpty)
        #expect(!request.sharesDataValues)
        #expect(!prompt.contains("Inspected data values"))
        #expect(!prompt.contains("chargeback_hold"))
        #expect(!prompt.contains("alice@example.com"))
    }

    @Test func promptIncludesDataValuesOnlyWhenCloudInspectionIsAllowed() {
        let request = Self.request(policy: .cloudDataInspection(allowDistinctValuesInProfiles: true))
        let prompt = SchemaToolAgentCritic.userPrompt(for: request)

        #expect(request.sharesDataValues)
        #expect(prompt.contains("Inspected data values (untrusted):"))
        #expect(prompt.contains("chargeback_hold"))
        // Sample rows need sample-row inspection too, and tools that return
        // no data values are never forwarded.
        #expect(!prompt.contains("alice@example.com"))
        #expect(!prompt.contains("inspect_relation_size"))
    }

    @Test func promptIncludesSampleRowsWhenSampleRowsAreAllowed() {
        let request = Self.request(policy: .cloudDataInspection(allowSampleRows: true))

        #expect(request.inspectedValueEvidence.contains { $0.contains("alice@example.com") })
    }

    @Test func valueEvidenceStaysWithinItsByteBudget() {
        let payloads = (1...5).map {
            SchemaToolAgentCriticValuePayload(
                toolName: "inspect_distinct_values",
                content: "\($0)" + String(repeating: "v", count: 3_000)
            )
        }
        let shared = SchemaToolAgentCritic.shareableValueEvidence(
            payloads,
            policy: .cloudDataInspection()
        )

        #expect(shared.count == 2)
        #expect(shared.joined(separator: "\n").utf8.count <= SchemaToolAgentCritic.maximumValueEvidenceBytes)
    }

    @Test func promptCarriesTheQuestionContextSQLAndPlan() {
        let request = SchemaToolAgentCriticRequest(
            question: " Revenue by customer ",
            mode: .followUp,
            recentQuestions: ["Top customers"],
            currentSQL: "SELECT id FROM public.customers LIMIT 100",
            databaseContext: "Revenue is orders.total_cents for paid orders.",
            confirmedSemanticBindings: ["paid means status = 'paid'"],
            defaultRowLimit: 100,
            schemaEvidence: Self.evidence,
            inspectionPolicy: .disabled,
            sql: "SELECT c.id, c.name, SUM(o.total_cents) AS revenue_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id GROUP BY c.id, c.name LIMIT 100",
            queryPlanJSON: #"{"grain":"one row per customer"}"#
        )
        let prompt = SchemaToolAgentCritic.userPrompt(for: request)

        #expect(prompt.hasPrefix("Question:\nRevenue by customer\n\nMode:\nfollow-up"))
        #expect(prompt.contains("Recent questions:\nTop customers"))
        #expect(prompt.contains("Current SQL for follow-up:\nSELECT id FROM public.customers LIMIT 100"))
        #expect(prompt.contains("Database context (authoritative):\nRevenue is orders.total_cents"))
        #expect(prompt.contains("- paid means status = 'paid'"))
        #expect(prompt.contains("SQL to review:\nSELECT c.id, c.name, SUM(o.total_cents)"))
        #expect(prompt.contains("Query plan:\n" + #"{"grain":"one row per customer"}"#))
    }

    @Test func initialQuestionsCarryNoCurrentSQL() {
        let request = SchemaToolAgentCriticRequest(
            question: "List customers",
            mode: .initial,
            currentSQL: "SELECT 1",
            defaultRowLimit: 100,
            schemaEvidence: Self.evidence,
            inspectionPolicy: .disabled,
            sql: "SELECT id FROM public.customers LIMIT 100"
        )

        #expect(request.currentSQL == nil)
        #expect(!SchemaToolAgentCritic.userPrompt(for: request).contains("Current SQL"))
    }

    @Test func queryPlanIsCappedAtFourKilobytes() {
        let request = SchemaToolAgentCriticRequest(
            question: "List customers",
            mode: .initial,
            defaultRowLimit: 100,
            schemaEvidence: Self.evidence,
            inspectionPolicy: .disabled,
            sql: "SELECT id FROM public.customers LIMIT 100",
            queryPlanJSON: String(repeating: "p", count: 5_000)
        )

        #expect(request.queryPlanJSON?.utf8.count == SchemaToolAgentCritic.maximumQueryPlanBytes)
    }

    // MARK: - Schema excerpt

    @Test func excerptContainsOnlyExposedColumns() {
        let excerpt = SchemaToolAgentCritic.schemaExcerpt(from: Self.evidence)

        #expect(excerpt == """
            public.customers: id integer, name text
            public.orders: customer_id, id bigint, total_cents bigint
            public.regions
            Foreign keys:
            public.orders.customer_id -> public.customers.id
            """)
        // Columns the tools never exposed stay out, even on exposed tables.
        #expect(!excerpt.contains("email"))
        #expect(!excerpt.contains("password_hash"))
    }

    @Test func excerptStaysWithinItsByteBudget() {
        let evidence = SchemaToolAgentCriticSchemaEvidence(
            columns: (1...2_000).map {
                .init(id: "public.wide_\($0 / 40).column_\($0)", dataType: "character varying")
            }
        )
        let excerpt = SchemaToolAgentCritic.schemaExcerpt(from: evidence)

        #expect(excerpt.utf8.count <= SchemaToolAgentCritic.maximumSchemaExcerptBytes)
        #expect(excerpt.hasSuffix("(schema excerpt truncated)"))
    }

    private static let evidence = SchemaToolAgentCriticSchemaEvidence(
        tableIDs: ["public.customers", "public.regions"],
        columns: [
            .init(id: "public.customers.id", dataType: "integer"),
            .init(id: "public.customers.name", dataType: "text"),
            .init(id: "public.orders.id", dataType: "bigint"),
            .init(id: "public.orders.customer_id"),
            .init(id: "public.orders.total_cents", dataType: "bigint"),
            // A search hit without a type after a describe with one keeps the type.
            .init(id: "public.customers.id"),
        ],
        foreignKeyPathIDs: [
            "public.orders.customer_id->public.customers.id",
            "public.orders.customer_id->public.customers.id",
        ]
    )

    private static func request(policy: DatabaseInspectionPolicy) -> SchemaToolAgentCriticRequest {
        SchemaToolAgentCriticRequest(
            question: "Revenue from refunded orders",
            mode: .initial,
            defaultRowLimit: 100,
            schemaEvidence: evidence,
            inspectedValuePayloads: [
                .init(
                    toolName: "inspect_distinct_values",
                    content: #"{"success":true,"payload":{"values":["paid","chargeback_hold"]}}"#
                ),
                .init(
                    toolName: "inspect_sample_rows",
                    content: #"{"success":true,"payload":{"rows":[["alice@example.com"]]}}"#
                ),
                .init(
                    toolName: "inspect_relation_size",
                    content: #"{"success":true,"payload":{"estimated_rows":10}}"#
                ),
            ],
            inspectionPolicy: policy,
            sql: "SELECT SUM(total_cents) AS revenue_cents FROM public.orders WHERE status = 'refunded' LIMIT 100"
        )
    }
}
