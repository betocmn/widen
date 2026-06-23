import CryptoKit
import Foundation
import Logging
import PostgresNIO

public struct TextToSQLSemanticDatabaseServer: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var maintenanceDatabase: String
    public var sslMode: SSLMode

    public init(
        host: String = "localhost",
        port: Int = 5432,
        username: String = NSUserName(),
        password: String? = nil,
        maintenanceDatabase: String = "postgres",
        sslMode: SSLMode = .disable
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.maintenanceDatabase = maintenanceDatabase
        self.sslMode = sslMode
    }

    public static func fromEnvironment(_ environment: [String: String]) -> Self {
        let port = environment["WIDEN_EVAL_DB_PORT"].flatMap(Int.init) ?? 5432
        let sslMode = environment["WIDEN_EVAL_DB_SSLMODE"].flatMap(SSLMode.init(rawValue:)) ?? .disable
        let password = environment["WIDEN_EVAL_DB_PASSWORD"]?.nilIfBlank
        return TextToSQLSemanticDatabaseServer(
            host: environment["WIDEN_EVAL_DB_HOST"]?.nilIfBlank ?? "localhost",
            port: port,
            username: environment["WIDEN_EVAL_DB_USER"]?.nilIfBlank ?? NSUserName(),
            password: password,
            maintenanceDatabase: environment["WIDEN_EVAL_DB_MAINTENANCE_DB"]?.nilIfBlank ?? "postgres",
            sslMode: sslMode
        )
    }

    public func config(database: String) -> DatabaseConnectionConfig {
        DatabaseConnectionConfig(
            name: "Widen Eval \(database)",
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode,
            defaultRowLimit: 1_000,
            statementTimeoutSeconds: 5
        )
    }
}

public struct TextToSQLSemanticProvisionedDatabase: Equatable, Sendable {
    public var fixture: String
    public var databaseName: String
    public var config: DatabaseConnectionConfig

    public init(fixture: String, databaseName: String, config: DatabaseConnectionConfig) {
        self.fixture = fixture
        self.databaseName = databaseName
        self.config = config
    }
}

public enum TextToSQLSemanticDatabaseError: LocalizedError, Equatable, Sendable {
    case environmentUnavailable(String)
    case setupInvalid(String)
    case fixtureInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .environmentUnavailable(let message), .setupInvalid(let message),
            .fixtureInvalid(let message):
            message
        }
    }
}

public final class TextToSQLSemanticDatabaseProvisioner: Sendable {
    private let server: TextToSQLSemanticDatabaseServer
    private let logger: Logger

    public init(server: TextToSQLSemanticDatabaseServer) {
        self.server = server
        self.logger = PostgresService.makeLogger(label: "widen.eval.postgres")
    }

    public func provision(
        fixture: String,
        setupURL: URL,
        expectedSchema: DatabaseSchema
    ) async throws -> TextToSQLSemanticProvisionedDatabase {
        let databaseName = Self.databaseName(for: fixture)
        do {
            try await runStatements(
                ["CREATE DATABASE \(Self.quotedIdentifier(databaseName))"],
                database: server.maintenanceDatabase
            )
        } catch {
            throw TextToSQLSemanticDatabaseError.environmentUnavailable(
                "PostgreSQL semantic environment unavailable: \(error.localizedDescription)"
            )
        }

        let provisioned = TextToSQLSemanticProvisionedDatabase(
            fixture: fixture,
            databaseName: databaseName,
            config: server.config(database: databaseName)
        )
        do {
            let statements = try loadSetupStatements(setupURL)
            try await runStatements(statements, database: databaseName)
            try await validateSchema(expectedSchema, provisioned: provisioned)
            return provisioned
        } catch let error as TextToSQLSemanticDatabaseError {
            await drop(provisioned)
            throw error
        } catch {
            await drop(provisioned)
            throw TextToSQLSemanticDatabaseError.setupInvalid(
                "Fixture \(fixture) setup failed: \(error.localizedDescription)"
            )
        }
    }

    public func drop(_ provisioned: TextToSQLSemanticProvisionedDatabase) async {
        try? await runStatements(
            ["DROP DATABASE IF EXISTS \(Self.quotedIdentifier(provisioned.databaseName)) WITH (FORCE)"],
            database: server.maintenanceDatabase
        )
    }

