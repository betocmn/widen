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
        "DELETE FROM users",
        "DROP TABLE users",
        "SELECT 1; DELETE FROM users",
        "UPDATE users SET email = 'x'",
        "COPY users TO PROGRAM 'rm -rf /'",
        "CALL dangerous_function()",
        "DO $$ BEGIN PERFORM 1; END $$",
        "SELECT pg_sleep(100)",
    ])
    func rejectsMutatingOrDangerousSQL(sql: String) {
        let result = validate(sql)
        #expect(!result.isValid, "expected rejection for: \(sql)")
        #expect(result.normalizedSQL == nil)
    }

    @Test func rejectsEmptyAndWhitespaceOnlySQL() {
        #expect(!validate("").isValid)
        #expect(!validate("   \n\t ").isValid)
        #expect(!validate(" ; ").isValid)
    }

    @Test func rejectsNonSelectFirstKeyword() {
        let result = validate("EXPLAIN SELECT 1")
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("Only SELECT or WITH") })
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
}
