import Foundation
import Testing

@testable import WidenKit

@Suite("ParsedConnectionDetails")
struct ParsedConnectionDetailsTests {
    @Test func sanitizedTrimsAndDropsEmptyValues() {
        let details = ParsedConnectionDetails.sanitized(
            name: "  Staging  ",
            host: "  db.example.com ",
            port: 5432,
            database: "",
            username: "   ",
            password: " secret ",
            sslModeText: "require"
        )
        #expect(details.name == "Staging")
        #expect(details.host == "db.example.com")
        #expect(details.port == 5432)
        #expect(details.database == nil)
        #expect(details.username == nil)
        #expect(details.password == "secret")
        #expect(details.sslMode == .require)
    }

    @Test func sanitizedPreservesExplicitEmptyPasswordsWhenRequested() {
        #expect(ParsedConnectionDetails.sanitized(password: "").password == nil)
        #expect(
            ParsedConnectionDetails.sanitized(
                password: "", preservesEmptyPassword: true
            ).password == "")
        #expect(
            ParsedConnectionDetails.sanitized(
                password: " secret ", preservesEmptyPassword: true
            ).password == " secret ")
    }

    @Test func sanitizedRejectsOutOfRangePorts() {
        #expect(ParsedConnectionDetails.sanitized(port: 0).port == nil)
        #expect(ParsedConnectionDetails.sanitized(port: 70_000).port == nil)
        #expect(ParsedConnectionDetails.sanitized(port: 65_535).port == 65_535)
    }

    @Test func sanitizedStripsLeadingSlashFromDatabase() {
        #expect(ParsedConnectionDetails.sanitized(database: "/analytics").database == "analytics")
        #expect(ParsedConnectionDetails.sanitized(database: "/").database == nil)
    }

    @Test func sslModeMapsLibpqSpellings() {
        #expect(ParsedConnectionDetails.sslMode(from: "disable") == .disable)
        #expect(ParsedConnectionDetails.sslMode(from: "allow") == .prefer)
        #expect(ParsedConnectionDetails.sslMode(from: "PREFER") == .prefer)
        #expect(ParsedConnectionDetails.sslMode(from: "verify-full") == .require)
        #expect(ParsedConnectionDetails.sslMode(from: "verify-ca") == .require)
        #expect(ParsedConnectionDetails.sslMode(from: "true") == .require)
        #expect(ParsedConnectionDetails.sslMode(from: "on") == .require)
        #expect(ParsedConnectionDetails.sslMode(from: "false") == .disable)
        #expect(ParsedConnectionDetails.sslMode(from: "unknown") == nil)
        #expect(ParsedConnectionDetails.sslMode(from: nil) == nil)
    }

    @Test func isEmptyOnlyWhenNothingWasFound() {
        #expect(ParsedConnectionDetails().isEmpty)
        #expect(!ParsedConnectionDetails(host: "localhost").isEmpty)
        #expect(!ParsedConnectionDetails(sslMode: .prefer).isEmpty)
    }
}

@Suite("ParsedConnectionDetails override")
struct ParsedConnectionDetailsOverrideTests {
    @Test func overrideReplacesOnlyNonNilFields() {
        let base = ParsedConnectionDetails(
            host: "old-host", port: 5432, username: "model-user", password: "from-prose")
        let override = ParsedConnectionDetails(host: "url-host", username: "postgres.ref")

        let merged = base.overridden(by: override)

        #expect(merged.host == "url-host")  // overridden
        #expect(merged.username == "postgres.ref")  // overridden
        #expect(merged.port == 5432)  // kept
        #expect(merged.password == "from-prose")  // kept: override had nil
    }
}