    private func loadSetupStatements(_ setupURL: URL) throws -> [String] {
        let data = try Data(contentsOf: setupURL)
        let statements = try JSONDecoder().decode([String].self, from: data)
        let cleaned = statements.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw TextToSQLSemanticDatabaseError.setupInvalid(
                "Setup fixture \(setupURL.path) has no statements."
            )
        }
        return cleaned
    }

    private func validateSchema(
        _ expectedSchema: DatabaseSchema,
        provisioned: TextToSQLSemanticProvisionedDatabase
    ) async throws {
        let service = PostgresService()
        try await service.connect(config: provisioned.config, password: server.password)
        do {
            let actual = try await SchemaIntrospectionService().loadSchema(using: service)
            await service.disconnect()

            let expectedFingerprint = TextToSQLSemanticSchemaFingerprint.make(expectedSchema)
            let actualFingerprint = TextToSQLSemanticSchemaFingerprint.make(actual)
            guard expectedFingerprint == actualFingerprint else {
                throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                    "Fixture \(provisioned.fixture) schema drift: expected \(expectedFingerprint.sha256), actual \(actualFingerprint.sha256)."
                )
            }
        } catch {
            await service.disconnect()
            throw error
        }
    }

    private func runStatements(_ statements: [String], database: String) async throws {
        let configuration = try PostgresService.makeConnectionConfiguration(
            server.config(database: database),
            password: server.password
        )
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

    private static func databaseName(for fixture: String) -> String {
        let safeFixture = fixture
            .lowercased()
            .map { char -> Character in
                (char.isLetter || char.isNumber) ? char : "_"
            }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(12)
            .lowercased()
        return "widen_eval_\(String(safeFixture))_\(suffix)"
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public struct TextToSQLSemanticExecutionOutput: Equatable, Sendable {
    public var goldenResult: TextToSQLSemanticQueryResult?
    public var candidateResult: TextToSQLSemanticQueryResult?
    public var comparison: TextToSQLSemanticComparisonResult?
    public var goldenError: String?
    public var candidateError: String?
    public var latencyMs: Int

    public var goldenExecutionSucceeded: Bool { goldenResult != nil && goldenError == nil }
    public var candidateExecutionSucceeded: Bool { candidateResult != nil && candidateError == nil }

    public init(
        goldenResult: TextToSQLSemanticQueryResult? = nil,
        candidateResult: TextToSQLSemanticQueryResult? = nil,
        comparison: TextToSQLSemanticComparisonResult? = nil,
        goldenError: String? = nil,
        candidateError: String? = nil,
        latencyMs: Int
    ) {
        self.goldenResult = goldenResult
        self.candidateResult = candidateResult
        self.comparison = comparison
        self.goldenError = goldenError
        self.candidateError = candidateError
        self.latencyMs = latencyMs
    }
}

public struct TextToSQLSemanticExecutor: Sendable {
    public var rowLimit: Int
    public var cellLimit: Int
    public var maxCellBytes: Int
    public var statementTimeoutMs: Int
    public var lockTimeoutMs: Int

    public init(
        rowLimit: Int = 1_000,
        cellLimit: Int = 50_000,
        maxCellBytes: Int = 64 * 1_024,
        statementTimeoutMs: Int = 5_000,
        lockTimeoutMs: Int = 2_000
    ) {
        self.rowLimit = rowLimit
        self.cellLimit = cellLimit
        self.maxCellBytes = maxCellBytes
        self.statementTimeoutMs = statementTimeoutMs
        self.lockTimeoutMs = lockTimeoutMs
    }

    public func executePair(
        goldenSQL: String,
        candidateSQL: String,
        expectation: TextToSQLSemanticExpectation,
        config: DatabaseConnectionConfig,
        password: String?
    ) async throws -> TextToSQLSemanticExecutionOutput {
        let logger = PostgresService.makeLogger(label: "widen.eval.executor")
        let started = ContinuousClock.now
        let configuration = try PostgresService.makeConnectionConfiguration(config, password: password)
        let connection = try await PostgresConnection.connect(
            on: PostgresConnection.defaultEventLoopGroup.any(),
            configuration: configuration,
            id: 1,
            logger: logger
        )
        do {
            try await connection.query("BEGIN READ ONLY", logger: logger)
            try await connection.query("SET LOCAL TIME ZONE 'UTC'", logger: logger)
            try await connection.query(
                PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = \(statementTimeoutMs)"),
                logger: logger
            )
            try await connection.query(
                PostgresQuery(unsafeSQL: "SET LOCAL lock_timeout = \(lockTimeoutMs)"),
                logger: logger
            )

            let golden: TextToSQLSemanticQueryResult
            do {
                golden = try await execute(goldenSQL, connection: connection, logger: logger)
            } catch {
                try? await connection.query("ROLLBACK", logger: logger)
                try? await connection.close()
                return TextToSQLSemanticExecutionOutput(
                    goldenError: error.localizedDescription,
                    latencyMs: elapsedMilliseconds(since: started)
                )
            }

            let candidate: TextToSQLSemanticQueryResult
            do {
                candidate = try await execute(candidateSQL, connection: connection, logger: logger)
            } catch {
                try? await connection.query("ROLLBACK", logger: logger)
                try? await connection.close()
                return TextToSQLSemanticExecutionOutput(
                    goldenResult: golden,
                    candidateError: error.localizedDescription,
                    latencyMs: elapsedMilliseconds(since: started)
                )
            }

            try await connection.query("ROLLBACK", logger: logger)
            try await connection.close()
            let comparison = TextToSQLSemanticComparator.compare(
                golden: golden,
                candidate: candidate,
                expectation: expectation
            )
            return TextToSQLSemanticExecutionOutput(
                goldenResult: golden,
                candidateResult: candidate,
                comparison: comparison,
                latencyMs: elapsedMilliseconds(since: started)
            )
        } catch {
            try? await connection.query("ROLLBACK", logger: logger)
            try? await connection.close()
            throw error
        }
    }

    private func execute(
        _ sql: String,
        connection: PostgresConnection,
        logger: Logger
    ) async throws -> TextToSQLSemanticQueryResult {
        let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        let columns = stream.columns.map(\.name)
        var rows: [[TextToSQLSemanticValue]] = []
        var cellCount = 0

        for try await row in stream {
            guard rows.count < rowLimit else {
                throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                    "Semantic result exceeded strict row cap of \(rowLimit)."
                )
            }
            var values: [TextToSQLSemanticValue] = []
            for cell in row {
                cellCount += 1
                guard cellCount <= cellLimit else {
                    throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                        "Semantic result exceeded strict cell cap of \(cellLimit)."
                    )
                }
                if let bytes = cell.bytes, bytes.readableBytes > maxCellBytes {
                    throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                        "Semantic result cell exceeded strict byte cap of \(maxCellBytes)."
                    )
                }
                values.append(Self.value(for: cell))
            }
            rows.append(values)
        }

        return TextToSQLSemanticQueryResult(columns: columns, rows: rows)
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }

    private static func value(for cell: PostgresCell) -> TextToSQLSemanticValue {
        guard cell.bytes != nil else { return .null }
        do {
            switch cell.dataType {
            case .bool:
                return .bool(try cell.decode(Bool.self))
            case .int2:
                return .number(Decimal(try cell.decode(Int16.self)))
            case .int4:
                return .number(Decimal(try cell.decode(Int32.self)))
            case .int8:
                return .number(Decimal(try cell.decode(Int64.self)))
            case .numeric:
                return .number(try cell.decode(Decimal.self))
            case .float4:
                return .float(Double(try cell.decode(Float.self)))
            case .float8:
                return .float(try cell.decode(Double.self))
            case .uuid:
                return .uuid(try cell.decode(UUID.self).uuidString.lowercased())
            case .date:
                return .date(dateOnlyFormatter.string(from: try cell.decode(Date.self)))
            case .timestamp, .timestamptz:
                return .timestamp(timestampFormatter.string(from: try cell.decode(Date.self)))
            case .json, .jsonb:
                let raw = try cell.decode(String.self)
                return .json(TextToSQLSemanticValue.canonicalJSON(raw) ?? raw)
            case .interval:
                return .interval(TextToSQLSemanticValue.normalizedInterval(try cell.decode(String.self)))
            case .bytea:
                return .bytes(PostgresCellFormatter.string(for: cell) ?? "")
            default:
                return TextToSQLSemanticValue.canonicalJSONOrString(try cell.decode(String.self))
            }
        } catch {
            return .string(PostgresCellFormatter.string(for: cell) ?? "")
        }
    }

    nonisolated(unsafe) private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

