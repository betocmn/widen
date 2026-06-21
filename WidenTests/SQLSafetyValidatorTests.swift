import Testing

@testable import WidenKit

@Suite("SQLSafetyValidator")
struct SQLSafetyValidatorTests {
    private func validate(_ sql: String) -> SQLValidationResult {
        SQLSafetyValidator.validate(sql)
    }

    // MARK: - Allowed (roadmap list)

    @Test func allowsSimpleSelect() {
        let result = validate("SELECT 1")
        #expect(result.isValid)
        #expect(result.errors.isEmpty)
    }

    @Test func allowsLowercaseSelectStarWithLimit() {
        let result = validate("select * from users limit 10")
        #expect(result.isValid)
        #expect(result.hasLimit)
    }

    @Test func allowsCTEQueries() {
        let result = validate(
            "WITH recent AS (SELECT id FROM orders ORDER BY created_at DESC LIMIT 5) SELECT * FROM recent"
        )
        #expect(result.isValid)
    }

    // MARK: - Rejected (roadmap list)

    @Test(arguments: [
        "DROP TABLE users",
        "SELECT 1; DELETE FROM users",
        "COPY users TO PROGRAM 'rm -rf /'",
        "CALL dangerous_function()",
        "DO $$ BEGIN PERFORM 1; END $$",
        "SELECT pg_sleep(100)",
        "ALTER TABLE users ADD COLUMN x int",
        "TRUNCATE users",
        "CREATE TABLE t (id int)",
    ])
    func rejectsDDLOrDangerousSQL(sql: String) {
        let result = validate(sql)
        #expect(!result.isValid, "expected rejection for: \(sql)")
        #expect(result.normalizedSQL == nil)
    }

    // MARK: - Writes (INSERT / UPDATE / DELETE)

    @Test func allowsInsertWithoutConfirmation() {
        let result = validate("INSERT INTO users (id, email) VALUES (1, 'a@b.com')")
        #expect(result.isValid)
        #expect(result.kind == .insert)
        #expect(!result.requiresConfirmation)
    }

    @Test func upsertDoUpdateRequiresConfirmation() {
        let result = validate(
            "INSERT INTO users (id, name) SELECT id, 'x' FROM staging ON CONFLICT (id) DO UPDATE SET name = excluded.name"
        )
        #expect(result.isValid)
        #expect(result.kind == .insert)
        #expect(result.requiresConfirmation)
    }

    @Test func upsertDoNothingDoesNotRequireConfirmation() {
        let result = validate(
            "INSERT INTO users (id, name) VALUES (1, 'x') ON CONFLICT (id) DO NOTHING")
        #expect(result.isValid)
        #expect(result.kind == .insert)
        #expect(!result.requiresConfirmation)
    }

    @Test func allowsUpdateWithWhereWithoutConfirmation() {
        let result = validate("UPDATE users SET email = 'x' WHERE id = 1")
        #expect(result.isValid)
        #expect(result.kind == .update)
        #expect(!result.requiresConfirmation)
    }

    @Test func updateFromRequiresConfirmationEvenWithWhere() {
        let result = validate("UPDATE users SET email = staging.email FROM staging WHERE staging.ready")
        #expect(result.isValid)
        #expect(result.kind == .update)
        #expect(result.requiresConfirmation)
    }

    @Test func updateWithoutWhereRequiresConfirmation() {
        let result = validate("UPDATE users SET email = 'x'")
        #expect(result.isValid)
        #expect(result.kind == .update)
        #expect(result.requiresConfirmation)
    }

    @Test func updateWithWhereOnlyInSubqueryStillRequiresConfirmation() {
        // The only WHERE is inside a sub-SELECT, so no rows are scoped at the
        // top level — confirmation is still required.
        let result = validate(
            "UPDATE users SET email = (SELECT email FROM staging WHERE id = 1)")
        #expect(result.isValid)
        #expect(result.kind == .update)
        #expect(result.requiresConfirmation)
    }

