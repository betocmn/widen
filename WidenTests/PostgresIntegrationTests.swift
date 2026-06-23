import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WidenKit

/// Integration tests against a real local PostgreSQL server.
///
/// Skipped unless the `WIDEN_TEST_DB` environment variable is set (see
/// `make test-db`). Its value is only an on/off switch — each test provisions
/// its OWN uniquely-named throwaway database, seeds it when it needs the sample
/// data, and drops it afterward, so the suite never shares state with a
/// developer's manual-testing database (and cannot drift when that database is
/// poked by hand). The only requirement is a reachable server whose role can
/// CREATE DATABASE on localhost:5432.
private let integrationEnabled =
    ProcessInfo.processInfo.environment["WIDEN_TEST_DB"] != nil
    || ProcessInfo.processInfo.environment["TEST_RUNNER_WIDEN_TEST_DB"] != nil

private enum IntegrationServer {
    static let host = "localhost"
    static let port = 5432
    static let username = NSUserName()
    /// Always-present database, used only to issue CREATE/DROP DATABASE.
    static let maintenanceDatabase = "postgres"

    /// Sample schema + data, mirrored from `scripts/sample_db.sql`. Seeded into
    /// a fresh database for tests that read the sample tables. Kept as separate
    /// statements because the wire protocol runs one command per message.
    static let seedStatements = [
        """
        CREATE TABLE users (
          id SERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          name TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE orders (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id),
          total_cents INTEGER NOT NULL,
          status TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """,
        """
        INSERT INTO users (email, name, created_at) VALUES
        ('alice@example.com', 'Alice', now() - interval '10 days'),
        ('bob@example.com', 'Bob', now() - interval '5 days'),
        ('carla@example.com', 'Carla', now() - interval '1 day')
        """,
        """
        INSERT INTO orders (user_id, total_cents, status, created_at) VALUES
        (1, 2500, 'paid', now() - interval '9 days'),
        (1, 4500, 'paid', now() - interval '4 days'),
        (2, 1200, 'refunded', now() - interval '3 days'),
        (3, 9900, 'paid', now() - interval '1 day')
        """,
    ]

    static func config(
        database: String,
        username: String? = nil,
        rowLimit: Int = 100,
        timeoutSeconds: Int = 5
    ) -> DatabaseConnectionConfig {
        DatabaseConnectionConfig(
            name: "Integration",
            host: host,
            port: port,
            database: database,
            username: username ?? self.username,
            defaultRowLimit: rowLimit,
            statementTimeoutSeconds: timeoutSeconds
        )
    }
}

/// Runs each statement in `statements` against `database` on a throwaway direct
/// connection, one command per message. `simpleQuery` permits statements that
/// cannot run inside a transaction block — like CREATE/DROP DATABASE — which the
/// pooled, parameterized path would reject.
private func runStatements(_ statements: [String], on database: String) async throws {
    let configuration = try PostgresService.makeConnectionConfiguration(
        IntegrationServer.config(database: database), password: nil)
    var logger = Logger(label: "widen.tests")
    logger.logLevel = .critical
    let connection = try await PostgresConnection.connect(
        on: PostgresConnection.defaultEventLoopGroup.any(),
        configuration: configuration,
        id: 1,
        logger: logger
    )
    do {
        for statement in statements {
            _ = try await connection.simpleQuery(statement).get()
        }
        try await connection.close()
    } catch {
        try? await connection.close()
        throw error
    }
}

/// Provisions a fresh, uniquely-named database (optionally seeded with the
/// sample data), connects a `PostgresService` to it, runs `body`, and drops the
/// database afterward — so every test starts from a known, isolated state.
private func withDatabase<T>(
    seeded: Bool = false,
    rowLimit: Int = 100,
    timeoutSeconds: Int = 5,
    _ body: (DatabaseConnectionConfig, PostgresService) async throws -> T
) async throws -> T {
    let name =
        "widen_it_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    try await runStatements(
        ["CREATE DATABASE \"\(name)\""], on: IntegrationServer.maintenanceDatabase)

    func drop() async {
        try? await runStatements(
            ["DROP DATABASE IF EXISTS \"\(name)\" WITH (FORCE)"],
            on: IntegrationServer.maintenanceDatabase)
    }

    do {
        if seeded {
            try await runStatements(IntegrationServer.seedStatements, on: name)
        }
        let config = IntegrationServer.config(
            database: name, rowLimit: rowLimit, timeoutSeconds: timeoutSeconds)
        let service = PostgresService()
        try await service.connect(config: config, password: nil)
        do {
            let value = try await body(config, service)
            await service.disconnect()
            await drop()
            return value
        } catch {
            await service.disconnect()
            await drop()
            throw error
        }
    } catch {
        await drop()
        throw error
    }
}