public struct TextToSQLSemanticSchemaFingerprint: Equatable, Sendable {
    public var lines: [String]
    public var sha256: String

    public static func make(_ schema: DatabaseSchema) -> Self {
        var lines: [String] = []
        for schema in schema.schemas.map(\.name).sorted() {
            lines.append("schema|\(schema)")
        }
        for table in schema.tables.sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
            lines.append("table|\(table.schema)|\(table.name)|\(table.type.rawValue.lowercased())")
            for column in table.columns.sorted(by: { $0.ordinalPosition < $1.ordinalPosition }) {
                let constraints = (column.valueConstraints ?? [])
                    .map { constraint in
                        "\(constraint.kind.rawValue):\(constraint.values.sorted().joined(separator: ","))"
                    }
                    .sorted()
                    .joined(separator: ";")
                lines.append(
                    [
                        "column",
                        column.tableSchema,
                        column.tableName,
                        column.name,
                        column.dataType.lowercased(),
                        column.isNullable ? "nullable" : "not-null",
                        String(column.ordinalPosition),
                        constraints,
                    ].joined(separator: "|")
                )
            }
        }
        for fk in schema.foreignKeys.sorted(by: { $0.id < $1.id }) {
            lines.append(
                [
                    "fk",
                    fk.constraintName,
                    fk.sourceSchema,
                    fk.sourceTable,
                    fk.sourceColumn,
                    fk.targetSchema,
                    fk.targetTable,
                    fk.targetColumn,
                ].joined(separator: "|")
            )
        }
        let text = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return TextToSQLSemanticSchemaFingerprint(lines: lines, sha256: digest)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