    @Test func allowsDeleteWithWhereButRequiresConfirmation() {
        let result = validate("DELETE FROM users WHERE id = 1")
        #expect(result.isValid)
        #expect(result.kind == .delete)
        #expect(result.requiresConfirmation)
    }

    @Test func deleteWithoutWhereRequiresConfirmation() {
        let result = validate("DELETE FROM users")
        #expect(result.isValid)
        #expect(result.kind == .delete)
        #expect(result.requiresConfirmation)
    }

    @Test func allowsWriteWithReturning() {
        let result = validate("INSERT INTO users (id) VALUES (1) RETURNING id")
        #expect(result.isValid)
        #expect(result.kind == .insert)
    }

    @Test func selectClassifiesAsReadAndNeverConfirms() {
        let result = validate("SELECT id FROM users WHERE id = 1 LIMIT 1")
        #expect(result.isValid)
        #expect(result.kind == .read)
        #expect(!result.requiresConfirmation)
    }

    @Test func rejectsCTELedWrite() {
        // A data-modifying statement led by WITH is unsupported in v1.
        let result = validate("WITH x AS (SELECT 1) DELETE FROM users WHERE id = 1")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Data-modifying") })
    }

    @Test func rejectsCTELedInsertAndUpdate() {
        let insert = validate("WITH x AS (SELECT 1) INSERT INTO users (id) VALUES (1)")
        #expect(!insert.isValid)
        #expect(insert.errors.contains { $0.contains("Data-modifying") })

        let update = validate("WITH x AS (SELECT 1) UPDATE users SET id = 2 WHERE id = 1")
        #expect(!update.isValid)
        #expect(update.errors.contains { $0.contains("Data-modifying") })
    }