@Suite("Postgres integration", .enabled(if: integrationEnabled), .serialized)
struct PostgresIntegrationTests {
    @Test func testConnectionSucceeds() async throws {
        try await withDatabase { config, _ in
            try await PostgresService.testConnection(config: config, password: nil)
        }
    }

    @Test func missingDatabaseProducesUsefulError() async {
        do {
            try await PostgresService.testConnection(
                config: IntegrationServer.config(database: "widen_definitely_missing_db"),
                password: nil
            )
            Issue.record("Expected the connection to fail")
        } catch let error as AppError {
            guard case .databaseNotFound = error else {
                Issue.record("Expected databaseNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected an AppError, got \(error)")
        }
    }

    @Test func invalidUserProducesUsefulError() async {
        do {
            try await PostgresService.testConnection(
                config: IntegrationServer.config(
                    database: IntegrationServer.maintenanceDatabase,
                    username: "widen_invalid_user"),
                password: "wrong"
            )
            Issue.record("Expected the connection to fail")
        } catch let error as AppError {
            guard case .authenticationFailed = error else {
                Issue.record("Expected authenticationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected an AppError, got \(error)")
        }
    }

    @Test func connectRunSelectOneAndDisconnect() async throws {
        try await withDatabase { _, service in
            let connected = await service.isConnected
            #expect(connected)

            let values = try await service.query("SELECT 1 AS ok") { row in
                try row["ok"].decode(Int32.self)
            }
            #expect(values == [1])
        }
    }

    @Test func introspectsSampleSchema() async throws {
        try await withDatabase(seeded: true) { _, service in
            let schema = try await SchemaIntrospectionService().loadSchema(using: service)

            let users = try #require(
                schema.tables.first { $0.schema == "public" && $0.name == "users" })
            #expect(users.columns.map(\.name) == ["id", "email", "name", "created_at"])
            #expect(users.columns.first { $0.name == "email" }?.isNullable == false)
            #expect(users.columns.first { $0.name == "name" }?.isNullable == true)

            let orders = try #require(
                schema.tables.first { $0.schema == "public" && $0.name == "orders" })
            #expect(orders.columns.count == 5)

            #expect(
                schema.foreignKeys.contains {
                    $0.sourceTable == "orders" && $0.sourceColumn == "user_id"
                        && $0.targetTable == "users" && $0.targetColumn == "id"
                })

            #expect(schema.schemas.contains { $0.name == "public" })
            #expect(
                !schema.tables.contains {
                    $0.schema.hasPrefix("pg_") || $0.schema == "information_schema"
                })
        }
    }

    @Test func introspectsEnumAndCheckColumnValueConstraints() async throws {
        try await withDatabase { config, service in
            try await runStatements(
                [
                    "CREATE TYPE winner_decision AS ENUM ('tool_a', 'tool_b', 'tie')",
                    """
                    CREATE TABLE match_evaluations (
                      id SERIAL PRIMARY KEY,
                      winner_decision winner_decision NOT NULL,
                      review_status TEXT NOT NULL CHECK (review_status IN ('approved', 'rejected'))
                    )
                    """,
                ],
                on: config.database
            )

            let schema = try await SchemaIntrospectionService().loadSchema(using: service)
            let table = try #require(
                schema.tables.first { $0.schema == "public" && $0.name == "match_evaluations" })

            let winnerDecision = try #require(
                table.columns.first { $0.name == "winner_decision" })
            #expect(winnerDecision.udtSchema == "public")
            #expect(winnerDecision.udtName == "winner_decision")
            #expect(
                winnerDecision.valueConstraints?.contains(
                    ColumnValueConstraint(
                        kind: .enumValues,
                        values: ["tool_a", "tool_b", "tie"]
                    )) == true)

            let reviewStatus = try #require(table.columns.first { $0.name == "review_status" })
            let check = try #require(
                reviewStatus.valueConstraints?.first { $0.kind == .check })
            #expect(check.values == ["approved", "rejected"])
            #expect(check.expression?.contains("review_status") == true)
        }
    }

    @Test func queryWithoutConnectionThrowsNotConnected() async {
        let service = PostgresService()
        await #expect(throws: AppError.notConnected) {
            _ = try await service.query("SELECT 1") { _ in 0 }
        }
    }
}

