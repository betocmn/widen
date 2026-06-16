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
private let integrationEnabled = ProcessInfo.processInfo.environment["WIDEN_TEST_DB"] != nil

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
                #expect(error == .queryTimeout)
            }
            // The connection is healthy again after ROLLBACK.
            let values = try await service.query("SELECT 1 AS ok") { row in
                try row["ok"].decode(Int32.self)
            }
            #expect(values == [1])
        }
    }
}