@Suite("ConnectionURLParser")
struct ConnectionURLParserTests {
    @Test func keepsDottedSupabasePoolerUsername() {
        let details = ConnectionURLParser.details(
            in:
                "postgresql://postgres.flzyzmgitfdwaunkugxs:wEb6OkcHF5XBzN8i@aws-1-ap-southeast-2.pooler.supabase.com:6543/postgres"
        )
        #expect(details?.username == "postgres.flzyzmgitfdwaunkugxs")
        #expect(details?.password == "wEb6OkcHF5XBzN8i")
        #expect(details?.host == "aws-1-ap-southeast-2.pooler.supabase.com")
        #expect(details?.port == 6543)
        #expect(details?.database == "postgres")
        #expect(details?.sslMode == nil)
    }

    @Test func decodesPercentEncodedPassword() {
        let details = ConnectionURLParser.details(
            in: "postgres://widen:p%40ss@db.internal:5432/app?sslmode=require")
        #expect(details?.username == "widen")
        #expect(details?.password == "p@ss")
        #expect(details?.sslMode == .require)
    }

    @Test func preservesPercentEncodedPasswordWhitespace() {
        let details = ConnectionURLParser.details(
            in: "postgres://widen:%20secret%20@db.internal/app")
        #expect(details?.password == " secret ")
    }

    @Test func keepsUnencodedSpecialCharactersInPassword() {
        // Real passwords contain unencoded "@" and "/"; the host must still be
        // taken from after the last "@".
        let details = ConnectionURLParser.details(
            in: "postgres://admin:p@ss/word@10.0.0.5:5432/warehouse")
        #expect(details?.username == "admin")
        #expect(details?.password == "p@ss/word")
        #expect(details?.host == "10.0.0.5")
        #expect(details?.port == 5432)
        #expect(details?.database == "warehouse")
    }

    @Test func keepsApostropheInPassword() {
        let details = ConnectionURLParser.details(
            in: "postgres://admin:p'ass@db.internal/warehouse")
        #expect(details?.username == "admin")
        #expect(details?.password == "p'ass")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
    }

    @Test func keepsQuestionMarkInPassword() {
        let details = ConnectionURLParser.details(
            in: "postgres://admin:p?ss@db.internal/warehouse?sslmode=require")
        #expect(details?.username == "admin")
        #expect(details?.password == "p?ss")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
        #expect(details?.sslMode == .require)
    }

    @Test func keepsNumericPasswordPrefixBeforeQuestionMark() {
        let details = ConnectionURLParser.details(in: "postgres://u:123?abc@db.internal/app")
        #expect(details?.username == "u")
        #expect(details?.password == "123?abc")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "app")
    }

    @Test func keepsNumericPasswordPrefixBeforeSlash() {
        let details = ConnectionURLParser.details(in: "postgres://u:123/abc@db.internal/app")
        #expect(details?.username == "u")
        #expect(details?.password == "123/abc")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "app")
    }

    @Test func keepsAtSignBeforeQuestionMarkInPassword() {
        let details = ConnectionURLParser.details(
            in: "postgres://admin:p@ss?word@db.internal/warehouse")
        #expect(details?.username == "admin")
        #expect(details?.password == "p@ss?word")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
    }

    @Test func ignoresAtSignInQueryWhenFindingCredentials() {
        let details = ConnectionURLParser.details(
            in:
                "postgres://admin:secret@db.internal/warehouse?application_name=user@host&sslmode=require"
        )
        #expect(details?.username == "admin")
        #expect(details?.password == "secret")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
        #expect(details?.sslMode == .require)
    }

    @Test func ignoresAtSignInQueryAfterHostPort() {
        let details = ConnectionURLParser.details(
            in:
                "postgres://db.internal:5432/warehouse?application_name=user@host"
        )
        #expect(details?.username == nil)
        #expect(details?.password == nil)
        #expect(details?.host == "db.internal")
        #expect(details?.port == 5432)
        #expect(details?.database == "warehouse")
    }