@Suite("Query execution integration", .enabled(if: integrationEnabled), .serialized)
struct QueryExecutionIntegrationTests {
    @Test func runsSimpleSelect() async throws {
        try await withDatabase { config, service in
            let result = try await QueryExecutionService().run(
                sql: "SELECT 1 AS test", config: config, postgres: service)
            #expect(result.columns == ["test"])
            #expect(result.rows == [["1"]])
            #expect(result.rowCount == 1)
            #expect(!result.truncated)
        }
    }

    @Test func runsTableSelectWithCommonTypes() async throws {
        try await withDatabase(seeded: true) { config, service in
            let result = try await QueryExecutionService().run(
                sql: "SELECT id, email, name, created_at FROM users ORDER BY id LIMIT 10",
                config: config,
                postgres: service
            )
            #expect(result.columns == ["id", "email", "name", "created_at"])
            #expect(result.rowCount == 3)
            #expect(result.rows[0][1] == "alice@example.com")
            // timestamptz renders as an ISO-ish string
            #expect(result.rows[0][3]?.contains("T") == true)
        }
    }

    @Test func stringifiesBoolNumericUUIDJsonAndNull() async throws {
        let sql = """
            SELECT true AS flag,
                   3.14::numeric AS amount,
                   gen_random_uuid() AS uid,
                   '{"a": 1}'::jsonb AS payload,
                   NULL::text AS missing
            LIMIT 1
            """
        try await withDatabase { config, service in
            let result = try await QueryExecutionService().run(
                sql: sql, config: config, postgres: service)
            let row = try #require(result.rows.first)
            #expect(row[0] == "true")
            #expect(row[1] == "3.14")
            #expect(row[2]?.count == 36)
            #expect(row[3]?.contains("\"a\"") == true)
            #expect(row[4] == nil)
        }
    }

    @Test func appliesDefaultLimitAndReportsTruncation() async throws {
        try await withDatabase(seeded: true, rowLimit: 2) { config, service in
            let result = try await QueryExecutionService().run(
                sql: "SELECT id FROM orders ORDER BY id",
                config: config,
                postgres: service
            )
            #expect(result.rowCount == 2)
            #expect(result.truncated)
        }
    }

    @Test func userLimitRunsAsIs() async throws {
        try await withDatabase(seeded: true) { config, service in
            let result = try await QueryExecutionService().run(
                sql: "SELECT id FROM orders ORDER BY id LIMIT 1",
                config: config,
                postgres: service
            )
            #expect(result.rowCount == 1)
            #expect(!result.truncated)
        }
    }

    @Test func emptySelectPreservesColumnHeaders() async throws {
        try await withDatabase(seeded: true) { config, service in
            let result = try await QueryExecutionService().run(
                sql: "SELECT id, email FROM users WHERE false",
                config: config,
                postgres: service
            )
            #expect(result.columns == ["id", "email"])
            #expect(result.rows.isEmpty)
            #expect(result.csv() == "id,email")
        }
    }

    @Test func writeSQLIsRefusedOnTheReadPath() async throws {
        try await withDatabase(seeded: true) { config, service in
            do {
                // `run` is the path the auto-retry loop uses; it must refuse
                // writes before they reach the server.
                _ = try await QueryExecutionService().run(
                    sql: "DELETE FROM users", config: config, postgres: service)
                Issue.record("Expected the read path to refuse the write")
            } catch let error as AppError {
                guard case .executionFailed = error else {
                    Issue.record("Expected executionFailed, got \(error)")
                    return
                }
            }
            // The table is untouched.
            let counts = try await service.query("SELECT count(*) AS n FROM users") { row in
                try row["n"].decode(Int64.self)
            }
            #expect(counts == [3])
        }
    }

