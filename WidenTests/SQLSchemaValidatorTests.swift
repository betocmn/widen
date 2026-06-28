import Foundation
import Testing

@testable import WidenKit

@Suite("SQLSchemaValidator")
struct SQLSchemaValidatorTests {
    @Test func missingRelationIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.missing_table",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("table public.missing_table") == true)
    }

    @Test func missingQualifiedColumnIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.missing_column FROM public.users AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_column") == true)
        #expect(result.issues.first?.kind == .missingBaseColumn)
    }

    @Test func cteNamesAreNotSchemaValidatedAsTables() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_users AS (
                  SELECT id FROM public.users
                )
                SELECT id FROM recent_users
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func aliasesQuotedIdentifiersAndOrderByAliasesResolve() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT "u"."id" AS "User ID" FROM "public"."users" AS "u" ORDER BY "User ID""#,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func unqualifiedAliasedRelationNamesAreNotScannedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.email FROM users u",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func derivedTableAliasesResolveQualifiedColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT u.id, d.n
                FROM public.users AS u
                JOIN (
                  SELECT user_id, COUNT(*) AS n
                  FROM public.orders
                  GROUP BY user_id
                ) AS d ON d.user_id = u.id
                ORDER BY d.n DESC
                LIMIT 10
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.orders", "public.users"])
    }

    @Test func valuesDerivedTableAliasColumnListDefinesColumns() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT v.id FROM (VALUES (1)) AS v(id)",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func implicitSelectAliasesResolveInOrderBy() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT COUNT(*) n FROM public.orders ORDER BY n",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func outputAliasesDoNotResolveInWhere() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id AS total FROM public.users WHERE total > 100",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("total") })
    }

    @Test func selectAliasesWithoutFromAreNotColumns() {
        let scalar = SQLSchemaValidator.validate(
            sql: "SELECT 1 AS c",
            against: makeUsersOrdersSchema()
        )
        let ordered = SQLSchemaValidator.validate(
            sql: "SELECT 1 AS c ORDER BY c",
            against: makeUsersOrdersSchema()
        )
        let exists = SQLSchemaValidator.validate(
            sql: "SELECT EXISTS (SELECT 1 FROM public.users) AS has_users",
            against: makeUsersOrdersSchema()
        )

        #expect(!scalar.hasDefiniteErrors)
        #expect(!ordered.hasDefiniteErrors)
        #expect(!exists.hasDefiniteErrors)
        #expect(exists.referencedTables == ["public.users"])
    }

    @Test func quotedOutputAliasRequiresExactQuotedOrderByReference() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT id AS "UserID" FROM public.users ORDER BY "userid""#,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("userid") })
    }

    @Test func castTypeNamesAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT created_at::date AS day, CAST(created_at AS date) AS cast_day, COUNT(*) n
                FROM public.orders
                GROUP BY created_at::date, CAST(created_at AS date)
                ORDER BY day
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func schemaQualifiedFunctionCallsAreNotColumnReferences() {
        let dateTrunc = SQLSchemaValidator.validate(
            sql: """
                SELECT pg_catalog.date_trunc('day', created_at) AS day, COUNT(*) n
                FROM public.orders
                GROUP BY pg_catalog.date_trunc('day', created_at)
                """,
            against: makeUsersOrdersSchema()
        )
        let customFunction = SQLSchemaValidator.validate(
            sql: "SELECT public.my_func(id) AS value FROM public.users",
            against: makeUsersOrdersSchema()
        )

        #expect(!dateTrunc.hasDefiniteErrors)
        #expect(!customFunction.hasDefiniteErrors)
    }

    @Test func multiwordDoubleColonCastTypeNamesAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT created_at::timestamp with time zone AS created_at_tz
                FROM public.orders
                ORDER BY created_at_tz
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func atTimeZoneSyntaxIsNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT created_at AT TIME ZONE 'UTC' AS utc_created_at
                FROM public.orders
                ORDER BY utc_created_at
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func postgresLiteralAndArraySyntaxIsNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.orders
                WHERE created_at >= TIMESTAMP '2024-01-01 00:00:00'
                  AND created_at::date >= DATE '2024-01-01'
                  AND user_id = ANY(ARRAY[1, 2, 3])
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func uuidTypedLiteralSyntaxIsNotTreatedAsAColumn() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT tool_a_id
                FROM public.preseason_match_batch
                WHERE tool_a_id = UUID '550e8400-e29b-41d4-a716-446655440000'
                """,
            against: makePreseasonSchemaWithoutWinner()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func usingAndExtractSyntaxIdentifiersAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT EXTRACT(YEAR FROM orders.created_at) AS order_year, COUNT(*)
                FROM public.users
                JOIN public.orders USING (id)
                GROUP BY EXTRACT(YEAR FROM orders.created_at)
                ORDER BY order_year
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func naturalJoinDoesNotBecomeAnAlias() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT users.email
                FROM public.users
                NATURAL JOIN public.orders
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func naturalJoinMergedColumnsAreNotAmbiguous() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                NATURAL JOIN public.orders
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func joinUsingColumnsResolveAsMergedOutputColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                JOIN public.orders USING (id)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func joinUsingColumnsAreValidatedAgainstJoinedRelations() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT *
                FROM public.users
                JOIN public.orders USING (missing_id)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing_id") })
    }

    @Test func joinUsingMergeDoesNotHideAmbiguousExtraSourceColumn() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                JOIN public.orders USING (id)
                JOIN public.orders AS o2 ON o2.user_id = users.id
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .ambiguousColumn && $0.identifier == "id" })
    }

    @Test func joinUsingValidatesAgainstRightRelationAfterOnJoin() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT *
                FROM public.users
                JOIN public.orders ON orders.user_id = users.id
                JOIN public.notes USING (id)
                """,
            against: makeUsersOrdersNotesSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("JOIN USING column id") })
    }

    @Test func chainedJoinUsingValidatesEachJoinedRelation() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                JOIN public.orders USING (id)
                JOIN public.notes USING (id)
                """,
            against: makeUsersOrdersNotesSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("JOIN USING column id") })
    }

    @Test func postgresOperatorWordsAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT email
                FROM public.users
                WHERE email ILIKE '%@example.com'
                ORDER BY email DESC NULLS LAST
                LIMIT 10
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func dollarQuotedLiteralsAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: "INSERT INTO public.notes (body) VALUES ($$hello$$)",
            against: makeNotesSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func tableValuedFunctionSourcesResolveAsDerivedSources() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT d.day
                FROM generate_series(
                  NOW() - INTERVAL '7 days',
                  NOW(),
                  INTERVAL '1 day'
                ) AS d(day)
                ORDER BY d.day
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables.isEmpty)
    }

    @Test func lateralTableValuedFunctionSourcesResolveAsDerivedSources() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT tag.value
                FROM public.users AS u
                CROSS JOIN LATERAL jsonb_array_elements_text(u.email) AS tag(value)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func tableFunctionWithOrdinalityAliasColumnsAreValidated() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT tag.value, tag.ord
                FROM public.users AS u
                CROSS JOIN LATERAL jsonb_array_elements_text(u.email)
                  WITH ORDINALITY AS tag(value, ord)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func tableSampleAliasIsParsedAfterClause() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.id FROM public.users TABLESAMPLE SYSTEM (1) AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func insertDefaultValuesAndConflictSyntaxDoNotBecomeColumns() {
        let defaultValues = SQLSchemaValidator.validate(
            sql: "INSERT INTO public.users DEFAULT VALUES",
            against: makeUsersOrdersSchema()
        )
        let doNothing = SQLSchemaValidator.validate(
            sql: "INSERT INTO public.users (id) VALUES (1) ON CONFLICT (id) DO NOTHING",
            against: makeUsersOrdersSchema()
        )

        #expect(!defaultValues.hasDefiniteErrors)
        #expect(!doNothing.hasDefiniteErrors)
    }

    @Test func postgresClauseWordsDoNotBecomeColumns() {
        let overriding = SQLSchemaValidator.validate(
            sql: "INSERT INTO public.users (id) OVERRIDING SYSTEM VALUE VALUES (1)",
            against: makeUsersOrdersSchema()
        )
        let collate = SQLSchemaValidator.validate(
            sql: #"SELECT email FROM public.users WHERE email COLLATE "C" = 'a@example.com'"#,
            against: makeUsersOrdersSchema()
        )

        #expect(!overriding.hasDefiniteErrors)
        #expect(!collate.hasDefiniteErrors)
    }

    @Test func onConflictConstraintNamesAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id, email)
                VALUES (1, 'a@example.com')
                ON CONFLICT ON CONSTRAINT users_pkey DO NOTHING
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func insertSelectTargetColumnsAreValidated() {
        let valid = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id)
                SELECT user_id FROM public.orders
                """,
            against: makeUsersOrdersSchema()
        )
        let invalid = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (missing)
                SELECT user_id FROM public.orders
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!valid.hasDefiniteErrors)
        #expect(invalid.hasDefiniteErrors)
        #expect(invalid.errors.contains { $0.contains("missing") && $0.contains("public.users") })
    }

    @Test func insertSelectExpressionsDoNotAmbiguateAgainstInsertTarget() {
        let result = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (email)
                SELECT email FROM public.staging_users AS staging
                """,
            against: makeUsersStagingSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func insertValuesExpressionsDoNotResolveAgainstInsertTarget() {
        let result = SQLSchemaValidator.validate(
            sql: "INSERT INTO public.users (email) VALUES (email)",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("email") })
    }

    @Test func excludedColumnsResolveAgainstUpsertTarget() {
        let valid = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id, email)
                VALUES (1, 'a@example.com')
                ON CONFLICT (id) DO UPDATE SET email = excluded.email
                """,
            against: makeUsersOrdersSchema()
        )
        let invalid = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id, email)
                VALUES (1, 'a@example.com')
                ON CONFLICT (id) DO UPDATE SET email = excluded.missing_email
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!valid.hasDefiniteErrors)
        #expect(invalid.hasDefiniteErrors)
        #expect(invalid.errors.contains { $0.contains("missing_email") })
    }

    @Test func distinctFromOperatorDoesNotStartRelationParsing() {
        let joinPredicate = SQLSchemaValidator.validate(
            sql: """
                SELECT u.email
                FROM public.users AS u
                JOIN public.users AS other ON u.email IS DISTINCT FROM other.email
                """,
            against: makeUsersOrdersSchema()
        )
        let upsertPredicate = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id, email)
                VALUES (1, 'a@example.com')
                ON CONFLICT (id) DO UPDATE SET email = excluded.email
                WHERE public.users.email IS DISTINCT FROM excluded.email
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!joinPredicate.hasDefiniteErrors)
        #expect(!upsertPredicate.hasDefiniteErrors)
    }

    @Test func onConflictSetTargetsAreValidatedAgainstInsertTarget() {
        let result = SQLSchemaValidator.validate(
            sql: """
                INSERT INTO public.users (id, email)
                VALUES (1, 'a@example.com')
                ON CONFLICT (id) DO UPDATE SET missing = excluded.email
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing") && $0.contains("public.users") })
    }

    @Test func updateSetTargetsDoNotAmbiguateAgainstFromTables() {
        let result = SQLSchemaValidator.validate(
            sql: """
                UPDATE public.users
                SET email = staging.email
                FROM public.staging_users AS staging
                WHERE users.id = staging.user_id
                """,
            against: makeUsersStagingSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func updateSetTargetsAreValidatedAgainstUpdateTable() {
        let result = SQLSchemaValidator.validate(
            sql: """
                UPDATE public.users
                SET missing = 1
                WHERE id = 1
                """,
            against: makeUsersStagingSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing") && $0.contains("public.users") })
    }

    @Test func updateCorrelatedSubqueryCanReferenceTargetAlias() {
        let result = SQLSchemaValidator.validate(
            sql: """
                UPDATE public.users AS u
                SET email = 'updated@example.com'
                WHERE EXISTS (
                    SELECT 1
                    FROM public.orders AS o
                    WHERE o.user_id = u.id
                )
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func deleteUsingTablesAreRelationSources() {
        let result = SQLSchemaValidator.validate(
            sql: """
                DELETE FROM public.users
                USING public.staging_users AS staging
                WHERE users.id = staging.user_id
                """,
            against: makeUsersStagingSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func sourceLessIdentifiersAreRejected() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("id") })
    }

    @Test func unquotedMixedCaseColumnDoesNotMatchQuotedPostgresColumn() {
        let unquoted = SQLSchemaValidator.validate(
            sql: #"SELECT createdAt FROM public.events"#,
            against: makeMixedCaseSchema()
        )
        let quoted = SQLSchemaValidator.validate(
            sql: #"SELECT "createdAt" FROM public.events"#,
            against: makeMixedCaseSchema()
        )

        #expect(unquoted.hasDefiniteErrors)
        #expect(unquoted.errors.first?.contains("createdAt") == true)
        #expect(unquoted.issues.first?.kind == .requiresQuotedIdentifier)
        #expect(unquoted.issues.first?.suggestedIdentifier == "createdAt")
        #expect(!quoted.hasDefiniteErrors)
    }

    @Test func quotedMixedCaseRelationNamesRequireExactCase() {
        let unquoted = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.EventLog",
            against: makeMixedCaseTableSchema()
        )
        let quotedWrongCase = SQLSchemaValidator.validate(
            sql: #"SELECT id FROM "public"."eventlog""#,
            against: makeMixedCaseTableSchema()
        )
        let quotedExact = SQLSchemaValidator.validate(
            sql: #"SELECT id FROM "public"."EventLog""#,
            against: makeMixedCaseTableSchema()
        )
        let unquotedQualifier = SQLSchemaValidator.validate(
            sql: #"SELECT EventLog.id FROM public."EventLog""#,
            against: makeMixedCaseTableSchema()
        )
        let quotedQualifier = SQLSchemaValidator.validate(
            sql: #"SELECT "EventLog".id FROM public."EventLog""#,
            against: makeMixedCaseTableSchema()
        )
        let quotedQualifiedQualifier = SQLSchemaValidator.validate(
            sql: #"SELECT public."EventLog".id FROM public."EventLog""#,
            against: makeMixedCaseTableSchema()
        )

        #expect(unquoted.hasDefiniteErrors)
        #expect(quotedWrongCase.hasDefiniteErrors)
        #expect(unquotedQualifier.hasDefiniteErrors)
        #expect(!quotedExact.hasDefiniteErrors)
        #expect(!quotedQualifier.hasDefiniteErrors)
        #expect(!quotedQualifiedQualifier.hasDefiniteErrors)
        #expect(quotedExact.referencedTables == ["public.EventLog"])
    }

    @Test func tableAliasesHideOriginalTableQualifier() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT users.id FROM public.users AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("qualifier users") })
    }

    @Test func quotedTableAliasesRequireExactQuotedQualifierCase() {
        let unquoted = SQLSchemaValidator.validate(
            sql: #"SELECT u.id FROM public.users AS "U""#,
            against: makeUsersOrdersSchema()
        )
        let quoted = SQLSchemaValidator.validate(
            sql: #"SELECT "U".id FROM public.users AS "U""#,
            against: makeUsersOrdersSchema()
        )

        #expect(unquoted.hasDefiniteErrors)
        #expect(unquoted.errors.contains { $0.contains("qualifier u") })
        #expect(!quoted.hasDefiniteErrors)
    }

    @Test func quotedLowercaseTableAliasCanBeReferencedUnquoted() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT u.id FROM public.users AS "u""#,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func singleQuotedQualifiedTableNameIsNotAQualifier() {
        let invalid = SQLSchemaValidator.validate(
            sql: #"SELECT "public.users".id FROM public.users"#,
            against: makeUsersOrdersSchema()
        )
        let separatelyQuoted = SQLSchemaValidator.validate(
            sql: #"SELECT "public"."users".id FROM public.users"#,
            against: makeUsersOrdersSchema()
        )

        #expect(invalid.hasDefiniteErrors)
        #expect(invalid.errors.contains { $0.contains("public.users") })
        #expect(!separatelyQuoted.hasDefiniteErrors)
    }

    @Test func quotedCteOutputAliasRequiresExactQuotedReference() {
        let unquoted = SQLSchemaValidator.validate(
            sql: """
                WITH c AS (
                  SELECT id AS "UserID" FROM public.users
                )
                SELECT userid FROM c
                """,
            against: makeUsersOrdersSchema()
        )
        let quoted = SQLSchemaValidator.validate(
            sql: """
                WITH c AS (
                  SELECT id AS "UserID" FROM public.users
                )
                SELECT "UserID" FROM c
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(unquoted.hasDefiniteErrors)
        #expect(unquoted.errors.contains { $0.contains("userid") })
        #expect(!quoted.hasDefiniteErrors)
    }

    @Test func quotedCteNameRequiresExactQuotedReferenceCase() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH "RecentUsers" AS (
                  SELECT id FROM public.users
                )
                SELECT id FROM "recentusers"
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .missingRelation })
    }

    @Test func nestedSubqueryCteNamesAreParsedLocally() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT d.id
                FROM (
                  WITH c AS (SELECT id FROM public.users)
                  SELECT id FROM c
                ) AS d
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func derivedTableColumnAliasListsDefineDerivedColumns() {
        let valid = SQLSchemaValidator.validate(
            sql: """
                SELECT d.user_id
                FROM (SELECT id FROM public.users) AS d(user_id)
                """,
            against: makeUsersOrdersSchema()
        )
        let invalid = SQLSchemaValidator.validate(
            sql: """
                SELECT d.id
                FROM (SELECT id FROM public.users) AS d(user_id)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!valid.hasDefiniteErrors)
        #expect(invalid.hasDefiniteErrors)
        #expect(invalid.errors.contains { $0.contains("id") })
    }

    @Test func cteSelectStarExpandsKnownTableColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH u AS (
                  SELECT * FROM public.users
                )
                SELECT missing FROM u
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing") })
    }

    @Test func derivedSelectStarExpandsKnownTableColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT missing
                FROM (
                  SELECT * FROM public.users
                ) AS u
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing") })
    }

    @Test func cteSelectStarFromCteExpandsKnownColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH a AS (
                  SELECT id FROM public.users
                ),
                b AS (
                  SELECT * FROM a
                )
                SELECT email FROM b
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("email") })
    }

    @Test func generatedValidatorCanRepairUnquotedMixedCaseColumns() {
        let repaired = GeneratedSQLValidator.repairQuotedIdentifiers(
            sql:
                #"SELECT createdAt FROM public.events WHERE createdAt IS NOT NULL -- createdAt comment"#,
            schema: makeMixedCaseSchema()
        )

        #expect(
            repaired
                == #"SELECT "createdAt" FROM public.events WHERE "createdAt" IS NOT NULL -- createdAt comment"#
        )
    }

    @Test func generatedValidatorRepairsOnlyColumnReferenceIdentifiers() {
        let repaired = GeneratedSQLValidator.repairQuotedIdentifiers(
            sql: #"SELECT date, created_at::date AS created_day FROM public.events"#,
            schema: makeMixedCaseDateSchema()
        )

        #expect(repaired == #"SELECT "Date", created_at::date AS created_day FROM public.events"#)
    }

    @Test func prefixedStringLiteralsAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT id FROM public.users WHERE email = E'O\'Reilly' OR email = B'1010' OR email = X'FF'"#,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func timestampComparedDirectlyToIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT "createdAt" FROM public.events WHERE "createdAt" >= INTERVAL '7 days'"#,
            against: makeMixedCaseSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
        #expect(result.errors.first?.contains("NOW() - INTERVAL '7 days'") == true)
    }

    @Test func quotedAliasTemporalIntervalComparisonIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT "U"."createdAt" FROM public.events AS "U" WHERE "U"."createdAt" >= INTERVAL '7 days'"#,
            against: makeMixedCaseSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func timestampComparedDirectlyToParenthesizedIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE created_at > (INTERVAL '7 days')",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func timestampBetweenBareIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE created_at BETWEEN INTERVAL '7 days' AND NOW()",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func castedTimestampComparedToIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE created_at::date >= INTERVAL '7 days'",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func dateTruncComparedToIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql:
                "SELECT id FROM public.orders WHERE DATE_TRUNC('day', created_at) >= INTERVAL '7 days'",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func timestampDifferenceCanBeUsedWithIntervalBetween() {
        let result = SQLSchemaValidator.validate(
            sql:
                "SELECT id FROM public.orders WHERE NOW() - created_at BETWEEN INTERVAL '1 day' AND INTERVAL '7 days'",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors == false)
    }

    @Test func timestampComparedToTimestampExpressionIsValid() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT "createdAt" FROM public.events WHERE "createdAt" >= NOW() - INTERVAL '7 days'"#,
            against: makeMixedCaseSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func currentTimeIsBuiltinTemporalValue() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE created_at < CURRENT_TIME",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func timestampDifferenceCanBeComparedToInterval() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.jobs WHERE finished_at - started_at > INTERVAL '1 hour'",
            against: makeIntervalSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func dateDifferenceComparedToIntervalIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE CURRENT_DATE - order_date > INTERVAL '7 days'",
            against: makeOrderDateSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func parenthesizedTemporalColumnComparedToIntervalIsDefiniteError() {
        let left = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE (created_at) > INTERVAL '7 days'",
            against: makeUsersOrdersSchema()
        )
        let right = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders WHERE INTERVAL '7 days' < (created_at)",
            against: makeUsersOrdersSchema()
        )

        #expect(left.hasDefiniteErrors)
        #expect(left.issues.contains { $0.kind == .invalidTemporalComparison })
        #expect(right.hasDefiniteErrors)
        #expect(right.issues.contains { $0.kind == .invalidTemporalComparison })
    }

    @Test func temporalFunctionDifferenceCanBeComparedToInterval() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.jobs WHERE NOW() - started_at > INTERVAL '7 days'",
            against: makeIntervalSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func intervalColumnCanBeComparedToInterval() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT duration FROM public.jobs WHERE duration >= INTERVAL '7 days'",
            against: makeIntervalSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func percentileWithinGroupDoesNotTreatWithinAsColumn() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY id) FROM public.orders",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func postgresExpressionGrammarWordsAreNotColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT email
                FROM public.users
                WHERE email SIMILAR TO '%@%'
                  AND TRIM(BOTH FROM email) <> ''
                  AND SUBSTRING(email FROM 1 FOR 2) = 'al'
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func fetchFirstClauseIsNotAColumnReference() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders ORDER BY created_at FETCH FIRST 10 ROWS ONLY",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func fetchNextWithTiesClauseIsNotAColumnReference() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.orders ORDER BY created_at FETCH NEXT 10 ROWS WITH TIES",
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func groupingSetsClauseIsNotAColumnReference() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT user_id, COUNT(*)
                FROM public.orders
                GROUP BY GROUPING SETS ((user_id), ())
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func intervalColumnComparisonIgnoresNestedTimestampWithSameName() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT duration
                FROM public.jobs
                WHERE duration > INTERVAL '1 hour'
                  AND EXISTS (
                    SELECT 1 FROM public.events WHERE duration >= NOW()
                  )
                """,
            against: makeIntervalShadowSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func ambiguousUnqualifiedColumnIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                JOIN public.orders ON users.id = orders.user_id
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("ambiguous") == true)
    }

    @Test func trailingExpressionOperandsAreNotImplicitAliases() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id * missing FROM public.users",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("missing") })
    }

    @Test func windowFrameTermsAreNotTreatedAsColumns() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT SUM(id) OVER (
                  ORDER BY created_at
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS running_id
                FROM public.orders
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func namedWindowClauseDoesNotBecomeAliasOrColumn() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT COUNT(*) OVER w AS n
                FROM public.orders
                WINDOW w AS (PARTITION BY user_id ORDER BY created_at)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func nestedSubqueryScopesDoNotFalseAmbiguateOuterColumn() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                WHERE EXISTS (
                  SELECT 1
                  FROM public.orders
                  WHERE orders.user_id = users.id
                )
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.orders", "public.users"])
    }

    @Test func nonLateralDerivedTableCannotReferenceOuterScope() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT d.id
                FROM public.users AS u
                JOIN (SELECT u.id) AS d(id) ON true
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("qualifier u") })
    }

    @Test func commaDerivedTableCannotReferenceOuterScope() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT d.id
                FROM public.users AS u, (SELECT u.id) AS d(id)
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.contains { $0.contains("qualifier u") })
    }

    @Test func lateralDerivedTableCanReferenceOuterScope() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT d.id
                FROM public.users AS u
                JOIN LATERAL (SELECT u.id) AS d(id) ON true
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func cteOutputColumnsAreValidated() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_users AS (
                  SELECT id FROM public.users
                )
                SELECT email FROM recent_users
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("email") == true)
    }

    @Test func cteProjectionFailuresUseSpecificIssueKind() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_wins AS (
                  SELECT id FROM public.users
                )
                SELECT winner_id FROM recent_wins
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.issues.contains { $0.kind == .columnNotProjectedByCTE })
        #expect(
            result.errors.contains {
                $0.contains("winner_id is not an output column of recent_wins")
                    && $0.contains("project it from the CTE")
            })
    }

    @Test func quotedLowercaseCTEColumnsAllowUnquotedReferences() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_users("id") AS (
                  SELECT id FROM public.users
                )
                SELECT id FROM recent_users
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
    }

    @Test func unresolvedAliasStarIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT missing_alias.* FROM public.users AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_alias") == true)
    }

    @Test func commaSeparatedMissingRelationIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.id FROM public.users AS u, public.missing_table AS m",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_table") == true)
    }

    @Test func missingRelationDoesNotCascadeIntoMissingColumn() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.missing_table",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains("missing_table") == true)
    }

    @Test func generatedResultDerivesReferencedTables() {
        let generation = SQLGenerationResult(
            sql: "SELECT u.id FROM public.users AS u",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: ["public.fake"],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show users",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func groundingClarificationNamesWinnerAndTimeCandidates() {
        func column(
            table: String,
            name: String,
            type: String,
            nullable: Bool = false,
            ordinal: Int
        ) -> ColumnInfo {
            ColumnInfo(
                tableSchema: "public",
                tableName: table,
                name: name,
                dataType: type,
                isNullable: nullable,
                ordinalPosition: ordinal
            )
        }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_evaluation",
                    type: .baseTable,
                    columns: [
                        column(table: "preseason_match_evaluation", name: "winner_id", type: "uuid", nullable: true, ordinal: 1),
                        column(table: "preseason_match_evaluation", name: "createdAt", type: "timestamp with time zone", ordinal: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_tool",
                    type: .baseTable,
                    columns: [
                        column(table: "preseason_tool", name: "id", type: "uuid", ordinal: 1),
                        column(table: "preseason_tool", name: "name", type: "text", ordinal: 2),
                    ]
                ),
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "preseason_match_evaluation_winner_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "winner_id",
                            targetColumn: "id",
                            ordinalPosition: 1
                        ),
                    ]
                ),
            ]
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                GROUP BY t.name
                """,
            explanation: "Counts winners.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Tools with the most wins in the last two weeks",
            schema: schema,
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("winner_id") == true)
        #expect(enriched.clarificationQuestion?.contains("createdAt") == true)
    }

    @Test func winnerClarificationOffersMultipleTimeFieldsInsteadOfPickingFirst() {
        var schema = makePreseasonWinnerSchema()
        schema.tables[0].columns.append(
            ColumnInfo(
                tableSchema: "public",
                tableName: "preseason_match_evaluation",
                name: "evaluatedAt",
                dataType: "timestamp with time zone",
                isNullable: false,
                ordinalPosition: 3
            ))
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                GROUP BY t.name
                """,
            explanation: "Counts winners.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Tools with the most wins in the last two weeks",
            schema: schema,
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("which date field should define the time window") == true)
        #expect(enriched.clarificationQuestion?.contains("createdAt") == true)
        #expect(enriched.clarificationQuestion?.contains("evaluatedAt") == true)
        #expect(enriched.clarificationQuestion?.contains("use public.preseason_match_evaluation.createdAt") == false)
    }

    @Test func anchoredWinnerContextRequiresExplicitAnchorInsteadOfMovingNow() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, t.slug, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                  AND e."createdAt" >= NOW() - INTERVAL '14 days'
                GROUP BY t.name, t.slug
                ORDER BY COUNT(*) DESC
                """,
            explanation: "Counts winning evaluations by tool.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which tools have the most wins in the two weeks ending 2026-06-24 12:00 UTC?",
            schema: makePreseasonWinnerSchema(),
            databaseContext:
                "Each evaluation with a non-null winner_id records one win. Use the evaluation createdAt timestamp and treat the evaluation anchor as 2026-06-24 12:00 UTC."
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("2026-06-24 12:00 UTC") == true)
    }

    @Test func anchoredWinnerContextRequiresFullAnchorTimeNotJustDate() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, t.slug, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                  AND e."createdAt" >= NOW() - INTERVAL '14 days'
                  AND e."createdAt" < DATE '2026-06-24'
                GROUP BY t.name, t.slug
                ORDER BY COUNT(*) DESC
                """,
            explanation: "Counts winning evaluations by tool.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which tools have the most wins in the two weeks ending 2026-06-24 12:00 UTC?",
            schema: makePreseasonWinnerSchema(),
            databaseContext:
                "Each evaluation with a non-null winner_id records one win. Use the evaluation createdAt timestamp and treat the evaluation anchor as 2026-06-24 12:00 UTC."
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("2026-06-24 12:00 UTC") == true)
    }

    @Test func anchoredWinnerContextRejectsMovingLowerBoundEvenWithAnchoredUpperBound() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, t.slug, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                  AND e."createdAt" >= NOW() - INTERVAL '14 days'
                  AND e."createdAt" < CAST('2026-06-24 12:00:00+00' AS TIMESTAMPTZ)
                GROUP BY t.name, t.slug
                ORDER BY COUNT(*) DESC
                """,
            explanation: "Counts winning evaluations by tool.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which tools have the most wins in the two weeks ending 2026-06-24 12:00 UTC?",
            schema: makePreseasonWinnerSchema(),
            databaseContext:
                "Each evaluation with a non-null winner_id records one win. Use the evaluation createdAt timestamp and treat the evaluation anchor as 2026-06-24 12:00 UTC."
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("2026-06-24 12:00 UTC") == true)
    }

    @Test func explicitWinnerContextDoesNotClarifyDurationWordsWhenAnchorIsUsed() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT t.name, t.slug, COUNT(*) AS wins
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_tool AS t ON e.winner_id = t.id
                WHERE e.winner_id IS NOT NULL
                  AND e."createdAt" >= CAST('2026-06-24 12:00:00+00' AS TIMESTAMPTZ) - INTERVAL '14 days'
                GROUP BY t.name, t.slug
                ORDER BY COUNT(*) DESC
                """,
            explanation: "Counts winning evaluations by tool.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which tools have the most wins in the two weeks ending 2026-06-24 12:00 UTC?",
            schema: makePreseasonWinnerSchema(),
            databaseContext:
                "Each evaluation with a non-null winner_id records one win. Use the evaluation createdAt timestamp and treat the evaluation anchor as 2026-06-24 12:00 UTC."
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql.contains("2026-06-24 12:00:00+00"))
    }

    @Test func nonAnchorDatePredicateDoesNotClarifyMovingWindow() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                WHERE started_at < TIMESTAMPTZ '2026-01-01 00:00:00+00'
                  AND finished_at >= NOW() - INTERVAL '7 days'
                """,
            explanation: "Finds jobs matching the fixed start cutoff and recent finish window.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which jobs started before 2026-01-01 and finished in the last 7 days?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql.contains("NOW() - INTERVAL '7 days'"))
    }

    @Test func fixedUntilPredicateDoesNotAnchorSeparateMovingWindow() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                WHERE started_at < TIMESTAMPTZ '2026-01-01 00:00:00+00'
                  AND finished_at >= NOW() - INTERVAL '7 days'
                """,
            explanation: "Finds jobs created before the fixed cutoff and updated recently.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which jobs were created until 2026-01-01 and updated in the last 7 days?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql.contains("NOW() - INTERVAL '7 days'"))
    }

    @Test func fixedStartingWindowWithMovingCurrentTimeClarifies() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                WHERE finished_at >= CURRENT_DATE
                  AND finished_at < CURRENT_DATE + INTERVAL '30 days'
                """,
            explanation: "Finds jobs finishing in the next 30 days.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which jobs finish in the 30 days starting 2026-06-24?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("2026-06-24") == true)
    }

    @Test func singularWeekEndingWindowWithMovingCurrentTimeClarifies() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                WHERE finished_at >= NOW() - INTERVAL '7 days'
                """,
            explanation: "Finds jobs finished in the last week.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which jobs finished in the week ending 2026-06-24 12:00 UTC?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("2026-06-24 12:00 UTC") == true)
    }

    @Test func timeFieldClarificationExcludesIntervalColumns() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                """,
            explanation: "Lists jobs.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which jobs ran in the last 7 days?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("finished_at") == true)
        #expect(enriched.clarificationQuestion?.contains("started_at") == true)
        #expect(enriched.clarificationQuestion?.contains("duration") == false)
    }

    @Test func filterClarificationAsksAboutBusinessTermBeforeTimeFields() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT id
                FROM public.jobs
                WHERE started_at >= NOW() - INTERVAL '7 days'
                """,
            explanation: "Lists recent jobs.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "Which paid jobs ran last week?",
            schema: makeIntervalSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains(#"defines "paid""#) == true)
        #expect(enriched.clarificationQuestion?.contains("which date field should define") == false)
    }

    @Test func possessiveSuffixDoesNotBecomeUnsupportedGroundingConcept() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT o.id
                FROM public.orders AS o
                JOIN public.users AS u ON u.id = o.user_id
                WHERE u.email = 'alice@example.com'
                """,
            explanation: "Lists Alice's orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        for question in ["Show Alice's orders", "Show Alice’s orders"] {
            let enriched = GeneratedSQLPostprocessor.enriched(
                generation,
                question: question,
                schema: makeUsersOrdersSchema(),
                databaseContext: ""
            )

            #expect(!enriched.needsClarification)
            #expect(enriched.sql == generation.sql)
            #expect(enriched.referencedTables == ["public.orders", "public.users"])
            #expect(!enriched.groundingConcepts.contains { $0.term == "s" })
        }
    }

    @Test func genericMetricVerbsDoNotForceClarification() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT COUNT(*)
                FROM public.orders
                WHERE created_at >= NOW() - INTERVAL '7 days'
                """,
            explanation: "Counts recent orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "How many orders did we make last week?",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.referencedTables == ["public.orders"])
        #expect(enriched.groundingConcepts.contains {
            $0.kind == .metric && $0.state == .notRequired
        })
    }

    @Test func pastTenseGenericVerbMadeDoesNotRequireGrounding() {
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.orders WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'",
            explanation: "Lists recent orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show orders made last week",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.clarificationQuestion == nil)
        #expect(enriched.referencedTables == ["public.orders"])
    }

    @Test func literalFilterValuesDoNotForceClarification() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.customers WHERE state = 'California'",
            explanation: "Counts customers in California.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "How many customers are in California?",
            schema: makeCustomerStateSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.referencedTables == ["public.customers"])
    }

    @Test func unconstrainedStatusLiteralDoesNotDefineBusinessTerm() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'active'",
            explanation: "Counts active users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active users do we have?",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"active\"") == true)
        #expect(enriched.pendingClarification?.concept.state == .unsupported)
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func nonMetricFilterTermsStillRequireGrounding() {
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.users WHERE status = 'active'",
            explanation: "Lists active users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show active users",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"active\"") == true)
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func comparisonFilterTermsDoNotRequireGrounding() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "age",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.users WHERE age > 30",
            explanation: "Lists users older than 30.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show users older than 30",
            schema: schema,
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == "SELECT id FROM public.users WHERE age > 30")
        #expect(enriched.clarificationQuestion == nil)
    }

    @Test func numberWordsRemainGroundingTermsForCountFilters() {
        let zeroOrders = SQLGenerationResult(
            sql: "SELECT id FROM public.users",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
        let oneOrder = SQLGenerationResult(
            sql: """
                SELECT users.id
                FROM public.users
                WHERE EXISTS (
                  SELECT 1
                  FROM public.orders
                  WHERE orders.user_id = users.id
                )
                """,
            explanation: "Lists users with at least one order.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let zeroEnriched = GeneratedSQLPostprocessor.enriched(
            zeroOrders,
            question: "show users with zero orders",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )
        let oneEnriched = GeneratedSQLPostprocessor.enriched(
            oneOrder,
            question: "show users with one order",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(zeroEnriched.needsClarification)
        #expect(zeroEnriched.pendingClarification?.concept.term == "zero")
        #expect(oneEnriched.needsClarification)
        #expect(oneEnriched.pendingClarification?.concept.term == "one")
    }

    @Test func generatedWriteRequiresGroundingForUnsupportedLiteral() {
        let generation = SQLGenerationResult(
            sql: "DELETE FROM public.users WHERE status = 'churned'",
            explanation: "Deletes churned users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .high,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "delete churned users",
            schema: makeUsersStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"churned\"") == true)
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func statusLikePastParticipleValuesRequireGrounding() {
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.users WHERE status = 'deleted'",
            explanation: "Lists deleted users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show deleted users",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"deleted\"") == true)
        #expect(enriched.pendingClarification?.concept.term == "deleted")
    }

    @Test func databaseContextCanDefineUnconstrainedStatusLiteral() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'active'",
            explanation: "Counts active users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active users do we have?",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: "Active users are users whose status is active."
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func confirmedSemanticBindingDefinesUnconstrainedStatusLiteral() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'active'",
            explanation: "Counts active users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active users do we have?",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: "",
            confirmedSemanticBindings: ["active: users whose status is active"]
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.groundingConcepts.contains {
            $0.term == "active" && $0.evidence.contains("Confirmed semantic binding")
        })
    }

    @Test func semanticBindingLabelDoesNotDefineUnconstrainedStatusLiteral() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'churned'",
            explanation: "Counts churned users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many churned users do we have?",
            schema: makeUsersUnconstrainedStatusSchema(),
            databaseContext: "",
            confirmedSemanticBindings: ["churned: \"public\".\"users\".\"cancelled_at\" IS NOT NULL"]
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"churned\"") == true)
        #expect(enriched.pendingClarification?.concept.term == "churned")
    }

    @Test func postprocessorAsksWhenMetricTermIsMissingFromReferencedSchema() {
        let generation = SQLGenerationResult(
            sql: "SELECT tool_a_id, COUNT(*) FROM public.preseason_match_batch GROUP BY tool_a_id",
            explanation: "Counts tool A appearances.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what tools have the most wins?",
            schema: makePreseasonSchemaWithoutWinner(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"wins\"") == true)
        #expect(enriched.referencedTables == ["public.preseason_match_batch"])
    }

    @Test func genericOutcomeFieldsDoNotSilentlyDefineMissingMetricTerm() {
        let generation = SQLGenerationResult(
            sql: "SELECT tool_a_id, COUNT(*) FROM public.preseason_match_batch GROUP BY tool_a_id",
            explanation: "Counts appearances.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what tools have the most wins?",
            schema: makePreseasonSchemaWithGenericOutcomeFields(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"wins\"") == true)
        #expect(enriched.referencedTables == ["public.preseason_match_batch"])
    }

    @Test func shortBusinessTermsDoNotPrefixMatchUnrelatedSchemaTokens() {
        let generation = SQLGenerationResult(
            sql: "SELECT tool_a_id, COUNT(*) FROM public.preseason_match_batch GROUP BY tool_a_id",
            explanation: "Counts appearances.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what tools have the most wins?",
            schema: makePreseasonSchemaWithWindowTerms(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"wins\"") == true)
    }

    @Test func enumValueCanDefineBusinessTerm() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.customers WHERE segment = 'retained'",
            explanation: "Counts retained customers.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many retained customers do we have?",
            schema: makeCustomerSegmentSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.referencedTables == ["public.customers"])
    }

    @Test func inventedConstrainedLiteralDoesNotDefineBusinessTerm() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'churned'",
            explanation: "Counts churned users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many churned users do we have?",
            schema: makeUsersStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"churned\"") == true)
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func constrainedLiteralMustMatchExactValue() {
        let generation = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'Active'",
            explanation: "Counts active users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active users do we have?",
            schema: makeUsersStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"active\"") == true)
        #expect(enriched.pendingClarification?.concept.state == .unsupported)
        #expect(enriched.clarificationOptions.contains {
            $0.definition.contains(#""public"."users"."status" = 'active'"#)
        })
        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func inventedConstrainedLiteralInMembershipDoesNotDefineBusinessTerm() {
        let inGeneration = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status IN ('churned')",
            explanation: "Counts churned users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
        let anyGeneration = SQLGenerationResult(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = ANY(ARRAY['churned'])",
            explanation: "Counts churned users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let inEnriched = GeneratedSQLPostprocessor.enriched(
            inGeneration,
            question: "how many churned users do we have?",
            schema: makeUsersStatusSchema(),
            databaseContext: ""
        )
        let anyEnriched = GeneratedSQLPostprocessor.enriched(
            anyGeneration,
            question: "how many churned users do we have?",
            schema: makeUsersStatusSchema(),
            databaseContext: ""
        )

        #expect(inEnriched.needsClarification)
        #expect(inEnriched.sql.isEmpty)
        #expect(inEnriched.clarificationQuestion?.contains("\"churned\"") == true)
        #expect(anyEnriched.needsClarification)
        #expect(anyEnriched.sql.isEmpty)
        #expect(anyEnriched.clarificationQuestion?.contains("\"churned\"") == true)
    }

    @Test func unqualifiedConstrainedLiteralUsesResolvedScope() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT COUNT(*)
                FROM public.users
                WHERE status = 'active'
                  AND EXISTS (
                    SELECT 1
                    FROM public.orders
                    WHERE orders.user_id = users.id
                  )
                """,
            explanation: "Counts active users with orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active users have orders?",
            schema: makeUsersOrdersStatusSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.referencedTables == ["public.orders", "public.users"])
    }

    @Test func constrainedLiteralMustMatchQualifiedColumnTable() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT COUNT(*)
                FROM public.users
                JOIN public.orders ON users.id = orders.user_id
                WHERE orders.status = 'active'
                """,
            explanation: "Counts active orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "how many active orders do we have?",
            schema: makeUsersOrdersStatusSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("\"active\"") == true)
        #expect(enriched.referencedTables == ["public.orders", "public.users"])
    }

    private func makeUsersOrdersSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "email",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "user_id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "created_at",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 3
                        ),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makeUsersOrdersStatusSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["active", "inactive"],
                                    expression: "CHECK (status IN ('active', 'inactive'))"
                                )
                            ]
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "user_id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 3,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["paid", "refunded"],
                                    expression: "CHECK (status IN ('paid', 'refunded'))"
                                )
                            ]
                        ),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makeUsersUnconstrainedStatusSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeUsersStatusSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 1,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["active", "inactive"],
                                    expression: "CHECK (status IN ('active', 'inactive'))"
                                )
                            ]
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeUsersOrdersNotesSchema() -> DatabaseSchema {
        var schema = makeUsersOrdersSchema()
        schema.tables.append(
            TableInfo(
                schema: "public",
                name: "notes",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "notes",
                        name: "body",
                        dataType: "text",
                        isNullable: false,
                        ordinalPosition: 1
                    )
                ]
            )
        )
        return schema
    }

    private func makeUsersStagingSchema() -> DatabaseSchema {
        var schema = makeUsersOrdersSchema()
        schema.tables.append(
            TableInfo(
                schema: "public",
                name: "staging_users",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "staging_users",
                        name: "user_id",
                        dataType: "integer",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "staging_users",
                        name: "email",
                        dataType: "text",
                        isNullable: false,
                        ordinalPosition: 2
                    ),
                ]
            ))
        return schema
    }

    private func makeMixedCaseSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "events",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "events",
                            name: "createdAt",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeMixedCaseDateSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "events",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "events",
                            name: "Date",
                            dataType: "date",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "events",
                            name: "created_at",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeMixedCaseTableSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "EventLog",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "EventLog",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeNotesSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "notes",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "notes",
                            name: "body",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeOrderDateSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "order_date",
                            dataType: "date",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeIntervalSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "jobs",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "jobs",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "jobs",
                            name: "duration",
                            dataType: "interval",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "jobs",
                            name: "started_at",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 3
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "jobs",
                            name: "finished_at",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 4
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeIntervalShadowSchema() -> DatabaseSchema {
        var schema = makeIntervalSchema()
        schema.tables.append(
            TableInfo(
                schema: "public",
                name: "events",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "events",
                        name: "duration",
                        dataType: "timestamp with time zone",
                        isNullable: false,
                        ordinalPosition: 1
                    )
                ]
            )
        )
        return schema
    }

    private func makePreseasonSchemaWithoutWinner() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_b_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "completed_evaluations",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 3
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makePreseasonWinnerSchema() -> DatabaseSchema {
        func column(
            table: String,
            name: String,
            type: String,
            nullable: Bool = false,
            ordinal: Int
        ) -> ColumnInfo {
            ColumnInfo(
                tableSchema: "public",
                tableName: table,
                name: name,
                dataType: type,
                isNullable: nullable,
                ordinalPosition: ordinal
            )
        }
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_evaluation",
                    type: .baseTable,
                    columns: [
                        column(table: "preseason_match_evaluation", name: "winner_id", type: "uuid", nullable: true, ordinal: 1),
                        column(table: "preseason_match_evaluation", name: "createdAt", type: "timestamp with time zone", ordinal: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_tool",
                    type: .baseTable,
                    columns: [
                        column(table: "preseason_tool", name: "id", type: "uuid", ordinal: 1),
                        column(table: "preseason_tool", name: "name", type: "text", ordinal: 2),
                        column(table: "preseason_tool", name: "slug", type: "text", ordinal: 3),
                        column(table: "preseason_tool", name: "createdAt", type: "timestamp with time zone", ordinal: 4),
                    ]
                ),
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "preseason_match_evaluation_winner_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "winner_id",
                            targetColumn: "id",
                            ordinalPosition: 1
                        ),
                    ]
                ),
            ]
        )
    }

    private func makePreseasonSchemaWithGenericOutcomeFields() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_b_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "result",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 3
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "status",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 4
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "score",
                            dataType: "integer",
                            isNullable: true,
                            ordinalPosition: 5
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makePreseasonSchemaWithWindowTerms() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "window_start",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "winter_status",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 3
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeCustomerSegmentSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "customers",
                            name: "segment",
                            dataType: "user-defined",
                            isNullable: false,
                            ordinalPosition: 1,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .enumValues,
                                    values: ["new", "retained", "churned"]
                                )
                            ]
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeCustomerStateSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "customers",
                            name: "state",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }
}