    @Test func ignoresAtSignInQueryWithoutCredentials() {
        let details = ConnectionURLParser.details(
            in: "postgres://db.internal/warehouse?application_name=user@host&sslmode=require"
        )
        #expect(details?.username == nil)
        #expect(details?.password == nil)
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
        #expect(details?.sslMode == .require)
    }

    @Test func parsesCredentialsFromQueryParameters() {
        let details = ConnectionURLParser.details(
            in: "postgres://db.internal/warehouse?user=etl&password=secret&sslmode=require"
        )
        #expect(details?.username == "etl")
        #expect(details?.password == "secret")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
        #expect(details?.sslMode == .require)
    }

    @Test func parsesSSLQueryAlias() {
        let details = ConnectionURLParser.details(
            in: "postgres://u:p@db.internal/warehouse?ssl=true")
        #expect(details?.sslMode == .require)
    }

    @Test func decodesQueryCredentialsOnlyOnce() {
        let details = ConnectionURLParser.details(
            in: "postgres://db.internal/warehouse?user=etl&password=p%2540ss")
        #expect(details?.username == "etl")
        #expect(details?.password == "p%40ss")
    }

    @Test func trimsWrappingQuoteWithoutSplittingPassword() {
        let details = ConnectionURLParser.details(
            in: "DATABASE_URL='postgres://admin:p'ass@db.internal/warehouse'")
        #expect(details?.password == "p'ass")
        #expect(details?.host == "db.internal")
        #expect(details?.database == "warehouse")
    }

    @Test func stopsJSONURLTokenAtClosingQuote() {
        let details = ConnectionURLParser.details(
            in: #"{"DATABASE_URL":"postgres://u:p@host/db","other":"x"}"#
        )
        #expect(details?.host == "host")
        #expect(details?.database == "db")
        #expect(details?.username == "u")
        #expect(details?.password == "p")
    }

    @Test func findsURLInsideEnvAssignment() {
        let details = ConnectionURLParser.details(
            in: "DATABASE_URL=postgres://u:p@host/db\nOTHER=1")
        #expect(details?.host == "host")
        #expect(details?.username == "u")
        #expect(details?.password == "p")
        #expect(details?.database == "db")
        #expect(details?.port == nil)
    }

    @Test func skipsCommentedOutURLBeforeActiveURL() {
        let details = ConnectionURLParser.details(
            in:
                """
                # DATABASE_URL=postgres://old:secret@old-host/old-db
                DATABASE_URL=postgres://new:secret@new-host/new-db
                """)
        #expect(details?.username == "new")
        #expect(details?.host == "new-host")
        #expect(details?.database == "new-db")
    }

    @Test func ignoresURLInsideInlineComment() {
        let details = ConnectionURLParser.details(
            in: "DB_HOST=db.internal # old postgres://old:secret@old-host/old-db")
        #expect(details == nil)
    }

    @Test func parsesExplicitEmptyPassword() {
        let details = ConnectionURLParser.details(in: "postgres://u:@host/db")
        #expect(details?.host == "host")
        #expect(details?.username == "u")
        #expect(details?.password == "")
        #expect(details?.database == "db")
    }

    @Test func parsesBracketedIPv6HostWithoutPort() {
        let details = ConnectionURLParser.details(in: "postgres://u:p@[::1]/db")
        #expect(details?.host == "::1")
        #expect(details?.port == nil)
        #expect(details?.username == "u")
        #expect(details?.password == "p")
        #expect(details?.database == "db")
    }

    @Test func parsesBracketedIPv6HostWithPort() {
        let details = ConnectionURLParser.details(in: "postgres://u:p@[2001:db8::1]:6543/db")
        #expect(details?.host == "2001:db8::1")
        #expect(details?.port == 6543)
        #expect(details?.database == "db")
    }

    @Test func keepsIPv6BracketWhenTrimmingTrailingPunctuation() {
        let details = ConnectionURLParser.details(in: "postgres://u:p@[::1].")
        #expect(details?.host == "::1")
        #expect(details?.password == "p")
    }