    @Test func executesWritesReportsAffectedRowsAndCommits() async throws {
        try await withDatabase { config, service in
            _ = try await service.query("CREATE TABLE t (id int primary key, label text)") { _ in 0 }

            // INSERT … RETURNING: rowCount is the affected count; columns/rows
            // carry the RETURNING projection.
            let insert = try await QueryExecutionService().runWrite(
                sql: "INSERT INTO t (id, label) VALUES (1, 'a'), (2, 'b') RETURNING id",
                config: config, postgres: service, confirmedDangerous: false)
            #expect(insert.kind == .insert)
            #expect(insert.rowCount == 2)
            #expect(insert.columns == ["id"])
            #expect(insert.rows.count == 2)

            // UPDATE with a WHERE runs without confirmation and reports affected
            // rows with no RETURNING projection.
            let update = try await QueryExecutionService().runWrite(
                sql: "UPDATE t SET label = 'x' WHERE id = 1",
                config: config, postgres: service, confirmedDangerous: false)
            #expect(update.kind == .update)
            #expect(update.rowCount == 1)
            #expect(update.rows.isEmpty)

            // A DELETE requires confirmation: unconfirmed is refused.
            do {
                _ = try await QueryExecutionService().runWrite(
                    sql: "DELETE FROM t WHERE id = 2",
                    config: config, postgres: service, confirmedDangerous: false)
                Issue.record("Expected the unconfirmed DELETE to be refused")
            } catch let error as AppError {
                guard case .executionFailed = error else {
                    Issue.record("Expected executionFailed, got \(error)")
                    return
                }
            }

            // Confirmed DELETE runs and commits.
            let delete = try await QueryExecutionService().runWrite(
                sql: "DELETE FROM t WHERE id = 2",
                config: config, postgres: service, confirmedDangerous: true)
            #expect(delete.kind == .delete)
            #expect(delete.rowCount == 1)

            // The writes committed: id 2 is gone, id 1 remains.
            let counts = try await service.query("SELECT count(*) AS n FROM t") { row in
                try row["n"].decode(Int64.self)
            }
            #expect(counts == [1])
        }
    }

    @Test func writeWithLargeReturningIsCappedForDisplay() async throws {
        try await withDatabase(rowLimit: 1) { config, service in
            _ = try await service.query("CREATE TABLE t (id int)") { _ in 0 }

            // Three rows affected, but display rows are capped at rowLimit and
            // flagged truncated — `rowCount` still reports the true count.
            let insert = try await QueryExecutionService().runWrite(
                sql: "INSERT INTO t (id) VALUES (1), (2), (3) RETURNING id",
                config: config, postgres: service, confirmedDangerous: false)
            #expect(insert.rowCount == 3)
            #expect(insert.rows.count == 1)
            #expect(insert.truncated)
        }
    }

    @Test func statementTimeoutCancelsLongQueries() async throws {
        try await withDatabase(timeoutSeconds: 1) { config, service in
            do {
                _ = try await QueryExecutionService().run(
                    sql: "SELECT count(*) AS n FROM generate_series(1, 500000000)",
                    config: config,
                    postgres: service
                )
                Issue.record("Expected the statement timeout to fire")
            } catch let error as AppError {
                guard case .databaseFailed(let diagnostic) = error else {
                    Issue.record("Expected databaseFailed timeout diagnostic, got \(error)")
                    return
                }
                #expect(diagnostic.kind == .timedOut)
                #expect(diagnostic.sqlState == "57014")
                #expect(error.localizedDescription == AppError.queryTimeout.localizedDescription)
            }
            // The connection is healthy again after ROLLBACK.
            let values = try await service.query("SELECT 1 AS ok") { row in
                try row["ok"].decode(Int32.self)
            }
            #expect(values == [1])
        }
    }
}

