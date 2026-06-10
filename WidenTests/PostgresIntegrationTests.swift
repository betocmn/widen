import Foundation
import Testing

@testable import WidenKit

/// Integration tests against a real local PostgreSQL server.
///
/// Skipped unless the `WIDEN_TEST_DB` environment variable names a database
/// (see `make test-db`, which expects the `widen_test` sample database from
/// `scripts/sample_db.sql`).
private let testDatabase = ProcessInfo.processInfo.environment["WIDEN_TEST_DB"]

@Suite("Postgres integration", .enabled(if: testDatabase != nil), .serialized)
struct PostgresIntegrationTests {
    private func makeConfig(
        database: String? = nil,
        username: String? = nil
    ) -> DatabaseConnectionConfig {
        DatabaseConnectionConfig(
            name: "Integration",
            host: "localhost",
            port: 5432,
            database: database ?? testDatabase ?? "widen_test",
            username: username ?? NSUserName(),
            defaultRowLimit: 100,
            statementTimeoutSeconds: 5
        )
    }

    @Test func testConnectionSucceeds() async throws {
        try await PostgresService.testConnection(config: makeConfig(), password: nil)
    }

    @Test func missingDatabaseProducesUsefulError() async {
        do {
            try await PostgresService.testConnection(
                config: makeConfig(database: "widen_definitely_missing_db"),
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
                config: makeConfig(username: "widen_invalid_user"),
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
        let service = PostgresService()
        try await service.connect(config: makeConfig(), password: nil)
        let connected = await service.isConnected
        #expect(connected)

        let values = try await service.query("SELECT 1 AS ok") { row in
            try row["ok"].decode(Int32.self)
        }
        #expect(values == [1])

        await service.disconnect()
        let stillConnected = await service.isConnected
        #expect(!stillConnected)
    }

    @Test func introspectsSampleSchema() async throws {
        let service = PostgresService()
        try await service.connect(config: makeConfig(), password: nil)
        defer { Task { await service.disconnect() } }

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
                $0.schema == "pg_catalog" || $0.schema == "information_schema"
            })
    }

    @Test func queryWithoutConnectionThrowsNotConnected() async {
        let service = PostgresService()
        await #expect(throws: AppError.notConnected) {
            _ = try await service.query("SELECT 1") { _ in 0 }
        }
    }
}

@Suite("Query execution integration", .enabled(if: testDatabase != nil), .serialized)
struct QueryExecutionIntegrationTests {
    private func makeConfig(
        rowLimit: Int = 100,
        timeoutSeconds: Int = 5
    ) -> DatabaseConnectionConfig {
        DatabaseConnectionConfig(
            name: "Integration",
            host: "localhost",
            port: 5432,
            database: testDatabase ?? "widen_test",
            username: NSUserName(),
            defaultRowLimit: rowLimit,
            statementTimeoutSeconds: timeoutSeconds
        )
    }

    private func withService<T>(
        config: DatabaseConnectionConfig,
        _ body: (PostgresService) async throws -> T
    ) async throws -> T {
        let service = PostgresService()
        try await service.connect(config: config, password: nil)
        do {
            let value = try await body(service)
            await service.disconnect()
            return value
        } catch {
            await service.disconnect()
            throw error
        }
    }

    @Test func runsSimpleSelect() async throws {
        let config = makeConfig()
        let result = try await withService(config: config) { service in
            try await QueryExecutionService().run(
                sql: "SELECT 1 AS test", config: config, postgres: service)
        }
        #expect(result.columns == ["test"])
        #expect(result.rows == [["1"]])
        #expect(result.rowCount == 1)
        #expect(!result.truncated)
    }

    @Test func runsTableSelectWithCommonTypes() async throws {
        let config = makeConfig()
        let result = try await withService(config: config) { service in
            try await QueryExecutionService().run(
                sql: "SELECT id, email, name, created_at FROM users ORDER BY id LIMIT 10",
                config: config,
                postgres: service
            )
        }
        #expect(result.columns == ["id", "email", "name", "created_at"])
        #expect(result.rowCount == 3)
        #expect(result.rows[0][1] == "alice@example.com")
        // timestamptz renders as an ISO-ish string
        #expect(result.rows[0][3]?.contains("T") == true)
    }

    @Test func stringifiesBoolNumericUUIDJsonAndNull() async throws {
        let config = makeConfig()
        let sql = """
            SELECT true AS flag,
                   3.14::numeric AS amount,
                   gen_random_uuid() AS uid,
                   '{"a": 1}'::jsonb AS payload,
                   NULL::text AS missing
            LIMIT 1
            """
        let result = try await withService(config: config) { service in
            try await QueryExecutionService().run(sql: sql, config: config, postgres: service)
        }
        let row = try #require(result.rows.first)
        #expect(row[0] == "true")
        #expect(row[1] == "3.14")
        #expect(row[2]?.count == 36)
        #expect(row[3]?.contains("\"a\"") == true)
        #expect(row[4] == nil)
    }

    @Test func appliesDefaultLimitAndReportsTruncation() async throws {
        let config = makeConfig(rowLimit: 2)
        let result = try await withService(config: config) { service in
            try await QueryExecutionService().run(
                sql: "SELECT id FROM orders ORDER BY id",
                config: config,
                postgres: service
            )
        }
        #expect(result.rowCount == 2)
        #expect(result.truncated)
    }

    @Test func userLimitRunsAsIs() async throws {
        let config = makeConfig(rowLimit: 100)
        let result = try await withService(config: config) { service in
            try await QueryExecutionService().run(
                sql: "SELECT id FROM orders ORDER BY id LIMIT 1",
                config: config,
                postgres: service
            )
        }
        #expect(result.rowCount == 1)
        #expect(!result.truncated)
    }

    @Test func mutatingSQLIsBlockedBeforeReachingTheServer() async throws {
        let config = makeConfig()
        try await withService(config: config) { service in
            do {
                _ = try await QueryExecutionService().run(
                    sql: "DELETE FROM users", config: config, postgres: service)
                Issue.record("Expected validation to fail")
            } catch let error as AppError {
                guard case .validationFailed = error else {
                    Issue.record("Expected validationFailed, got \(error)")
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

    @Test func statementTimeoutCancelsLongQueries() async throws {
        let config = makeConfig(timeoutSeconds: 1)
        try await withService(config: config) { service in
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