    @Test func trimsTrailingProsePunctuation() {
        let details = ConnectionURLParser.details(
            in: "Use postgres://u:p@host/db?sslmode=require.")
        #expect(details?.host == "host")
        #expect(details?.username == "u")
        #expect(details?.password == "p")
        #expect(details?.database == "db")
        #expect(details?.sslMode == .require)
    }

    @Test func parsesURLWithoutCredentials() {
        let details = ConnectionURLParser.details(in: "postgres://localhost:5432/analytics")
        #expect(details?.host == "localhost")
        #expect(details?.port == 5432)
        #expect(details?.database == "analytics")
        #expect(details?.username == nil)
        #expect(details?.password == nil)
    }

    @Test func parsesHostAndPortFromQueryParameters() {
        let details = ConnectionURLParser.details(
            in: "postgresql:///analytics?host=db.internal&port=5433&user=etl&password=secret")
        #expect(details?.host == "db.internal")
        #expect(details?.port == 5433)
        #expect(details?.database == "analytics")
        #expect(details?.username == "etl")
        #expect(details?.password == "secret")
    }

    @Test func usesFirstEndpointFromMultiHostURI() {
        let details = ConnectionURLParser.details(
            in: "postgresql://host1:5432,host2:5433/analytics")
        #expect(details?.host == "host1")
        #expect(details?.port == 5432)
        #expect(details?.database == "analytics")
    }

    @Test func returnsNilWithoutURL() {
        #expect(ConnectionURLParser.details(in: "just some prose with no url") == nil)
    }
}

@Suite("ConnectionAutofillPromptBuilder")
struct ConnectionAutofillPromptBuilderTests {
    @Test func promptEmbedsPastedText() {
        let prompt = ConnectionAutofillPromptBuilder.prompt(
            for: "postgres://widen@localhost/app")
        #expect(prompt.contains("postgres://widen@localhost/app"))
    }

    @Test func promptTruncatesLongText() {
        let long = String(repeating: "x", count: 10_000)
        let truncated = ConnectionAutofillPromptBuilder.truncated(long)
        #expect(truncated.count == ConnectionAutofillPromptBuilder.maxPastedCharacters + 1)
        #expect(truncated.hasSuffix("…"))
    }
}