@Suite("Semantic eval database integration", .enabled(if: integrationEnabled), .serialized)
struct TextToSQLSemanticDatabaseIntegrationTests {
    @Test func fixturesMatchSchemaAndNegativeControlsFailEquivalence() async throws {
        let root = repositoryRoot()
        let suiteURL = root.appendingPathComponent("Evals/suites/text-to-sql-v1.json")
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(TextToSQLEvalSuite.self, from: suiteData)
        let schemaDirectory = root.appendingPathComponent("Evals/schemas", isDirectory: true)
        let databaseDirectory = root.appendingPathComponent("Evals/databases", isDirectory: true)
        let server = semanticServer()
        let provisioner = TextToSQLSemanticDatabaseProvisioner(server: server)
        let executor = TextToSQLSemanticExecutor()
        var provisioned: [TextToSQLSemanticProvisionedDatabase] = []

        do {
            let fixtures = Set(suite.cases.map(\.schemaFixture))
            for fixture in fixtures.sorted() {
                let schema = try loadSchema(fixture, from: schemaDirectory)
                let database = try await provisioner.provision(
                    fixture: fixture,
                    setupURL: databaseDirectory
                        .appendingPathComponent(fixture, isDirectory: true)
                        .appendingPathComponent("setup.json"),
                    expectedSchema: schema
                )
                provisioned.append(database)

                for evalCase in suite.cases
                    where evalCase.schemaFixture == fixture && evalCase.expected.decision == .sql
                {
                    let goldenSQL = try #require(evalCase.expected.goldenSQL)
                    let semantic = try #require(evalCase.expected.semantic)
                    let golden = try await executor.executePair(
                        goldenSQL: goldenSQL,
                        candidateSQL: goldenSQL,
                        expectation: semantic,
                        config: database.config,
                        password: server.password
                    )
                    #expect(golden.goldenExecutionSucceeded)
                    #expect(golden.candidateExecutionSucceeded)
                    #expect(golden.comparison?.equivalent == true)

                    for negative in semantic.negativeControls {
                        var expectation = semantic
                        if let mode = negative.comparisonMode {
                            expectation.comparisonMode = mode
                        }
                        let output = try await executor.executePair(
                            goldenSQL: goldenSQL,
                            candidateSQL: negative.sql,
                            expectation: expectation,
                            config: database.config,
                            password: server.password
                        )
                        #expect(
                            output.goldenExecutionSucceeded,
                            "golden failed for \(evalCase.id): \(output.goldenError ?? "-")"
                        )
                        #expect(
                            output.candidateExecutionSucceeded,
                            "negative failed to execute for \(evalCase.id).\(negative.id): \(output.candidateError ?? "-")"
                        )
                        #expect(
                            output.comparison?.equivalent == false,
                            "negative control unexpectedly matched \(evalCase.id).\(negative.id)"
                        )
                    }
                }
            }
            for database in provisioned {
                await provisioner.drop(database)
            }
        } catch {
            for database in provisioned {
                await provisioner.drop(database)
            }
            throw error
        }
    }

    @Test func schemaDriftIsDetectedBeforeModelExecution() async throws {
        let root = repositoryRoot()
        let schema = try loadSchema(
            "commerce",
            from: root.appendingPathComponent("Evals/schemas", isDirectory: true)
        )
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-drift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let setupURL = tempDirectory.appendingPathComponent("setup.json")
        let statements = [
            "CREATE TABLE public.customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL, name TEXT, country TEXT, created_at TIMESTAMPTZ NOT NULL)",
            "CREATE TABLE public.orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES public.customers(id), status TEXT NOT NULL, total_cents INTEGER NOT NULL, created_at TIMESTAMPTZ NOT NULL)",
        ]
        try JSONEncoder().encode(statements).write(to: setupURL)

        let provisioner = TextToSQLSemanticDatabaseProvisioner(server: semanticServer())
        await #expect(throws: TextToSQLSemanticDatabaseError.self) {
            _ = try await provisioner.provision(
                fixture: "commerce-drift",
                setupURL: setupURL,
                expectedSchema: schema
            )
        }
    }

    @Test func candidateRunsInsideReadOnlyTransaction() async throws {
        let root = repositoryRoot()
        let schema = try loadSchema(
            "commerce",
            from: root.appendingPathComponent("Evals/schemas", isDirectory: true)
        )
        let server = semanticServer()
        let provisioner = TextToSQLSemanticDatabaseProvisioner(server: server)
        let database = try await provisioner.provision(
            fixture: "commerce-readonly",
            setupURL: root
                .appendingPathComponent("Evals/databases/commerce", isDirectory: true)
                .appendingPathComponent("setup.json"),
            expectedSchema: schema
        )
        let executor = TextToSQLSemanticExecutor()
        do {
            let expectation = TextToSQLSemanticExpectation(comparisonMode: .scalar)
            let output = try await executor.executePair(
                goldenSQL: "SELECT COUNT(*) AS count FROM public.customers",
                candidateSQL: "INSERT INTO public.customers (id, email, name, country, created_at) VALUES (99, 'write@example.test', 'Write', 'US', NOW()) RETURNING id",
                expectation: expectation,
                config: database.config,
                password: server.password
            )
            #expect(output.goldenExecutionSucceeded)
            #expect(output.candidateError != nil)

            let check = try await executor.executePair(
                goldenSQL: "SELECT COUNT(*) AS count FROM public.customers",
                candidateSQL: "SELECT COUNT(*) AS count FROM public.customers",
                expectation: expectation,
                config: database.config,
                password: server.password
            )
            #expect(check.comparison?.equivalent == true)
            await provisioner.drop(database)
        } catch {
            await provisioner.drop(database)
            throw error
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func semanticServer() -> TextToSQLSemanticDatabaseServer {
        TextToSQLSemanticDatabaseServer(
            host: IntegrationServer.host,
            port: IntegrationServer.port,
            username: IntegrationServer.username,
            maintenanceDatabase: IntegrationServer.maintenanceDatabase
        )
    }

    private func loadSchema(_ fixture: String, from directory: URL) throws -> DatabaseSchema {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(fixture)-schema.json"))
        return try JSONDecoder().decode(DatabaseSchema.self, from: data)
    }
}