    @Test func rejectsForbiddenFunctionInsideWrite() {
        // Dangerous functions are blocked on the write path too, not just reads.
        let result = validate("INSERT INTO logs (n) SELECT pg_sleep(10)")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("pg_sleep") })
    }

    @Test func rejectsEmptyAndWhitespaceOnlySQL() {
        #expect(!validate("").isValid)
        #expect(!validate("   \n\t ").isValid)
        #expect(!validate(" ; ").isValid)
    }

    @Test func rejectsNonSelectFirstKeyword() {
        let result = validate("EXPLAIN SELECT 1")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Only SELECT, WITH, INSERT, UPDATE, or DELETE") })
    }

    @Test func rejectsMultipleStatements() {
        let result = validate("SELECT 1; SELECT 2")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Multiple statements") })
    }

    @Test func rejectsMutationHiddenInsideCTE() {
        let result = validate(
            "WITH del AS (DELETE FROM users RETURNING id) SELECT * FROM del")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("DELETE") })
    }

    @Test func rejectsDangerousFunctions() {
        #expect(!validate("SELECT lo_import('/etc/passwd')").isValid)
        #expect(!validate("SELECT dblink('host=evil', 'select 1')").isValid)
        #expect(!validate("SELECT lo_export(1234, '/tmp/x')").isValid)
    }

    @Test func rejectsQuotedDangerousFunctionCalls() {
        #expect(!validate(#"SELECT "pg_sleep"(100)"#).isValid)
        #expect(!validate(#"SELECT "pg_catalog"."pg_sleep"(100)"#).isValid)
        #expect(validate(#"SELECT "pg_sleep" FROM metrics LIMIT 1"#).isValid)
    }

    @Test func rejectsSideEffectingAdminFunctions() {
        #expect(!validate("SELECT pg_terminate_backend(123)").isValid)
        #expect(!validate("SELECT pg_cancel_backend(123)").isValid)
        #expect(!validate(#"SELECT "pg_terminate_backend"(123)"#).isValid)
    }

    @Test func rejectsServerFileFunctions() {
        #expect(!validate("SELECT pg_read_file('/etc/passwd')").isValid)
        #expect(!validate("SELECT pg_read_binary_file('/etc/passwd')").isValid)
        #expect(!validate("SELECT pg_ls_dir('.')").isValid)
        #expect(!validate("SELECT pg_ls_logdir()").isValid)
        #expect(!validate("SELECT pg_ls_waldir()").isValid)
        #expect(!validate("SELECT pg_ls_archive_statusdir()").isValid)
        #expect(!validate("SELECT pg_ls_tmpdir()").isValid)
        #expect(!validate("SELECT pg_stat_file('/etc/passwd')").isValid)
    }

    @Test func rejectsSelectForUpdateLockClause() {
        // FOR UPDATE takes row locks; the UPDATE token rejection is intended.
        #expect(!validate("SELECT * FROM users FOR UPDATE").isValid)
    }

    @Test func rejectsUnterminatedString() {
        let result = validate("SELECT 'abc")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("unterminated") })
    }

    @Test func rejectsSetAndTransactionControl() {
        #expect(!validate("SET statement_timeout = 0").isValid)
        #expect(!validate("BEGIN").isValid)
        #expect(!validate("COMMIT").isValid)
        #expect(!validate("ROLLBACK").isValid)
        #expect(!validate("RESET ALL").isValid)
    }

    @Test func rejectsAggregateWrappedAroundWindowFunction() {
        let result = validate(
            "SELECT AVG(COUNT(*) OVER (PARTITION BY created_at)) FROM public.orders"
        )

        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Aggregate functions cannot contain") })
    }

    @Test func rejectsAggregateWrappedAroundAggregateFunction() {
        let result = validate(
            "SELECT AVG(COUNT(*) / DAY(created_at)) FROM public.orders GROUP BY DAY(created_at)"
        )

        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("other aggregate functions") })
    }

    @Test func allowsAggregateWindowOverGroupedAggregate() {
        let result = validate(
            "SELECT COUNT(*) / SUM(COUNT(*)) OVER () FROM public.orders GROUP BY user_id"
        )

        #expect(result.isValid)
    }

    @Test func allowsAggregateInsideScalarSubqueryArgument() {
        let result = validate(
            "SELECT SUM((SELECT COUNT(*) FROM public.orders)) FROM public.users"
        )

        #expect(result.isValid)
    }

    @Test func allowsAverageOfCountsFromCTE() {
        let result = validate(
            """
            WITH daily_counts AS (
              SELECT DATE_TRUNC('day', created_at) AS day, COUNT(*) AS order_count
              FROM public.orders
              GROUP BY 1
            )
            SELECT AVG(order_count) FROM daily_counts
            """
        )

        #expect(result.isValid)
    }

    @Test func allowsAggregateUsedAsWindowFunction() {
        let result = validate(
            "SELECT AVG(total_cents) OVER (PARTITION BY user_id) FROM public.orders LIMIT 100"
        )

        #expect(result.isValid)
    }

    // MARK: - Comments, strings, identifiers must not fool the checks

    @Test func keywordInsideLineCommentIsIgnored() {
        let result = validate("SELECT 1 -- DROP TABLE users\nLIMIT 1")
        #expect(result.isValid)
    }

    @Test func keywordInsideNestedBlockCommentIsIgnored() {
        let result = validate("SELECT 1 /* outer /* DELETE FROM users */ note */ LIMIT 1")
        #expect(result.isValid)
    }

    @Test func unterminatedBlockCommentIsRejected() {
        #expect(!validate("SELECT 1 /* DELETE FROM users").isValid)
    }

    @Test func keywordInsideStringLiteralIsIgnored() {
        let result = validate("SELECT 'DELETE FROM users' AS note LIMIT 1")
        #expect(result.isValid)
    }

    @Test func escapedQuotesInsideStringsAreHandled() {
        let result = validate("SELECT 'it''s a DROP TABLE trap' AS note LIMIT 1")
        #expect(result.isValid)
    }

    @Test func standardStringBackslashDoesNotHideSemicolon() {
        let result = validate(#"SELECT '\' AS x; SELECT pg_sleep(10); --' LIMIT 1"#)
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Multiple statements") })
        #expect(result.errors.contains { $0.contains("pg_sleep") })
    }

    @Test func escapeStringBackslashCanEscapeQuote() {
        let result = validate(#"SELECT E'it\'s ok' AS note LIMIT 1"#)
        #expect(result.isValid)
    }

    @Test func keywordInsideQuotedIdentifierIsIgnored() {
        let result = validate("SELECT \"drop table\" FROM t LIMIT 1")
        #expect(result.isValid)
    }

    @Test func keywordInsideDollarQuotedStringIsIgnored() {
        let result = validate("SELECT $tag$ DELETE FROM users $tag$ AS note LIMIT 1")
        #expect(result.isValid)
    }

    @Test func identifiersContainingKeywordsAreAllowed() {
        // `created_at` must not match CREATE, `updated_at` must not match UPDATE.
        let result = validate("SELECT created_at, updated_at, dropped FROM events LIMIT 5")
        #expect(result.isValid)
    }

    @Test func semicolonInsideStringIsAllowed() {
        let result = validate("SELECT 'a;b' AS v LIMIT 1")
        #expect(result.isValid)
    }

    @Test func noWhitespaceAroundStarStillParses() {
        let result = validate("select*from users limit 10")
        #expect(result.isValid)
        #expect(result.hasLimit)
    }

    // MARK: - Normalization

    @Test func allowsSingleTrailingSemicolon() {
        let result = validate("SELECT 1;")
        #expect(result.isValid)
        #expect(result.normalizedSQL == "SELECT 1")
    }

    @Test func rejectsDoubleTrailingSemicolons() {
        // Only one trailing semicolon is trimmed; the leftover one is treated
        // as a statement separator.
        #expect(!validate("SELECT 1;;").isValid)
    }

    // MARK: - Warnings and hasLimit

    @Test func warnsWhenLimitIsMissing() {
        let result = validate("SELECT id FROM users")
        #expect(result.isValid)
        #expect(!result.hasLimit)
        #expect(result.warnings.contains { $0.contains("LIMIT") })
    }

    @Test func warnsOnSelectStar() {
        let result = validate("SELECT * FROM users LIMIT 5")
        #expect(result.isValid)
        #expect(result.warnings.contains { $0.contains("SELECT *") })
    }

    @Test func warnsWhenNoWhereClause() {
        let result = validate("SELECT id FROM users LIMIT 5")
        #expect(result.isValid)
        #expect(result.warnings.contains { $0.contains("WHERE") })
    }

    @Test func noWarningsForScopedQuery() {
        let result = validate("SELECT id FROM users WHERE id = 1 LIMIT 1")
        #expect(result.isValid)
        #expect(result.warnings.isEmpty)
    }

    @Test func aggregateWithoutLimitIsValidButFlagged() {
        let result = validate("SELECT count(id) FROM users WHERE id > 0")
        #expect(result.isValid)
        #expect(!result.hasLimit)
    }

    @Test func nestedLimitDoesNotCountAsTopLevelLimit() {
        let result = validate(
            "WITH recent AS (SELECT id FROM orders LIMIT 10) SELECT * FROM users")
        #expect(result.isValid)
        #expect(!result.hasLimit)
        #expect(result.warnings.contains { $0.contains("LIMIT") })
    }

    @Test func topLevelLimitAfterCTECounts() {
        let result = validate(
            "WITH recent AS (SELECT id FROM orders LIMIT 10) SELECT * FROM recent LIMIT 5")
        #expect(result.isValid)
        #expect(result.hasLimit)
    }

    @Test func limitAllAndNullDoNotCountAsBoundedLimits() {
        let limitAll = validate("SELECT * FROM users LIMIT ALL")
        #expect(limitAll.isValid)
        #expect(!limitAll.hasLimit)
        #expect(limitAll.warnings.contains { $0.contains("LIMIT") })

        let limitNull = validate("SELECT * FROM users LIMIT NULL")
        #expect(limitNull.isValid)
        #expect(!limitNull.hasLimit)

        let parenthesizedNull = validate("SELECT * FROM users LIMIT (NULL)")
        #expect(parenthesizedNull.isValid)
        #expect(!parenthesizedNull.hasLimit)
    }
}