@Suite("MockConnectionDetailsParser")
struct MockConnectionDetailsParserTests {
    @Test func parsesConnectionURL() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            "postgres://widen:p%40ss@db.internal:6543/analytics?sslmode=require")
        #expect(details.host == "db.internal")
        #expect(details.port == 6543)
        #expect(details.database == "analytics")
        #expect(details.username == "widen")
        #expect(details.password == "p@ss")
        #expect(details.sslMode == .require)
    }

    @Test func parsesURLInsideEnvAssignment() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            "DATABASE_URL=postgresql://admin:secret@localhost/app")
        #expect(details.host == "localhost")
        #expect(details.username == "admin")
        #expect(details.password == "secret")
        #expect(details.database == "app")
        #expect(details.port == nil)
    }

    @Test func parsesEnvStyleKeyValues() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            export DB_HOST="10.0.0.5"
            DB_PORT=5433
            DB_NAME=warehouse
            DB_USER=etl
            DB_PASSWORD='hunter2'
            DB_SSLMODE=prefer
            """)
        #expect(details.host == "10.0.0.5")
        #expect(details.port == 5433)
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "hunter2")
        #expect(details.sslMode == .prefer)
    }

    @Test func parsesExplicitEmptyPasswordFromKeyValue() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=localhost
            DB_PASSWORD=
            """)
        #expect(details.host == "localhost")
        #expect(details.password == "")
    }

    @Test func stripsInlineCommentsOutsideQuotes() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal # staging
            DB_PASSWORD='p # ss' # keep quoted hash
            """)
        #expect(details.host == "db.internal")
        #expect(details.password == "p # ss")
    }

    @Test func preservesUnspacedHashInValues() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal
            DB_PASSWORD=p#ss
            """)
        #expect(details.password == "p#ss")
    }

    @Test func preservesCommaInUnquotedPasswordValues() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal
            DB_PASSWORD=p,ss
            """)
        #expect(details.host == "db.internal")
        #expect(details.password == "p,ss")
    }

    @Test func preservesURLLikePasswordValues() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal
            DB_PASSWORD=abc://def
            """)
        #expect(details.host == "db.internal")
        #expect(details.password == "abc://def")
    }

    @Test func preservesOppositeQuoteCharactersInsideQuotedPassword() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            #"""
            DB_HOST=db.internal
            DB_PASSWORD="'secret'"
            """#)
        #expect(details.host == "db.internal")
        #expect(details.password == "'secret'")
    }

    @Test func honorsEscapedSingleQuoteInQuotedPassword() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            #"""
            DB_HOST=db.internal
            DB_PASSWORD='pa\'ss'
            """#)
        #expect(details.host == "db.internal")
        #expect(details.password == "pa'ss")
    }

    @Test func ignoresCommentedOutKeyValuePairs() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal
            # DB_PASSWORD=oldsecret
            """)
        #expect(details.host == "db.internal")
        #expect(details.password == nil)
    }

    @Test func passfileKeysDoNotBecomePasswords() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            PGHOST=db.internal
            PGPASSFILE=/Users/me/.pgpass
            POSTGRES_PASSWORD_FILE=/run/secrets/db_password
            """)
        #expect(details.host == "db.internal")
        #expect(details.password == nil)
    }

    @Test func prefersDatabaseSpecificKeysOverOtherServiceKeys() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            API_HOST=api.internal
            API_USER=api
            API_PASSWORD=api-secret
            DB_HOST=db.internal
            DB_USER=etl
            DB_PASSWORD=db-secret
            """)
        #expect(details.host == "db.internal")
        #expect(details.username == "etl")
        #expect(details.password == "db-secret")
    }

    @Test func doesNotUseUnrelatedServicePortFallback() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal
            DB_NAME=warehouse
            REDIS_PORT=6379
            """)
        #expect(details.host == "db.internal")
        #expect(details.database == "warehouse")
        #expect(details.port == nil)
    }

    @Test func inlineCommentURLsDoNotOverrideActiveKeyValues() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_HOST=db.internal # old postgres://old:secret@old-host/old-db
            DB_NAME=warehouse
            DB_USER=etl
            DB_PASSWORD=secret
            """)
        #expect(details.host == "db.internal")
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func prefersDatabaseNameOverDatabaseHost() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DATABASE_HOST=db.internal
            DATABASE_NAME=warehouse
            """)
        #expect(details.host == "db.internal")
        #expect(details.database == "warehouse")
    }

    @Test func databaseMetadataKeysDoNotBecomeDatabaseName() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DATABASE_HOST=db.internal
            DATABASE_USER=etl
            DATABASE_PASSWORD=secret
            """)
        #expect(details.host == "db.internal")
        #expect(details.database == nil)
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func parsesLibpqEnvironmentKeys() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            PGHOST=db.internal
            PGDATABASE=warehouse
            PGUSER=etl
            PGPASSWORD=secret
            """)
        #expect(details.host == "db.internal")
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func parsesSpaceSeparatedInlinePairs() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            "host=db.internal port=5433 dbname=warehouse user=etl password=secret")
        #expect(details.host == "db.internal")
        #expect(details.port == 5433)
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func parsesSemicolonDelimitedConnectionString() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            "Host=db.internal;Port=5433;Database=warehouse;Username=etl;Password=secret")
        #expect(details.host == "db.internal")
        #expect(details.port == 5433)
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func parsesCommaSeparatedColonPairs() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            "host: db.internal, user: etl, password: secret")
        #expect(details.host == "db.internal")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func prefersSSLModeOverOtherSSLKeys() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            PGSSLCERT=/tmp/client.crt
            PGSSLMODE=require
            """)
        #expect(details.sslMode == .require)
    }

    @Test func booleanSSLRequiresTLS() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            DB_SSL=true
            """)
        #expect(details.sslMode == .require)
    }

    @Test func stripsJSONCommasBeforeQuotes() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            "host": "db.internal",
            "port": 5433,
            "database": "warehouse",
            "user": "etl"
            """)
        #expect(details.host == "db.internal")
        #expect(details.port == 5433)
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
    }

    @Test func parsesCompactJSONObject() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            #"{"host":"db.internal","port":5433,"database":"warehouse","username":"etl","password":"secret"}"#
        )
        #expect(details.host == "db.internal")
        #expect(details.port == 5433)
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "secret")
    }

    @Test func parsesCompactJSONDatabaseURLWithoutAdjacentFields() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            #"{"DATABASE_URL":"postgres://u:p@host/db","other":"x"}"#
        )
        #expect(details.host == "host")
        #expect(details.database == "db")
        #expect(details.username == "u")
        #expect(details.password == "p")
    }

    @Test func parsesEscapedJSONDatabaseURL() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            #"{"DATABASE_URL":"postgres:\/\/u:p@host\/db"}"#
        )
        #expect(details.host == "host")
        #expect(details.database == "db")
        #expect(details.username == "u")
        #expect(details.password == "p")
    }

    @Test func parsesPostgresDatabaseKey() async throws {
        let details = try await MockConnectionDetailsParser().parse(
            """
            POSTGRES_HOST=localhost
            POSTGRES_DB=warehouse
            POSTGRES_USER=etl
            POSTGRES_PASSWORD=hunter2
            """)
        #expect(details.host == "localhost")
        #expect(details.database == "warehouse")
        #expect(details.username == "etl")
        #expect(details.password == "hunter2")
    }

    @Test func returnsEmptyDetailsForUnrelatedText() async throws {
        let details = try await MockConnectionDetailsParser().parse("hello world")
        #expect(details.isEmpty)
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Suite("FoundationModelsConnectionParser helpers")
    struct FoundationModelsConnectionParserHelperTests {
        @Test func sslMentionAcceptsTLS() {
            #expect(FoundationModelsConnectionParser.mentionsSSLSetting(in: "TLS required"))
            #expect(FoundationModelsConnectionParser.mentionsSSLSetting(in: "sslmode=require"))
            #expect(!FoundationModelsConnectionParser.mentionsSSLSetting(in: "use a password"))
        }

        @Test func deterministicKeyValuesCanClearModelPassword() {
            let modelDetails = ParsedConnectionDetails(host: "model-host", password: "old-password")
            let deterministicDetails = FoundationModelsConnectionParser.deterministicDetails(
                in:
                    """
                    DB_HOST=db.internal
                    DB_PASSWORD=
                    """,
                urlDetails: nil
            )

            let merged = modelDetails.overridden(by: deterministicDetails!)

            #expect(merged.host == "db.internal")
            #expect(merged.password == "")
        }
    }
#endif

private struct StubParser: ConnectionDetailsParsing {
    var result: Result<ParsedConnectionDetails, AppError>

    func parse(_ text: String) async throws -> ParsedConnectionDetails {
        try result.get()
    }
}

private struct CancellationIgnoringParser: ConnectionDetailsParsing {
    func parse(_ text: String) async throws -> ParsedConnectionDetails {
        try? await Task.sleep(nanoseconds: 1_000_000)
        return ParsedConnectionDetails(host: "late-host", password: "late-password")
    }
}

@Suite("ConnectionSettingsViewModel autofill")
@MainActor
struct ConnectionAutofillViewModelTests {
    @Test func fillsOnlyProvidedFieldsAndClearsPastedText() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "postgres://widen:secret@db.example.com:6543/analytics"
        let details = ParsedConnectionDetails(
            host: "db.example.com",
            port: 6543,
            database: "analytics",
            username: "widen",
            password: "secret",
            sslMode: .require
        )

        let filled = await viewModel.autofill(using: StubParser(result: .success(details)))

        #expect(filled)
        #expect(viewModel.host == "db.example.com")
        #expect(viewModel.portText == "6543")
        #expect(viewModel.database == "analytics")
        #expect(viewModel.username == "widen")
        #expect(viewModel.password == "secret")
        #expect(viewModel.sslMode == .require)
        // Fields the parser did not return keep their values.
        #expect(viewModel.name == "")
        #expect(viewModel.rowLimitText == "100")
        // The pasted text may contain credentials, so success clears it.
        #expect(viewModel.autofillText.isEmpty)
        #expect(viewModel.autofillState == .idle)
        #expect(viewModel.hasUnsavedChanges)
    }

    @Test func keepsExistingValuesForMissingFields() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.host = "old-host"
        viewModel.autofillText = "password is hunter2"

        let filled = await viewModel.autofill(
            using: StubParser(result: .success(ParsedConnectionDetails(password: "hunter2"))))

        #expect(filled)
        #expect(viewModel.host == "old-host")
        #expect(viewModel.password == "hunter2")
    }

    @Test func successfulAutofillClearsStaleValidationErrors() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.host = ""
        viewModel.database = ""
        viewModel.username = ""
        #expect(viewModel.buildConfig() == nil)
        #expect(!viewModel.validationErrors.isEmpty)
        viewModel.autofillText = "host=db.internal dbname=warehouse user=etl"

        let filled = await viewModel.autofill(
            using: StubParser(
                result: .success(
                    ParsedConnectionDetails(
                        host: "db.internal", database: "warehouse", username: "etl"))))

        #expect(filled)
        #expect(viewModel.validationErrors.isEmpty)
    }

    @Test func canceledAutofillDoesNotApplyLateParserResult() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "postgres://late-host/app"

        let task = Task {
            await viewModel.autofill(using: CancellationIgnoringParser())
        }
        task.cancel()
        let filled = await task.value

        #expect(!filled)
        #expect(viewModel.host == "localhost")
        #expect(viewModel.password == "")
        #expect(viewModel.autofillState == .idle)
    }

    @Test func failsOnEmptyPaste() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "   \n  "

        let filled = await viewModel.autofill(
            using: StubParser(result: .success(ParsedConnectionDetails(host: "x"))))

        #expect(!filled)
        #expect(viewModel.autofillState == .failure("Paste the connection details first."))
    }

    @Test func surfacesParserErrors() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "postgres://localhost"

        let filled = await viewModel.autofill(
            using: StubParser(result: .failure(.autofillFailed("nope"))))

        #expect(!filled)
        #expect(viewModel.autofillState == .failure("Autofill failed: nope"))
        // The pasted text stays so the user can edit and retry.
        #expect(viewModel.autofillText == "postgres://localhost")
    }

    @Test func failsWhenNothingWasFound() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "hello world"

        let filled = await viewModel.autofill(
            using: StubParser(result: .success(ParsedConnectionDetails())))

        #expect(!filled)
        if case .failure(let message) = viewModel.autofillState {
            #expect(message.contains("No connection details"))
        } else {
            Issue.record("Expected a failure state.")
        }
    }

    @Test func resetClearsTextAndState() async {
        let viewModel = ConnectionSettingsViewModel(connectionTester: { _, _ in })
        viewModel.autofillText = "hello"
        await viewModel.autofill(using: StubParser(result: .failure(.autofillFailed("nope"))))

        viewModel.resetAutofill()

        #expect(viewModel.autofillText.isEmpty)
        #expect(viewModel.autofillState == .idle)
    }
}
