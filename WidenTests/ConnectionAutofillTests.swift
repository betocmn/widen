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

    @Test func findsURLInsideEnvAssignment() {
        let details = ConnectionURLParser.details(
            in: "DATABASE_URL=postgres://u:p@host/db\nOTHER=1")
        #expect(details?.host == "host")
        #expect(details?.username == "u")
        #expect(details?.password == "p")
        #expect(details?.database == "db")
        #expect(details?.port == nil)
    }

    @Test func parsesURLWithoutCredentials() {
        let details = ConnectionURLParser.details(in: "postgres://localhost:5432/analytics")
        #expect(details?.host == "localhost")
        #expect(details?.port == 5432)
        #expect(details?.database == "analytics")
        #expect(details?.username == nil)
        #expect(details?.password == nil)
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

    @Test func returnsEmptyDetailsForUnrelatedText() async throws {
        let details = try await MockConnectionDetailsParser().parse("hello world")
        #expect(details.isEmpty)
    }
}

private struct StubParser: ConnectionDetailsParsing {
    var result: Result<ParsedConnectionDetails, AppError>

    func parse(_ text: String) async throws -> ParsedConnectionDetails {
        try result.get()
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
