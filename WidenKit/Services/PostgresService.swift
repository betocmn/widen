import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

/// Owns the PostgreSQL client lifecycle and runs queries.
///
/// Lifecycle: `connect` creates a pooled `PostgresClient` and starts its
/// `run()` loop in a long-lived task; `disconnect` cancels that task, which
/// closes the client. A client is never reused after its run task is
/// cancelled — reconnecting always builds a fresh client.
public actor PostgresService: DatabaseInspectionQuerying {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    let logger: Logger

    public init() {
        self.logger = Self.makeLogger(label: "widen.postgres")
    }

    public var isConnected: Bool { client != nil }

    /// Establishes a new client and verifies connectivity, so authentication
    /// and missing-database errors surface immediately.
    public func connect(config: DatabaseConnectionConfig, password: String?) async throws {
        disconnect()
        // Probe with a single throwaway connection first: the pooled client
        // retries failed connections in the background, so server FATALs
        // (bad credentials, missing database) would otherwise only surface as
        // a generic timeout.
        try await Self.probe(config: config, password: password)

        let client = PostgresClient(
            configuration: Self.makeConfiguration(config, password: password),
            backgroundLogger: logger
        )
        self.client = client
        // `run()` must be called exactly once per client; cancelling the task
        // closes the client and its connections.
        self.runTask = Task { await client.run() }
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        client = nil
    }

    /// Runs a read query and decodes every row inside the actor, so only
    /// `Sendable` values cross the actor boundary.
    public func query<T: Sendable>(
        _ sql: String,
        decode: @escaping @Sendable (PostgresRandomAccessRow) throws -> T
    ) async throws -> [T] {
        guard let client else { throw AppError.notConnected }
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var results: [T] = []
            for try await row in rows {
                results.append(try decode(row.makeRandomAccess()))
            }
            return results
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    /// Executes a validated query inside a read-only transaction with a
    /// statement timeout, pinned to a single pooled connection.
    ///
    /// When `hasLimit` is false the query is wrapped in a
    /// `LIMIT rowLimit + 1` subquery: the extra row only signals truncation
    /// and is dropped from the returned result.
    public func executeReadOnly(
        sql: String,
        hasLimit: Bool,
        rowLimit: Int,
        timeoutSeconds: Int
    ) async throws -> QueryResult {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let start = ContinuousClock.now
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN READ ONLY", logger: logger)
                do {
                    // SET cannot take bind parameters; timeoutSeconds is
                    // app-validated (1…120).
                    try await connection.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = \(timeoutSeconds * 1000)"),
                        logger: logger
                    )

                    let finalSQL =
                        hasLimit
                        ? sql
                        : "SELECT * FROM (\n\(sql)\n) AS widen_subquery LIMIT \(rowLimit + 1)"
                    let stream = try await connection.query(
                        PostgresQuery(unsafeSQL: finalSQL),
                        logger: logger
                    )

                    let columns = stream.columns.map(\.name)
                    var rows: [[String?]] = []
                    for try await row in stream {
                        let randomAccess = row.makeRandomAccess()
                        rows.append(
                            (0..<randomAccess.count).map {
                                PostgresCellFormatter.string(for: randomAccess[$0])
                            }
                        )
                    }
                    try await connection.query("COMMIT", logger: logger)

                    var truncated = false
                    if !hasLimit, rows.count > rowLimit {
                        truncated = true
                        rows.removeLast()
                    }
                    let elapsed = start.duration(to: .now)
                    return QueryResult(
                        columns: columns,
                        rows: rows,
                        rowCount: rows.count,
                        truncated: truncated,
                        executionTimeMs: Int(elapsed / .milliseconds(1))
                    )
                } catch {
                    // Leave the pooled connection in a clean state.
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    /// Verifies generated read SQL using PostgreSQL parse/analyze/bind/type
    /// checks without executing the user query or fetching rows.
    public func verifyGeneratedReadOnlySQL(_ sql: String) async throws -> SQLVerificationResult {
        guard let client else {
            return .skipped(
                .skippedNoConnection,
                message: AppError.notConnected.localizedDescription
            )
        }
        let logger = logger
        let start = ContinuousClock.now
        let statementName = Self.verificationPreparedStatementName()
        let generatedSQL = Self.sqlWithoutTrailingTerminator(sql)
        var stage: SQLVerificationStage = .transaction
        var prepared = false

        return try await client.withConnection { connection in
            do {
                try await connection.query(
                    "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
                    logger: logger
                )
                try await connection.query(
                    "SET LOCAL statement_timeout = '2s'",
                    logger: logger
                )
                try await connection.query(
                    "SET LOCAL lock_timeout = '500ms'",
                    logger: logger
                )
                try await connection.query(
                    "SET LOCAL idle_in_transaction_session_timeout = '5s'",
                    logger: logger
                )
                try await connection.query("SET LOCAL timezone = 'UTC'", logger: logger)
                try await connection.query("SET LOCAL DateStyle = 'ISO, YMD'", logger: logger)
                try await connection.query("SET LOCAL IntervalStyle = 'iso_8601'", logger: logger)

                stage = .prepare
                try await connection.query(
                    PostgresQuery(
                        unsafeSQL: "PREPARE \(statementName) AS \(generatedSQL)"
                    ),
                    logger: logger
                )
                prepared = true

                stage = .deallocate
                try await connection.query(
                    PostgresQuery(unsafeSQL: "DEALLOCATE \(statementName)"),
                    logger: logger
                )

                stage = .rollback
                try await connection.query("ROLLBACK", logger: logger)
                return .passed(elapsedMs: Int(start.duration(to: .now) / .milliseconds(1)))
            } catch is CancellationError {
                if prepared {
                    try? await connection.query(
                        PostgresQuery(unsafeSQL: "DEALLOCATE \(statementName)"),
                        logger: logger
                    )
                }
                try? await connection.query("ROLLBACK", logger: logger)
                throw CancellationError()
            } catch {
                if prepared, stage != .deallocate {
                    try? await connection.query(
                        PostgresQuery(unsafeSQL: "DEALLOCATE \(statementName)"),
                        logger: logger
                    )
                }
                try? await connection.query("ROLLBACK", logger: logger)
                let mapped = Self.verificationFailure(from: error)
                return .failed(
                    diagnostic: mapped.diagnostic,
                    elapsedMs: Int(start.duration(to: .now) / .milliseconds(1)),
                    stage: stage,
                    message: mapped.message
                )
            }
        }
    }

    public func inspectRelationSize(
        schema: String,
        table: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseRelationSizeSnapshot {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let sql = Self.relationSizeInspectionSQL(schema: schema, table: table)
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: logger)
                do {
                    try await Self.applyInspectionSettings(on: connection, logger: logger, policy: policy)
                    let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    var estimate: Int64?
                    for try await row in stream {
                        estimate = try? row.makeRandomAccess()["row_estimate"].decode(Int64.self)
                    }
                    try await connection.query("ROLLBACK", logger: logger)
                    return DatabaseRelationSizeSnapshot(
                        approximateRowCount: estimate,
                        source: "pg_class.reltuples"
                    )
                } catch {
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    static func relationSizeInspectionSQL(schema: String, table: String) -> String {
        """
        SELECT
          CASE
            WHEN c.reltuples < 0 THEN NULL::bigint
            ELSE round(c.reltuples)::bigint
          END AS row_estimate
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n
          ON n.oid = c.relnamespace
        WHERE n.nspname = \(Self.sqlLiteral(schema))
          AND c.relname = \(Self.sqlLiteral(table))
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
        LIMIT 1
        """
    }

    public func inspectColumnStatistics(
        schema: String,
        table: String,
        column: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnStatisticsSnapshot {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let sql = """
            SELECT
              s.null_frac::double precision AS null_frac,
              CASE
                WHEN s.n_distinct < 0 AND c.reltuples >= 0
                  THEN abs(s.n_distinct::double precision) * c.reltuples::double precision
                WHEN s.n_distinct >= 0
                  THEN s.n_distinct::double precision
                ELSE NULL
              END AS distinct_estimate
            FROM pg_catalog.pg_stats AS s
            LEFT JOIN pg_catalog.pg_namespace AS n
              ON n.nspname = s.schemaname
            LEFT JOIN pg_catalog.pg_class AS c
              ON c.relname = s.tablename
             AND c.relnamespace = n.oid
            WHERE s.schemaname = \(Self.sqlLiteral(schema))
              AND s.tablename = \(Self.sqlLiteral(table))
              AND s.attname = \(Self.sqlLiteral(column))
            LIMIT 1
            """
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: logger)
                do {
                    try await Self.applyInspectionSettings(on: connection, logger: logger, policy: policy)
                    let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    var snapshot = DatabaseColumnStatisticsSnapshot()
                    for try await row in stream {
                        let random = row.makeRandomAccess()
                        snapshot = DatabaseColumnStatisticsSnapshot(
                            approximateNullFraction: try? random["null_frac"].decode(Double.self),
                            approximateDistinctCount: try? random["distinct_estimate"].decode(Double.self)
                        )
                    }
                    try await connection.query("ROLLBACK", logger: logger)
                    return snapshot
                } catch {
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    public func inspectColumnAggregate(
        table: TableInfo,
        column: ColumnInfo,
        includeDistinct: Bool,
        includeMinMax: Bool,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnAggregateSnapshot {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let qualifiedTable = Self.qualifiedIdentifier(schema: table.schema, table: table.name)
        let columnSQL = Self.quotedIdentifier(column.name)
        let distinctColumnSQL = Self.inspectionColumnExpression(for: column)
        let distinctSQL = includeDistinct
            ? "count(DISTINCT \(distinctColumnSQL))::bigint AS distinct_count"
            : "NULL::bigint AS distinct_count"
        let minSQL = includeMinMax ? "min(\(columnSQL)) AS min_value" : "NULL::text AS min_value"
        let maxSQL = includeMinMax ? "max(\(columnSQL)) AS max_value" : "NULL::text AS max_value"
        let sql = """
            SELECT
              count(*)::bigint AS row_count,
              (count(*) - count(\(columnSQL)))::bigint AS null_count,
              \(distinctSQL),
              \(minSQL),
              \(maxSQL)
            FROM \(qualifiedTable)
            """
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: logger)
                do {
                    try await Self.applyInspectionSettings(on: connection, logger: logger, policy: policy)
                    let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    var snapshot: DatabaseColumnAggregateSnapshot?
                    for try await row in stream {
                        let random = row.makeRandomAccess()
                        snapshot = DatabaseColumnAggregateSnapshot(
                            rowCount: try random["row_count"].decode(Int64.self),
                            nullCount: try random["null_count"].decode(Int64.self),
                            distinctCount: try? random["distinct_count"].decode(Int64.self),
                            minValue: Self.inspectionValue(
                                for: random["min_value"],
                                policy: policy,
                                preferredKind: includeMinMax ? nil : .unsupportedType
                            ),
                            maxValue: Self.inspectionValue(
                                for: random["max_value"],
                                policy: policy,
                                preferredKind: includeMinMax ? nil : .unsupportedType
                            )
                        )
                    }
                    try await connection.query("ROLLBACK", logger: logger)
                    return snapshot ?? DatabaseColumnAggregateSnapshot(rowCount: 0, nullCount: 0)
                } catch {
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    public func inspectDistinctValues(
        table: TableInfo,
        column: ColumnInfo,
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseDistinctValueRow] {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let boundedLimit = min(max(limit, 0), policy.effectiveMaximumDistinctValues) + 1
        let qualifiedTable = Self.qualifiedIdentifier(schema: table.schema, table: table.name)
        let columnSQL = Self.inspectionColumnExpression(for: column)
        let preferredKind = Self.inspectionValueKind(for: column)
        let sql = """
            SELECT \(columnSQL) AS value, count(*)::bigint AS value_count
            FROM \(qualifiedTable)
            GROUP BY \(columnSQL)
            ORDER BY value_count DESC, value ASC NULLS LAST
            LIMIT \(boundedLimit)
            """
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: logger)
                do {
                    try await Self.applyInspectionSettings(on: connection, logger: logger, policy: policy)
                    let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    var rows: [DatabaseDistinctValueRow] = []
                    for try await row in stream {
                        let random = row.makeRandomAccess()
                        rows.append(
                            DatabaseDistinctValueRow(
                                value: Self.inspectionValue(
                                    for: random["value"],
                                    policy: policy,
                                    preferredKind: preferredKind
                                ),
                                count: try? random["value_count"].decode(Int64.self)
                            )
                        )
                    }
                    try await connection.query("ROLLBACK", logger: logger)
                    return rows
                } catch {
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    public func inspectSampleRows(
        table: TableInfo,
        columns: [ColumnInfo],
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseSampleRow] {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let boundedLimit = min(max(limit, 0), policy.effectiveMaximumReturnedRows) + 1
        let qualifiedTable = Self.qualifiedIdentifier(schema: table.schema, table: table.name)
        let selectedColumns = Array(columns.prefix(policy.effectiveMaximumSampleColumns))
        let selectedColumnReferences = selectedColumns.enumerated().map { offset, column in
            let stableID = SchemaObjectID.column(
                schema: column.tableSchema,
                table: column.tableName,
                name: column.name
            ).stableString
            return SampleColumnReference(
                stableID: stableID,
                alias: "__widen_sample_\(offset)",
                preferredKind: Self.inspectionValueKind(for: column)
            )
        }
        let sampleColumnByAlias = Dictionary(
            uniqueKeysWithValues: selectedColumnReferences.map { ($0.alias, $0) }
        )
        let selections: [String]
        if selectedColumnReferences.isEmpty {
            selections = ["1 AS \(Self.quotedIdentifier("__widen_sample_marker"))"]
        } else {
            selections = zip(selectedColumns, selectedColumnReferences).map { column, reference in
                "\(Self.inspectionColumnExpression(for: column)) AS \(Self.quotedIdentifier(reference.alias))"
            }
        }
        let sql = """
            SELECT \(selections.joined(separator: ", "))
            FROM \(qualifiedTable)
            LIMIT \(boundedLimit)
            """
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", logger: logger)
                do {
                    try await Self.applyInspectionSettings(on: connection, logger: logger, policy: policy)
                    let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    var sampleRows: [DatabaseSampleRow] = []
                    for try await row in stream {
                        var values: [String: DatabaseInspectionValue] = [:]
                        for cell in row {
                            guard let reference = sampleColumnByAlias[cell.columnName] else { continue }
                            values[reference.stableID] = Self.inspectionValue(
                                for: cell,
                                policy: policy,
                                preferredKind: reference.preferredKind
                            )
                        }
                        sampleRows.append(DatabaseSampleRow(valuesByColumnStableID: values))
                    }
                    try await connection.query("ROLLBACK", logger: logger)
                    return sampleRows
                } catch {
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    /// Executes a validated write (INSERT/UPDATE/DELETE) inside a read-write
    /// transaction with a statement timeout, pinned to a single pooled
    /// connection. Captures the affected-row count from the command tag and any
    /// RETURNING rows. Rolls back on error so the pooled connection stays clean.
    ///
    /// `rowCount` is the affected-row count. RETURNING rows are materialized for
    /// display only up to `rowLimit` (with `truncated` set when more were
    /// returned), so a `… RETURNING *` over a large table cannot flood the
    /// transcript and UI — mirroring the read path's row cap.
    public func executeWrite(
        sql: String,
        rowLimit: Int,
        timeoutSeconds: Int,
        kind: SQLStatementKind
    ) async throws -> QueryResult {
        guard let client else { throw AppError.notConnected }
        let logger = logger
        let start = ContinuousClock.now
        do {
            return try await client.withConnection { connection in
                try await connection.query("BEGIN", logger: logger)
                do {
                    // SET cannot take bind parameters; timeoutSeconds is
                    // app-validated (1…120).
                    try await connection.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = \(timeoutSeconds * 1000)"),
                        logger: logger
                    )

                    let limitsReturningRows = Self.hasTopLevelReturning(sql)
                    let executionSQL =
                        limitsReturningRows
                        ? Self.limitedReturningWriteSQL(sql: sql, rowLimit: rowLimit)
                        : sql
                    let accumulator = WriteResultAccumulator(
                        rowLimit: rowLimit,
                        capturesLimitedReturning: limitsReturningRows
                    )
                    let metadata = try await connection.query(
                        PostgresQuery(unsafeSQL: executionSQL),
                        logger: logger
                    ) { row in
                        accumulator.record(row)
                    }.get()
                    try await connection.query("COMMIT", logger: logger)

                    let snapshot = accumulator.snapshot(
                        commandRows: limitsReturningRows ? nil : metadata.rows)
                    let elapsed = start.duration(to: .now)
                    return QueryResult(
                        columns: snapshot.columns,
                        rows: snapshot.rows,
                        rowCount: snapshot.rowCount,
                        truncated: snapshot.truncated,
                        executionTimeMs: Int(elapsed / .milliseconds(1)),
                        kind: kind
                    )
                } catch {
                    // Leave the pooled connection in a clean state.
                    try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    // MARK: - Configuration

    private struct SampleColumnReference: Sendable {
        var stableID: String
        var alias: String
        var preferredKind: DatabaseInspectionValueKind?
    }

    private static let returningRowNumberColumn = "__widen_returning_row_number"
    private static let returningAffectedRowsColumn = "__widen_affected_rows"

    private static func verificationPreparedStatementName() -> String {
        "widen_generated_check_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased()
    }

    private static func verificationFailure(
        from error: any Error
    ) -> (diagnostic: DatabaseDiagnostic?, message: String) {
        if let psql = error as? PSQLError, let server = psql.serverInfo {
            let diagnostic = PostgresErrorMapper.diagnostic(from: server)
            return (diagnostic, diagnostic.displayMessage)
        }
        if let appError = error as? AppError {
            switch appError {
            case .databaseFailed(let diagnostic):
                return (diagnostic, diagnostic.displayMessage)
            default:
                return (nil, appError.localizedDescription)
            }
        }
        let mapped = PostgresErrorMapper.map(error)
        switch mapped {
        case .databaseFailed(let diagnostic):
            return (diagnostic, diagnostic.displayMessage)
        default:
            return (nil, mapped.localizedDescription)
        }
    }

    private static func applyInspectionSettings(
        on connection: PostgresConnection,
        logger: Logger,
        policy: DatabaseInspectionPolicy
    ) async throws {
        try await connection.query(
            PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = '\(policy.effectiveStatementTimeoutMilliseconds)ms'"),
            logger: logger
        )
        try await connection.query(
            PostgresQuery(unsafeSQL: "SET LOCAL lock_timeout = '\(policy.effectiveLockTimeoutMilliseconds)ms'"),
            logger: logger
        )
        try await connection.query(
            PostgresQuery(
                unsafeSQL: "SET LOCAL idle_in_transaction_session_timeout = '\(policy.effectiveIdleTransactionTimeoutMilliseconds)ms'"
            ),
            logger: logger
        )
        try await connection.query("SET LOCAL timezone = 'UTC'", logger: logger)
        try await connection.query("SET LOCAL DateStyle = 'ISO, YMD'", logger: logger)
        try await connection.query("SET LOCAL IntervalStyle = 'iso_8601'", logger: logger)
    }

    static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func qualifiedIdentifier(schema: String, table: String) -> String {
        "\(quotedIdentifier(schema)).\(quotedIdentifier(table))"
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func inspectionColumnExpression(for column: ColumnInfo) -> String {
        let columnSQL = quotedIdentifier(column.name)
        return castsColumnToTextForInspection(column) ? "(\(columnSQL))::text" : columnSQL
    }

    private static func castsColumnToTextForInspection(_ column: ColumnInfo) -> Bool {
        column.valueConstraints?.contains { $0.kind == .enumValues } == true
            || inspectionValueKind(for: column) != nil
    }

    private static func inspectionValueKind(for column: ColumnInfo) -> DatabaseInspectionValueKind? {
        switch column.dataType.lowercased() {
        case "time", "time without time zone":
            .time
        case "time with time zone", "timetz":
            .timeWithTimeZone
        default:
            nil
        }
    }

    private static func inspectionValue(
        for cell: PostgresCell,
        policy: DatabaseInspectionPolicy,
        preferredKind: DatabaseInspectionValueKind? = nil
    ) -> DatabaseInspectionValue {
        guard cell.bytes != nil else { return .null }
        if preferredKind == .unsupportedType {
            return .unsupported(cell.dataType.description)
        }
        do {
            if let preferredKind {
                switch preferredKind {
                case .time:
                    return .time(try stringOrTimeString(for: cell))
                case .timeWithTimeZone:
                    return .timeWithTimeZone(try stringOrTimeWithTimeZoneString(for: cell))
                default:
                    break
                }
            }
            switch cell.dataType {
            case .bool:
                return .boolean(try cell.decode(Bool.self))
            case .int2:
                return .integer(Int64(try cell.decode(Int16.self)))
            case .int4:
                return .integer(Int64(try cell.decode(Int32.self)))
            case .int8:
                return .integer(try cell.decode(Int64.self))
            case .numeric:
                return .decimal(String(describing: try cell.decode(Decimal.self)))
            case .float4:
                return .float(Double(try cell.decode(Float.self)))
            case .float8:
                return .float(try cell.decode(Double.self))
            case .uuid:
                return .uuid(try cell.decode(UUID.self).uuidString.lowercased())
            case .date:
                return .date(dateOnlyFormatter.string(from: try cell.decode(Date.self)))
            case .time:
                return .time(try timeString(for: cell))
            case .timetz:
                return .timeWithTimeZone(try timeWithTimeZoneString(for: cell))
            case .timestamp:
                return .timestamp(try localTimestampString(for: cell))
            case .timestamptz:
                return .timestampWithTimeZone(try timestampWithTimeZoneString(for: cell))
            case .json, .jsonb:
                return .json(try cell.decode(String.self), cap: policy.effectiveMaximumJSONCharacters)
            case .text, .varchar, .bpchar, .name, .char, .unknown:
                return .text(try cell.decode(String.self), cap: policy.effectiveMaximumTextCharacters)
            case .bytea:
                return .unsupported("bytea")
            default:
                if let value = try? cell.decode(String.self), isSafeDecodedTextType(cell.dataType.description) {
                    return .text(value, cap: policy.effectiveMaximumTextCharacters)
                }
                return .unsupported(cell.dataType.description)
            }
        } catch {
            return .unsupported("\(cell.dataType.description):decodeFailure")
        }
    }

    private static func isSafeDecodedTextType(_ typeName: String) -> Bool {
        let lowered = typeName.lowercased()
        return lowered.contains("enum") || lowered.contains("text") || lowered.contains("varchar")
    }

    private static func stringOrTimeString(for cell: PostgresCell) throws -> String {
        if let value = try decodedTextString(for: cell) {
            return value
        }
        return try timeString(for: cell)
    }

    private static func stringOrTimeWithTimeZoneString(for cell: PostgresCell) throws -> String {
        if let value = try decodedTextString(for: cell) {
            return value
        }
        return try timeWithTimeZoneString(for: cell)
    }

    private static func decodedTextString(for cell: PostgresCell) throws -> String? {
        switch cell.dataType {
        case .text, .varchar, .bpchar, .name, .char, .unknown:
            return try cell.decode(String.self)
        default:
            return nil
        }
    }

    private static func timeString(for cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes, let microseconds = bytes.readInteger(as: Int64.self) else {
            return "invalid"
        }
        return timeString(postgresMicroseconds: microseconds)
    }

    private static func timeWithTimeZoneString(for cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes,
            let microseconds = bytes.readInteger(as: Int64.self),
            let timeZoneSecondsWest = bytes.readInteger(as: Int32.self)
        else {
            return "invalid"
        }
        return "\(timeString(postgresMicroseconds: microseconds))\(timeZoneOffsetString(secondsEast: -Int(timeZoneSecondsWest)))"
    }

    private static func timeString(postgresMicroseconds: Int64) -> String {
        let microsecondsPerHour: Int64 = 3_600_000_000
        let microsecondsPerMinute: Int64 = 60_000_000
        let microsecondsPerSecond: Int64 = 1_000_000
        let hours = postgresMicroseconds / microsecondsPerHour
        let afterHours = postgresMicroseconds - hours * microsecondsPerHour
        let minutes = afterHours / microsecondsPerMinute
        let afterMinutes = afterHours - minutes * microsecondsPerMinute
        let seconds = afterMinutes / microsecondsPerSecond
        let micros = afterMinutes - seconds * microsecondsPerSecond
        return String(format: "%02d:%02d:%02d.%06d", Int(hours), Int(minutes), Int(seconds), Int(micros))
    }

    private static func timeZoneOffsetString(secondsEast: Int) -> String {
        let sign = secondsEast >= 0 ? "+" : "-"
        let absolute = abs(secondsEast)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private static func localTimestampString(for cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes, let microseconds = bytes.readInteger(as: Int64.self) else {
            return "invalid"
        }
        return timestampString(postgresMicroseconds: microseconds, includeTimeZone: false)
    }

    private static func timestampWithTimeZoneString(for cell: PostgresCell) throws -> String {
        guard var bytes = cell.bytes, let microseconds = bytes.readInteger(as: Int64.self) else {
            return "invalid"
        }
        return timestampString(postgresMicroseconds: microseconds, includeTimeZone: true)
    }

    private static func timestampString(
        postgresMicroseconds: Int64,
        includeTimeZone: Bool
    ) -> String {
        let seconds = floorDividing(postgresMicroseconds, by: 1_000_000)
        let micros = postgresMicroseconds - seconds * 1_000_000
        let date = Date(
            timeInterval: Double(seconds),
            since: Date(timeIntervalSince1970: 946_684_800)
        )
        let base = includeTimeZone
            ? timestampWithTimeZoneFormatter.string(from: date)
            : localTimestampFormatter.string(from: date)
        let suffix = String(format: ".%06d", Int(micros))
        return includeTimeZone ? "\(base)\(suffix)Z" : "\(base)\(suffix)"
    }

    private static func floorDividing(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    nonisolated(unsafe) private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    nonisolated(unsafe) private static let localTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    nonisolated(unsafe) private static let timestampWithTimeZoneFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func limitedReturningWriteSQL(sql: String, rowLimit: Int) -> String {
        let writeSQL = sqlWithoutTrailingTerminator(sql)
        let streamLimit = max(rowLimit, 0) + 1
        return """
            WITH "__widen_write" AS (
            \(writeSQL)
            ),
            "__widen_count" AS (
              SELECT count(*)::bigint AS "\(returningAffectedRowsColumn)" FROM "__widen_write"
            ),
            "__widen_limited" AS (
              SELECT row_number() OVER () AS "\(returningRowNumberColumn)", "__widen_write".*
              FROM "__widen_write"
              LIMIT \(streamLimit)
            )
            SELECT "__widen_limited".*, "__widen_count"."\(returningAffectedRowsColumn)"
            FROM "__widen_count"
            LEFT JOIN "__widen_limited" ON true
            """
    }

    private static func sqlWithoutTrailingTerminator(_ sql: String) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func hasTopLevelReturning(_ sql: String) -> Bool {
        let stripped = SQLSafetyValidator.strip(sql).text
        let chars = Array(stripped)
        var depth = 0
        var i = 0

        while i < chars.count {
            let char = chars[i]
            if isWordStart(char) {
                var token = ""
                while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                    token.append(chars[i])
                    i += 1
                }
                if depth == 0, token.uppercased() == "RETURNING" {
                    return true
                }
                continue
            }
            if char == "(" {
                depth += 1
            } else if char == ")", depth > 0 {
                depth -= 1
            }
            i += 1
        }
        return false
    }

    private static func isWordStart(_ char: Character) -> Bool {
        char.isLetter || char == "_"
    }

    private static func isWordPart(_ char: Character, tokenStarted: Bool) -> Bool {
        char.isLetter || char == "_" || (tokenStarted && (char.isNumber || char == "$"))
    }

    static func makeLogger(label: String) -> Logger {
        var logger = Logger(label: label)
        logger.logLevel = .critical
        return logger
    }

    nonisolated static func makeConfiguration(
        _ config: DatabaseConnectionConfig,
        password: String?
    ) -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch config.sslMode {
        case .disable:
            tls = .disable
        case .prefer, .require:
            // Local-development semantics: encrypt the connection but do not
            // verify the server certificate (local Postgres typically uses a
            // self-signed certificate, if any). Documented in the README.
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            tls = config.sslMode == .prefer ? .prefer(tlsConfig) : .require(tlsConfig)
        }

        var configuration = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: (password?.isEmpty ?? true) ? nil : password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        configuration.options.connectTimeout = .seconds(10)
        configuration.options.minimumConnections = 0
        configuration.options.maximumConnections = 4
        return configuration
    }

    /// One-shot connectivity check used by the settings screen. Never touches
    /// the live client.
    public static func testConnection(
        config: DatabaseConnectionConfig,
        password: String?
    ) async throws {
        try await probe(config: config, password: password)
    }

    /// Opens a single direct connection, runs `SELECT 1`, and closes it.
    /// Unlike the pooled client, a direct connection throws the server's real
    /// error (authentication failure, unknown database, refused connection)
    /// immediately.
    static func probe(config: DatabaseConnectionConfig, password: String?) async throws {
        let logger = makeLogger(label: "widen.postgres.probe")
        do {
            let configuration = try makeConnectionConfiguration(config, password: password)
            try await withTimeout(seconds: 15) {
                let connection = try await PostgresConnection.connect(
                    on: PostgresConnection.defaultEventLoopGroup.any(),
                    configuration: configuration,
                    id: 1,
                    logger: logger
                )
                do {
                    _ = try await connection.query("SELECT 1 AS ok", logger: logger).collect()
                    try await connection.close()
                } catch {
                    try? await connection.close()
                    throw error
                }
            }
        } catch {
            throw PostgresErrorMapper.map(error)
        }
    }

    nonisolated static func makeConnectionConfiguration(
        _ config: DatabaseConnectionConfig,
        password: String?
    ) throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS
        switch config.sslMode {
        case .disable:
            tls = .disable
        case .prefer, .require:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            // Unlike the pooled client, the direct-connection API takes a
            // pre-built NIOSSLContext.
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            tls = config.sslMode == .prefer ? .prefer(sslContext) : .require(sslContext)
        }
        return PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: (password?.isEmpty ?? true) ? nil : password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
    }

    /// Races `body` against a wall-clock timeout so the UI can never hang on a
    /// stuck connection attempt.
    static func withTimeout<T: Sendable>(
        seconds: Int,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TimeoutRaceState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let workerTask = Task {
                    do {
                        let value = try await body()
                        state.complete(.success(value), cancelWorker: false)
                    } catch {
                        state.complete(.failure(error), cancelWorker: false)
                    }
                }
                let timerTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        state.complete(
                            .failure(
                                AppError.connectionFailed(
                                    "Timed out waiting for the server to respond.")),
                            cancelWorker: true
                        )
                    } catch {
                        // The worker completed or the caller cancelled first.
                    }
                }
                state.install(
                    continuation: continuation,
                    workerTask: workerTask,
                    timerTask: timerTask
                )
            }
        } onCancel: {
            state.complete(.failure(CancellationError()), cancelWorker: true)
        }
    }
}

private final class WriteResultAccumulator: @unchecked Sendable {
    private let rowLimit: Int
    private let capturesLimitedReturning: Bool
    private let lock = NSLock()
    private var columns: [String] = []
    private var rows: [[String?]] = []
    private var returnedRowCount = 0
    private var affectedRows: Int?

    init(rowLimit: Int, capturesLimitedReturning: Bool = false) {
        self.rowLimit = max(rowLimit, 0)
        self.capturesLimitedReturning = capturesLimitedReturning
    }

    func record(_ row: PostgresRow) {
        lock.lock()
        defer { lock.unlock() }

        if capturesLimitedReturning {
            recordLimitedReturning(row)
            return
        }

        returnedRowCount += 1
        if columns.isEmpty {
            columns = row.map(\.columnName)
        }
        if rows.count < rowLimit {
            rows.append(row.map { PostgresCellFormatter.string(for: $0) })
        }
    }

    private func recordLimitedReturning(_ row: PostgresRow) {
        let randomAccess = row.makeRandomAccess()
        let columnNames = row.map(\.columnName)
        guard randomAccess.count >= 2 else { return }

        if columns.isEmpty {
            columns = Array(columnNames.dropFirst().dropLast())
        }
        if affectedRows == nil {
            let affectedRowsValue = PostgresCellFormatter.string(
                for: randomAccess[randomAccess.count - 1])
            affectedRows = affectedRowsValue.flatMap(Int.init)
        }

        let rowNumber = PostgresCellFormatter.string(for: randomAccess[0])
        guard rowNumber != nil else { return }

        returnedRowCount += 1
        if rows.count < rowLimit {
            rows.append(
                (1..<(randomAccess.count - 1)).map {
                    PostgresCellFormatter.string(for: randomAccess[$0])
                }
            )
        }
    }

    func snapshot(commandRows: Int?) -> (
        columns: [String], rows: [[String?]], rowCount: Int, truncated: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }

        let effectiveRowCount = affectedRows ?? commandRows ?? returnedRowCount
        return (
            columns: columns,
            rows: Array(rows.prefix(rowLimit)),
            rowCount: effectiveRowCount,
            truncated: capturesLimitedReturning
                ? effectiveRowCount > rowLimit
                : returnedRowCount > rowLimit
        )
    }
}

private final class TimeoutRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var workerTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var result: Result<T, any Error>?

    func install(
        continuation: CheckedContinuation<T, any Error>,
        workerTask: Task<Void, Never>,
        timerTask: Task<Void, Never>
    ) {
        let completed: Result<T, any Error>?

        lock.lock()
        if let result {
            completed = result
        } else {
            completed = nil
            self.continuation = continuation
            self.workerTask = workerTask
            self.timerTask = timerTask
        }
        lock.unlock()

        if let completed {
            workerTask.cancel()
            timerTask.cancel()
            continuation.resume(with: completed)
        }
    }

    func complete(_ result: Result<T, any Error>, cancelWorker: Bool) {
        let continuationToResume: CheckedContinuation<T, any Error>?
        let workerTaskToCancel: Task<Void, Never>?
        let timerTaskToCancel: Task<Void, Never>?

        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuationToResume = continuation
        workerTaskToCancel = workerTask
        timerTaskToCancel = timerTask
        continuation = nil
        workerTask = nil
        timerTask = nil
        lock.unlock()

        if cancelWorker {
            workerTaskToCancel?.cancel()
        }
        timerTaskToCancel?.cancel()
        continuationToResume?.resume(with: result)
    }
}
