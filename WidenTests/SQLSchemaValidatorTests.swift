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

    @Test func frequentFeedbackClusterDoesNotAskToDefineFrequent() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT fc.id, COUNT(*) AS feedback_count
                FROM public.feedback_cluster AS fc
                JOIN public.feedback_cluster_membership AS fcm
                  ON fcm.cluster_id = fc.id
                GROUP BY fc.id
                ORDER BY feedback_count DESC
                LIMIT 1
                """,
            explanation: "Finds the cluster with the most feedback memberships.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what is the most frequent feedback cluster?",
            schema: makeFeedbackClusterSchema(),
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.clarificationQuestion == nil)
        #expect(!enriched.groundingConcepts.contains {
            $0.term == "frequent" && $0.required
        })
    }

    @Test func frequentFeedbackClusterIntentGroundsToMembershipRows() {
        let intent = QueryIntentPlanner.deterministicIntent(
            for: "what is the most frequent feedback cluster?"
        )

        #expect(intent.measure == .countRows)
        #expect(intent.ranking?.direction == .descending)
        #expect(intent.ranking?.takeFirst == true)
        #expect(intent.requestedLimit == 1)
        #expect(intent.customBusinessTerms.isEmpty)
        #expect(intent.groupingPhrases == ["feedback cluster"])

        let plan = GroundedQueryPlanner.ground(intent: intent, schema: makeFeedbackClusterSchema())

        #expect(plan.readiness == .readyWithInterpretation)
        #expect(plan.selectedTables.contains("public.feedback_cluster"))
        #expect(plan.selectedTables.contains("public.feedback_cluster_membership"))
        #expect(GroundedQueryPlanner.clarification(for: plan) == nil)
        #expect(plan.slots.contains {
            $0.kind == .occurrenceRelation && $0.state == .grounded
        })
    }

    @Test func multipleOccurrenceRelationsAskAboutRelationshipNotFrequent() {
        let intent = QueryIntentPlanner.deterministicIntent(
            for: "what is the most frequent feedback cluster?"
        )
        let plan = GroundedQueryPlanner.ground(
            intent: intent,
            schema: makeAmbiguousFeedbackClusterSchema()
        )
        let pending = GroundedQueryPlanner.clarification(for: plan)

        #expect(plan.readiness == .needsClarification)
        #expect(pending?.slotID == .occurrenceRelation)
        #expect(pending?.question.localizedCaseInsensitiveContains("frequent") == false)
        #expect(pending?.question.localizedCaseInsensitiveContains("count") == true)
        #expect((pending?.options.count ?? 0) >= 2)
    }

    @Test func confirmedOccurrenceBindingResolvesAmbiguousFrequencySource() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT fc.id, COUNT(*) AS feedback_count
                FROM public.feedback_cluster AS fc
                JOIN public.feedback_cluster_membership AS fcm
                  ON fcm.cluster_id = fc.id
                GROUP BY fc.id
                ORDER BY feedback_count DESC
                LIMIT 1
                """,
            explanation: "Finds the most frequent feedback cluster.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what is the most frequent feedback cluster?",
            schema: makeAmbiguousFeedbackClusterSchema(),
            databaseContext: "",
            confirmedSemanticBindings: [
                "feedback cluster occurrences: fk:feedback_cluster_membership_cluster_fkey, table:public.feedback_cluster_membership"
            ]
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.clarificationQuestion == nil)
        #expect(enriched.sql == generation.sql)
    }

    @Test func disabledGroundingClarificationDoesNotBlockOnIntentAmbiguity() {
        let generation = SQLGenerationResult(
            sql: """
                SELECT fc.id, COUNT(*) AS feedback_count
                FROM public.feedback_cluster AS fc
                JOIN public.feedback_cluster_membership AS fcm
                  ON fcm.cluster_id = fc.id
                GROUP BY fc.id
                ORDER BY feedback_count DESC
                LIMIT 1
                """,
            explanation: "Finds the most frequent feedback cluster.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what is the most frequent feedback cluster?",
            schema: makeAmbiguousFeedbackClusterSchema(),
            databaseContext: "",
            allowGroundingClarification: false
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
    }

    @Test func customMetricTermsProduceMetricClarification() {
        for question in [
            "best customer",
            "healthy account",
            "successful campaign",
            "valuable product",
            "engaged user",
        ] {
            let intent = QueryIntentPlanner.deterministicIntent(for: question)
            let plan = GroundedQueryPlanner.ground(intent: intent, schema: makeUsersOrdersSchema())
            let pending = GroundedQueryPlanner.clarification(for: plan)

            #expect(intent.measure == .custom, "Expected custom metric for: \(question)")
            #expect(pending?.slotID == .customBusinessTerm, "Expected custom slot for: \(question)")
            #expect(pending?.question.localizedCaseInsensitiveContains("metric") == true)
        }
    }

    @Test func databaseContextGroundsCustomTermBeforePlanClarification() {
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.customers WHERE status = 'enabled'",
            explanation: "Lists healthy customers.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "healthy customers",
            schema: makeBestCustomerSchema(),
            databaseContext: "Healthy customers means status = 'enabled'."
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
        #expect(enriched.clarificationQuestion == nil)
    }

    @Test func omittedSchemaTermBlocksWrongOrdinaryRead() {
        let generation = SQLGenerationResult(
            sql: "SELECT id, email FROM public.users LIMIT 100",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show orders",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.localizedCaseInsensitiveContains("orders") == true)
    }

    @Test func customTermMatchingSchemaColumnDoesNotRequireDefinition() {
        let schema = makeUsersWinsSchema()
        let intent = QueryIntentPlanner.deterministicIntent(for: "show users by wins")
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        let customSlot = plan.slots.first { $0.kind == .customBusinessTerm }

        #expect(customSlot?.state == .grounded)
        #expect(customSlot?.selectedCandidate?.objectIDs == ["column:public.users.wins"])
        #expect(GroundedQueryPlanner.clarification(for: plan) == nil)

        let generation = SQLGenerationResult(
            sql: "SELECT id, wins FROM public.users ORDER BY wins DESC LIMIT 100",
            explanation: "Lists users by wins.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show users by wins",
            schema: schema,
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == generation.sql)
    }

    @Test func frequencyIntentConformanceRejectsWrongSQLShapes() {
        let intent = QueryIntentPlanner.deterministicIntent(
            for: "what is the most frequent feedback cluster?"
        )
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: makeFeedbackClusterSchema())
        let schema = makeFeedbackClusterSchema()

        let badSQL = [
            "SELECT DISTINCT cluster_id FROM public.feedback_cluster_membership",
            "SELECT COUNT(*) FROM public.feedback_cluster_membership",
            """
            SELECT cluster_id, COUNT(*) AS n
            FROM public.feedback_cluster_membership
            GROUP BY cluster_id
            ORDER BY n ASC
            LIMIT 1
            """,
            """
            SELECT cluster_id, COUNT(*) AS n
            FROM public.feedback_cluster_membership
            GROUP BY cluster_id
            ORDER BY n DESC
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY n ASC, fc.id DESC
            LIMIT 1
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY fc.id DESC
            LIMIT 1
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM (
              SELECT cluster_id
              FROM public.feedback_cluster_membership
              LIMIT 1
            ) AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY n DESC
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON true
            GROUP BY fc.id
            ORDER BY n DESC
            LIMIT 1
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON true
            WHERE fcm.cluster_id IS NOT NULL AND fc.id IS NOT NULL
            GROUP BY fc.id
            ORDER BY n DESC
            LIMIT 1
            """,
            """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fcm.feedback_item_id
            ORDER BY n DESC
            LIMIT 1
            """,
        ]

        for sql in badSQL {
            let result = SQLIntentConformanceValidator.validate(sql: sql, plan: plan, schema: schema)
            #expect(!result.isValid, "Expected conformance failure for: \(sql)")
        }

        let good = """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY n DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: good, plan: plan, schema: schema).isValid)

        let spacedCount = """
            SELECT fc.id, COUNT (*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY n DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: spacedCount, plan: plan, schema: schema).isValid)

        let newlineGroup = """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP
            BY fc.id
            ORDER BY n DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: newlineGroup, plan: plan, schema: schema).isValid)

        let ordinalOrder = """
            SELECT fc.id, COUNT(*) AS n
            FROM public.feedback_cluster_membership AS fcm
            JOIN public.feedback_cluster AS fc ON fcm.cluster_id = fc.id
            GROUP BY fc.id
            ORDER BY 2 DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: ordinalOrder, plan: plan, schema: schema).isValid)

        let groupedCountCTE = """
            WITH counts AS (
              SELECT fcm.cluster_id, COUNT(*) AS n
              FROM public.feedback_cluster_membership AS fcm
              GROUP BY fcm.cluster_id
            )
            SELECT fc.id, counts.n
            FROM counts
            JOIN public.feedback_cluster AS fc ON counts.cluster_id = fc.id
            ORDER BY counts.n DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: groupedCountCTE, plan: plan, schema: schema).isValid)
    }

    @Test func frequencyIntentConformanceRejectsSiblingGroupingColumn() {
        let schema = makeAnalyticsOperatorSchema()
        let intent = QueryIntentPlanner.deterministicIntent(for: "most common error code")
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        let wrongGrouping = """
            SELECT endpoint, COUNT(*) AS n
            FROM public.events
            GROUP BY endpoint
            ORDER BY n DESC
            LIMIT 1
            """
        let correctGrouping = """
            SELECT error_code, COUNT(*) AS n
            FROM public.events
            GROUP BY error_code
            ORDER BY n DESC
            LIMIT 1
            """

        #expect(!SQLIntentConformanceValidator.validate(sql: wrongGrouping, plan: plan, schema: schema).isValid)
        #expect(SQLIntentConformanceValidator.validate(sql: correctGrouping, plan: plan, schema: schema).isValid)
    }

    @Test func storedCountColumnCanSatisfyFrequencyIntent() {
        let intent = QueryIntentPlanner.deterministicIntent(
            for: "what is the most frequent feedback cluster?"
        )
        let schema = makeFeedbackClusterStoredCountSchema()
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        let sql = """
            SELECT id, feedback_count
            FROM public.feedback_cluster
            ORDER BY feedback_count DESC
            LIMIT 1
            """

        #expect(plan.readiness == .readyWithInterpretation)
        #expect(plan.slots.contains {
            $0.kind == .occurrenceRelation
                && $0.selectedCandidate?.objectIDs.contains("column:public.feedback_cluster.feedback_count") == true
        })
        #expect(SQLIntentConformanceValidator.validate(sql: sql, plan: plan, schema: schema).isValid)

        let enriched = GeneratedSQLPostprocessor.enriched(
            SQLGenerationResult(
                sql: sql,
                explanation: "Finds the cluster with the highest stored feedback count.",
                assumptions: [],
                referencedTables: [],
                confidence: 1,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            ),
            question: "what is the most frequent feedback cluster?",
            schema: schema,
            databaseContext: ""
        )

        #expect(!enriched.needsClarification)
        #expect(enriched.sql == sql)
    }

    @Test func storedCountColumnMustReferenceGroundedTable() {
        let intent = QueryIntentPlanner.deterministicIntent(
            for: "what is the most frequent feedback cluster?"
        )
        let schema = makeFeedbackClusterStoredCountWithSameNamedMetricSchema()
        let plan = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        let wrongTableMetric = """
            SELECT fc.id, other.feedback_count
            FROM public.feedback_cluster AS fc
            JOIN public.other_metric AS other ON other.cluster_id = fc.id
            ORDER BY other.feedback_count DESC
            LIMIT 1
            """

        #expect(!SQLIntentConformanceValidator.validate(sql: wrongTableMetric, plan: plan, schema: schema).isValid)

        let groundedMetric = """
            SELECT fc.id, fc.feedback_count
            FROM public.feedback_cluster AS fc
            JOIN public.other_metric AS other ON other.cluster_id = fc.id
            ORDER BY fc.feedback_count DESC
            LIMIT 1
            """

        #expect(SQLIntentConformanceValidator.validate(sql: groundedMetric, plan: plan, schema: schema).isValid)
    }

    @Test func analyticCompilerBuildsTopCountQuery() {
        let result = AnalyticQueryCompiler.compile(
            question: "what is the most frequent feedback cluster?",
            schema: makeFeedbackClusterSchema(),
            defaultRowLimit: 100
        )

        #expect(result != nil)
        #expect(result?.needsClarification == false)
        #expect(result?.sql.localizedCaseInsensitiveContains("COUNT(*)") == true)
        #expect(result?.sql.localizedCaseInsensitiveContains("GROUP BY") == true)
        #expect(result?.sql.localizedCaseInsensitiveContains("ORDER BY occurrence_count DESC") == true)
        #expect(result?.sql.localizedCaseInsensitiveContains("LIMIT 1") == true)
        #expect(result?.referencedTables == [
            "public.feedback_cluster_membership",
            "public.feedback_cluster",
        ])
    }

    @Test func subjectTableBindingResolvesAmbiguousSubjectSlot() {
        let intent = QueryIntentPlanner.deterministicIntent(for: "show users")
        let schema = makeDuplicateUsersSchema()

        let ambiguous = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        #expect(ambiguous.slots.first { $0.kind == .subjectEntity }?.state == .ambiguous)

        let grounded = GroundedQueryPlanner.ground(
            intent: intent,
            schema: schema,
            confirmedSemanticBindings: ["users: table:auth.users"]
        )

        let subject = grounded.slots.first { $0.kind == .subjectEntity }
        #expect(subject?.state == .grounded)
        #expect(subject?.selectedCandidate?.objectIDs == ["table:auth.users"])
        #expect(grounded.selectedTables == ["auth.users"])
    }

    @Test func subjectTableBindingCanGroundSynonymWithoutLexicalCandidate() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "accounts",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "accounts",
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
        let intent = QueryIntentPlanner.deterministicIntent(for: "show customers")
        let ungrounded = GroundedQueryPlanner.ground(intent: intent, schema: schema)
        let grounded = GroundedQueryPlanner.ground(
            intent: intent,
            schema: schema,
            confirmedSemanticBindings: ["customers: table:public.accounts"]
        )

        #expect(ungrounded.slots.first { $0.kind == .subjectEntity }?.state == .unsupported)
        let subject = grounded.slots.first { $0.kind == .subjectEntity }
        #expect(subject?.state == .grounded)
        #expect(subject?.selectedCandidate?.objectIDs == ["table:public.accounts"])
        #expect(grounded.selectedTables == ["public.accounts"])
    }

    @Test func customMetricBindingObjectsMustConform() {
        let schema = makeBestCustomerSchema()
        let intent = QueryIntentPlanner.deterministicIntent(for: "best customers")
        let plan = GroundedQueryPlanner.ground(
            intent: intent,
            schema: schema,
            confirmedSemanticBindings: ["best: column:public.customers.score"]
        )
        let missingMetric = "SELECT id FROM public.customers"
        let usesMetric = "SELECT id, score FROM public.customers ORDER BY score DESC"

        #expect(!SQLIntentConformanceValidator.validate(sql: missingMetric, plan: plan, schema: schema).isValid)
        #expect(SQLIntentConformanceValidator.validate(sql: usesMetric, plan: plan, schema: schema).isValid)
    }

    @Test func customMetricBindingLiteralsMustConform() {
        let schema = makeBestCustomerSchema()
        let intent = QueryIntentPlanner.deterministicIntent(for: "healthy customers")
        let plan = GroundedQueryPlanner.ground(
            intent: intent,
            schema: schema,
            confirmedSemanticBindings: ["healthy: column:public.customers.status 'enabled'"]
        )
        let wrongLiteral = "SELECT id FROM public.customers WHERE status = 'disabled'"
        let projectedLiteral = "SELECT id, status, 'enabled' AS label FROM public.customers"
        let matchingLiteral = "SELECT id FROM public.customers WHERE status = 'enabled'"

        #expect(!SQLIntentConformanceValidator.validate(sql: wrongLiteral, plan: plan, schema: schema).isValid)
        #expect(!SQLIntentConformanceValidator.validate(sql: projectedLiteral, plan: plan, schema: schema).isValid)
        #expect(SQLIntentConformanceValidator.validate(sql: matchingLiteral, plan: plan, schema: schema).isValid)
    }

    @Test func analyticCompilerSkipsRequestsWithTimeIntent() {
        let result = AnalyticQueryCompiler.compile(
            question: "most common error code last week",
            schema: makeAnalyticsOperatorSchema(),
            defaultRowLimit: 100
        )

        #expect(result == nil)
    }

    @Test func analyticCompilerPreservesSourceSideFrequencyGrouping() {
        let result = AnalyticQueryCompiler.compile(
            question: "most frequent orders",
            schema: makeOrderCustomerSchema(),
            defaultRowLimit: 100
        )

        #expect(result != nil)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"FROM "public"."customers" AS o"#) == true)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"JOIN "public"."orders" AS g"#) == true)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"GROUP BY g."customer_id""#) == true)
    }

    @Test func analyticCompilerBuildsCommonSingleTableQueries() {
        let schema = makeAnalyticsOperatorSchema()
        let cases: [(String, [String])] = [
            (
                "most common error code",
                ["COUNT(*)", #"GROUP BY t."error_code""#, "ORDER BY occurrence_count DESC", "LIMIT 1"]
            ),
            (
                "highest-volume endpoint",
                ["COUNT(*)", #"GROUP BY t."endpoint""#, "ORDER BY occurrence_count DESC", "LIMIT 1"]
            ),
            (
                "latest order",
                [#"ORDER BY t."created_at" DESC"#, "LIMIT 1"]
            ),
            (
                "oldest account",
                [#"ORDER BY t."created_at" ASC"#, "LIMIT 1"]
            ),
            (
                "unique users per organization",
                [#"COUNT(DISTINCT t."user_id")"#, #"GROUP BY t."organization_id""#, "LIMIT 100"]
            ),
            (
                "average orders per day",
                ["AVG(row_count)", #"GROUP BY t."created_at"::date"#]
            ),
        ]

        for (question, expectedFragments) in cases {
            let result = AnalyticQueryCompiler.compile(
                question: question,
                schema: schema,
                defaultRowLimit: 100
            )

            #expect(result != nil, "Expected compiler result for: \(question)")
            #expect(result?.needsClarification == false)
            for fragment in expectedFragments {
                #expect(result?.sql.localizedCaseInsensitiveContains(fragment) == true, "Missing \(fragment) for: \(question)")
            }
        }
    }

    @Test func analyticCompilerOrdersRankedGroupedMeasures() {
        let result = AnalyticQueryCompiler.compile(
            question: "highest total sales by customer",
            schema: makeSalesSchema(),
            defaultRowLimit: 100
        )

        #expect(result != nil)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"SUM(t."total_sales")"#) == true)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"GROUP BY t."customer_id""#) == true)
        let sql = result?.sql ?? ""
        let aliasPrefix = #"SUM(t."total_sales") AS ""#
        let measureAlias = sql
            .components(separatedBy: aliasPrefix)
            .dropFirst()
            .first?
            .split(separator: "\"", maxSplits: 1)
            .first
            .map(String.init)
        #expect(measureAlias != nil)
        #expect(measureAlias.map { sql.localizedCaseInsensitiveContains("ORDER BY \"\($0)\" DESC") } == true)
        #expect(result?.sql.localizedCaseInsensitiveContains("LIMIT 1") == true)
    }

    @Test func analyticCompilerAveragesNumericColumnsBeforeRowCounts() {
        let result = AnalyticQueryCompiler.compile(
            question: "average order total by day",
            schema: makeSalesSchema(),
            defaultRowLimit: 100
        )

        #expect(result != nil)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"AVG(t."order_total")"#) == true)
        #expect(result?.sql.localizedCaseInsensitiveContains("AVG(row_count)") == false)
        #expect(result?.sql.localizedCaseInsensitiveContains(#"GROUP BY t."created_at"::date"#) == true)
    }

    @Test func universalAnalyticalOperatorsDoNotRequireSchemaTokenGrounding() {
        let cases: [(String, String)] = [
            (
                "most common error code",
                "SELECT error_code, COUNT(*) AS n FROM public.events GROUP BY error_code ORDER BY n DESC LIMIT 1"
            ),
            (
                "most recurring failure",
                "SELECT failure_code, COUNT(*) AS n FROM public.events GROUP BY failure_code ORDER BY n DESC LIMIT 1"
            ),
            (
                "highest-volume endpoint",
                "SELECT endpoint, COUNT(*) AS n FROM public.events GROUP BY endpoint ORDER BY n DESC LIMIT 1"
            ),
            (
                "latest order",
                "SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 1"
            ),
            (
                "oldest account",
                "SELECT id FROM public.accounts ORDER BY created_at ASC LIMIT 1"
            ),
            (
                "average orders per day",
                "SELECT AVG(order_count) FROM (SELECT created_at::date AS day, COUNT(*) AS order_count FROM public.orders GROUP BY created_at::date) AS daily"
            ),
            (
                "total revenue by month",
                "SELECT DATE_TRUNC('month', created_at) AS month, SUM(total_cents) FROM public.orders GROUP BY DATE_TRUNC('month', created_at)"
            ),
            (
                "unique users per organization",
                "SELECT organization_id, COUNT(DISTINCT user_id) FROM public.events GROUP BY organization_id"
            ),
        ]

        for (question, sql) in cases {
            let generation = SQLGenerationResult(
                sql: sql,
                explanation: "Generated SQL.",
                assumptions: [],
                referencedTables: [],
                confidence: 1,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            )

            let enriched = GeneratedSQLPostprocessor.enriched(
                generation,
                question: question,
                schema: makeAnalyticsOperatorSchema(),
                databaseContext: ""
            )

            #expect(!enriched.needsClarification, "Unexpected clarification for: \(question)")
            #expect(enriched.clarificationQuestion == nil)
        }
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

    @Test func constrainedStatusInequalityLiteralRequiresAllowedValue() {
        for operatorSQL in ["<>", "!="] {
            let generation = SQLGenerationResult(
                sql: "SELECT COUNT(*) FROM public.users WHERE status \(operatorSQL) 'churned'",
                explanation: "Counts users not churned.",
                assumptions: [],
                referencedTables: [],
                confidence: 1,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            )

            let enriched = GeneratedSQLPostprocessor.enriched(
                generation,
                question: "how many non-churned users?",
                schema: makeUsersStatusSchema(),
                databaseContext: ""
            )

            #expect(enriched.needsClarification, "Expected clarification for \(operatorSQL)")
            #expect(enriched.sql.isEmpty, "Expected SQL to be blocked for \(operatorSQL)")
            #expect(enriched.clarificationQuestion?.contains("\"churned\"") == true)
        }
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

    private func makeFeedbackClusterSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "feedback_cluster",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster", name: "id",
                            dataType: "uuid", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster", name: "label",
                            dataType: "text", isNullable: true, ordinalPosition: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "feedback_item",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_item", name: "id",
                            dataType: "uuid", isNullable: false, ordinalPosition: 1),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "feedback_cluster_membership",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster_membership",
                            name: "cluster_id", dataType: "uuid", isNullable: false,
                            ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster_membership",
                            name: "feedback_item_id", dataType: "uuid", isNullable: false,
                            ordinalPosition: 2),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "feedback_cluster_membership_cluster_fkey",
                    sourceSchema: "public",
                    sourceTable: "feedback_cluster_membership",
                    sourceColumn: "cluster_id",
                    targetSchema: "public",
                    targetTable: "feedback_cluster",
                    targetColumn: "id"
                ),
                ForeignKeyInfo(
                    constraintName: "feedback_cluster_membership_item_fkey",
                    sourceSchema: "public",
                    sourceTable: "feedback_cluster_membership",
                    sourceColumn: "feedback_item_id",
                    targetSchema: "public",
                    targetTable: "feedback_item",
                    targetColumn: "id"
                ),
            ]
        )
    }

    private func makeAmbiguousFeedbackClusterSchema() -> DatabaseSchema {
        var schema = makeFeedbackClusterSchema()
        if let index = schema.tables.firstIndex(where: { $0.name == "feedback_item" }) {
            schema.tables[index].columns.append(
                ColumnInfo(
                    tableSchema: "public",
                    tableName: "feedback_item",
                    name: "cluster_id",
                    dataType: "uuid",
                    isNullable: true,
                    ordinalPosition: 2
                )
            )
        }
        schema.foreignKeys.append(
            ForeignKeyInfo(
                constraintName: "feedback_item_cluster_fkey",
                sourceSchema: "public",
                sourceTable: "feedback_item",
                sourceColumn: "cluster_id",
                targetSchema: "public",
                targetTable: "feedback_cluster",
                targetColumn: "id"
            )
        )
        return schema
    }

    private func makeFeedbackClusterStoredCountSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "feedback_cluster",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster", name: "id",
                            dataType: "uuid", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster",
                            name: "feedback_count", dataType: "integer", isNullable: false,
                            ordinalPosition: 2),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeFeedbackClusterStoredCountWithSameNamedMetricSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "feedback_cluster",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster", name: "id",
                            dataType: "uuid", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "feedback_cluster",
                            name: "feedback_count", dataType: "integer", isNullable: false,
                            ordinalPosition: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "other_metric",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "other_metric", name: "cluster_id",
                            dataType: "uuid", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "other_metric",
                            name: "feedback_count", dataType: "integer", isNullable: false,
                            ordinalPosition: 2),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makeAnalyticsOperatorSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "events",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "error_code",
                            dataType: "text", isNullable: true, ordinalPosition: 2),
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "failure_code",
                            dataType: "text", isNullable: true, ordinalPosition: 3),
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "endpoint",
                            dataType: "text", isNullable: true, ordinalPosition: 4),
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "user_id",
                            dataType: "integer", isNullable: true, ordinalPosition: 5),
                        ColumnInfo(
                            tableSchema: "public", tableName: "events", name: "organization_id",
                            dataType: "integer", isNullable: true, ordinalPosition: 6),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "created_at",
                            dataType: "timestamp with time zone", isNullable: false,
                            ordinalPosition: 2),
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "total_cents",
                            dataType: "integer", isNullable: false, ordinalPosition: 3),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "accounts",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "accounts", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "accounts", name: "created_at",
                            dataType: "timestamp with time zone", isNullable: false,
                            ordinalPosition: 2),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makeOrderCustomerSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "orders", name: "customer_id",
                            dataType: "integer", isNullable: false, ordinalPosition: 2),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "customers", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "orders_customer_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    sourceColumn: "customer_id",
                    targetSchema: "public",
                    targetTable: "customers",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeSalesSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "sales",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "sales", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "sales", name: "customer_id",
                            dataType: "integer", isNullable: false, ordinalPosition: 2),
                        ColumnInfo(
                            tableSchema: "public", tableName: "sales", name: "total_sales",
                            dataType: "integer", isNullable: false, ordinalPosition: 3),
                        ColumnInfo(
                            tableSchema: "public", tableName: "sales", name: "order_total",
                            dataType: "integer", isNullable: false, ordinalPosition: 4),
                        ColumnInfo(
                            tableSchema: "public", tableName: "sales", name: "created_at",
                            dataType: "timestamp with time zone", isNullable: false,
                            ordinalPosition: 5),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeDuplicateUsersSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                    ]
                ),
                TableInfo(
                    schema: "auth",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "auth", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makeBestCustomerSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "customers",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "customers", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "customers", name: "score",
                            dataType: "integer", isNullable: false, ordinalPosition: 2),
                        ColumnInfo(
                            tableSchema: "public", tableName: "customers", name: "status",
                            dataType: "text", isNullable: false, ordinalPosition: 3),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeUsersWinsSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1),
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "wins",
                            dataType: "integer", isNullable: false, ordinalPosition: 2),
                    ]
                )
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
