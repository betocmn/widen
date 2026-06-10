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
