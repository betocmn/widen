import CryptoKit
import Foundation

import WidenKit

struct DatabaseInspectionEvalRun: Codable {
    var manifest: DatabaseInspectionEvalManifest
    var results: [DatabaseInspectionEvalResult]
    var summary: DatabaseInspectionEvalSummary
    var acceptance: DatabaseInspectionEvalAcceptance
}

struct DatabaseInspectionEvalManifest: Codable {
    var suiteName: String
    var suiteVersion: String
    var commitSHA: String
    var startedAt: String
    var finishedAt: String
    var caseCount: Int
    var deterministicDigest: String
}

struct DatabaseInspectionEvalResult: Codable {
    var caseID: String
    var passed: Bool
    var messages: [String]
    var callsAttempted: Int
    var policyDeniedCalls: Int
    var redactedValues: Int
    var resultByteSizes: [Int]
    var latencyMs: Int
    var truncated: Bool
    var deterministicDigest: String
}

struct DatabaseInspectionEvalSummary: Codable {
    var caseCount: Int
    var passed: Int
    var failed: Int
    var callsAttempted: Int
    var policyDeniedCalls: Int
    var redactedValues: Int
    var maxResultBytes: Int
    var truncationCount: Int
    var totalLatencyMs: Int
}

struct DatabaseInspectionEvalAcceptance: Codable {
    var passed: Bool
    var messages: [String]
}

private struct StableDatabaseInspectionEvalResult: Codable {
    var caseID: String
    var passed: Bool
    var messages: [String]
    var callsAttempted: Int
    var policyDeniedCalls: Int
    var redactedValues: Int
    var truncated: Bool
    var deterministicDigest: String

    init(_ result: DatabaseInspectionEvalResult) {
        self.caseID = result.caseID
        self.passed = result.passed
        self.messages = result.messages
        self.callsAttempted = result.callsAttempted
        self.policyDeniedCalls = result.policyDeniedCalls
        self.redactedValues = result.redactedValues
        self.truncated = result.truncated
        self.deterministicDigest = result.deterministicDigest
    }
}

private struct StableDatabaseInspectionToolResult: Codable {
    var callID: String
    var toolName: String
    var success: Bool
    var payload: JSONValue?
    var error: DatabaseInspectionError?
    var truncation: DatabaseInspectionTruncation
    var diagnostic: StableDatabaseInspectionDiagnostic

    init(_ result: DatabaseInspectionResult) {
        self.callID = result.callID
        self.toolName = result.toolName
        self.success = result.success
        self.payload = result.payload
        self.error = result.error
        self.truncation = result.truncation
        self.diagnostic = StableDatabaseInspectionDiagnostic(result.diagnostic)
    }
}

private struct StableDatabaseInspectionDiagnostic: Codable {
    var toolName: String
    var tableID: String?
    var columnIDs: [String]
    var rowCount: Int
    var valueCount: Int
    var redactionCount: Int
    var cloudShareable: Bool
    var errorCode: DatabaseInspectionErrorCode?

    init(_ diagnostic: DatabaseInspectionDiagnostic) {
        self.toolName = diagnostic.toolName
        self.tableID = diagnostic.tableID
        self.columnIDs = diagnostic.columnIDs
        self.rowCount = diagnostic.rowCount
        self.valueCount = diagnostic.valueCount
        self.redactionCount = diagnostic.redactionCount
        self.cloudShareable = diagnostic.cloudShareable
        self.errorCode = diagnostic.errorCode
    }
}

struct DatabaseInspectionEvalRunner {
    var options: EvalCLIOptions

    func run() async throws -> DatabaseInspectionEvalRun {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var results: [DatabaseInspectionEvalResult] = []
        results.append(try await relationSizeCase())
        results.append(try await enumStatusCase())
        results.append(try await lowCardinalityStatusCase())
        results.append(try await dateMinMaxCase())
        results.append(try await nullableProfileCase())
        results.append(try await sensitiveRedactionCase())
        results.append(try await truncationCase())
        results.append(try await disabledPolicyCase())
        results.append(try await cloudPolicyCase())
        results.append(try await sampleRowsDisabledCase())
        results.append(try await ambiguousStatusCase())

        let summary = summarize(results)
        let acceptance = acceptance(results: results)
        let digest = try Self.sha256(
            JSONEncoder.schemaToolEncoder.encode(results.map(StableDatabaseInspectionEvalResult.init))
        )
        let finishedAt = ISO8601DateFormatter().string(from: Date())
        return DatabaseInspectionEvalRun(
            manifest: DatabaseInspectionEvalManifest(
                suiteName: "Database inspection tool eval",
                suiteVersion: "1",
                commitSHA: Self.commitSHA(),
                startedAt: startedAt,
                finishedAt: finishedAt,
                caseCount: results.count,
                deterministicDigest: digest
            ),
            results: results,
            summary: summary,
            acceptance: acceptance
        )
    }

    private func relationSizeCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.relationSize = DatabaseRelationSizeSnapshot(approximateRowCount: 1_250, source: "pg_class.reltuples")
        let workflow = try await singleCall(
            caseID: "relation-size.approximate-row-count",
            policy: .localDataInspection(),
            database: database,
            table: "orders",
            column: nil,
            tool: .inspectRelationSize
        )
        var messages = workflow.messages
        if workflow.results.first?.payload?["approximate_row_count"]?.intValue != 1_250 {
            messages.append("Relation size did not return expected estimate.")
        }
        if workflow.results.first?.payload?["full_table_scanned"]?.boolValue != false {
            messages.append("Relation size scanned the table.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func enumStatusCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(rowCount: 3, nullCount: 0, distinctCount: 2)
        database.distinctRows = [
            DatabaseDistinctValueRow(value: .text("active", cap: 160), count: 2),
            DatabaseDistinctValueRow(value: .text("disabled", cap: 160), count: 1),
        ]
        let workflow = try await singleCall(
            caseID: "status.enum-constrained-values",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "accounts",
            column: "state",
            tool: .inspectDistinctValues
        )
        var messages = workflow.messages
        let text = try encodedPayloadText(workflow.results)
        if !text.contains("active") || !text.contains("disabled") {
            messages.append("Enum-like status values were not recovered.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func lowCardinalityStatusCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(rowCount: 4, nullCount: 0, distinctCount: 2)
        database.distinctRows = [
            DatabaseDistinctValueRow(value: .text("paid", cap: 160), count: 3),
            DatabaseDistinctValueRow(value: .text("refunded", cap: 160), count: 1),
        ]
        let workflow = try await singleCall(
            caseID: "status.live-low-cardinality-values",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "orders",
            column: "status",
            tool: .inspectDistinctValues
        )
        var messages = workflow.messages
        let text = try encodedPayloadText(workflow.results)
        if !text.contains("paid") || !text.contains("refunded") {
            messages.append("Low-cardinality live values were not returned.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func dateMinMaxCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(
            rowCount: 5,
            nullCount: 0,
            distinctCount: 5,
            minValue: .date("2026-01-01"),
            maxValue: .date("2026-02-15")
        )
        let workflow = try await singleCall(
            caseID: "date-profile.min-max",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "orders",
            column: "created_at",
            tool: .inspectColumnProfile
        )
        var messages = workflow.messages
        if workflow.results.first?.payload?["min"]?["value"]?.stringValue != "2026-01-01" {
            messages.append("Date min was not returned.")
        }
        if workflow.results.first?.payload?["max"]?["value"]?.stringValue != "2026-02-15" {
            messages.append("Date max was not returned.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func nullableProfileCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(rowCount: 10, nullCount: 4, distinctCount: 2)
        let workflow = try await singleCall(
            caseID: "nullable-column.profile",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "tickets",
            column: "resolved_at",
            tool: .inspectColumnProfile
        )
        var messages = workflow.messages
        if workflow.results.first?.payload?["null_count"]?.intValue != 4 {
            messages.append("Null count was not returned.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func sensitiveRedactionCase() async throws -> DatabaseInspectionEvalResult {
        let workflow = try await singleCall(
            caseID: "privacy.sensitive-column-redaction",
            policy: .localDataInspection(allowFullTableScans: true),
            database: EvalInspectionDatabase(),
            table: "accounts",
            column: "email",
            tool: .inspectDistinctValues
        )
        var messages = workflow.messages
        if workflow.results.first?.payload?["redacted"]?.boolValue != true {
            messages.append("Sensitive email column was not redacted.")
        }
        if workflow.results.first?.diagnostic.redactionCount != 1 {
            messages.append("Redaction count was not reported.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func truncationCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(rowCount: 10, nullCount: 0, distinctCount: 3)
        database.distinctRows = [
            DatabaseDistinctValueRow(value: .text("paid", cap: 160), count: 5),
            DatabaseDistinctValueRow(value: .text("refunded", cap: 160), count: 3),
            DatabaseDistinctValueRow(value: .text("pending", cap: 160), count: 2),
        ]
        let workflow = try await singleCall(
            caseID: "bounds.distinct-value-truncation",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "orders",
            column: "status",
            tool: .inspectDistinctValues,
            argumentsExtra: ["limit": 2]
        )
        var messages = workflow.messages
        if workflow.results.first?.truncation.truncated != true {
            messages.append("Distinct values were not marked truncated.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func disabledPolicyCase() async throws -> DatabaseInspectionEvalResult {
        let workflow = try await singleCall(
            caseID: "policy.disabled",
            policy: .disabled,
            database: EvalInspectionDatabase(),
            table: "orders",
            column: nil,
            tool: .inspectRelationSize
        )
        var messages = workflow.messages
        if workflow.results.first?.error?.code != .policyDenied {
            messages.append("Disabled policy did not return policyDenied.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func cloudPolicyCase() async throws -> DatabaseInspectionEvalResult {
        var policy = DatabaseInspectionPolicy.localDataInspection(allowFullTableScans: true)
        policy.audience = .cloud
        policy.allowCloudDataInspection = false
        let workflow = try await singleCall(
            caseID: "policy.cloud-data-denied",
            policy: policy,
            database: EvalInspectionDatabase(),
            table: "orders",
            column: "status",
            tool: .inspectDistinctValues
        )
        var messages = workflow.messages
        if workflow.results.first?.error?.code != .policyDenied {
            messages.append("Cloud data policy did not reject data-valued output.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func sampleRowsDisabledCase() async throws -> DatabaseInspectionEvalResult {
        let workflow = try await singleCall(
            caseID: "policy.sample-rows-disabled",
            policy: .localDataInspection(allowFullTableScans: true),
            database: EvalInspectionDatabase(),
            table: "orders",
            column: "status",
            tool: .inspectSampleRows
        )
        var messages = workflow.messages
        if workflow.results.first?.error?.code != .policyDenied {
            messages.append("Sample rows were not disabled by default.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private func ambiguousStatusCase() async throws -> DatabaseInspectionEvalResult {
        let database = EvalInspectionDatabase()
        database.aggregate = DatabaseColumnAggregateSnapshot(rowCount: 3, nullCount: 0, distinctCount: 2)
        database.distinctRows = [
            DatabaseDistinctValueRow(value: .text("resolved", cap: 160), count: 2),
            DatabaseDistinctValueRow(value: .text("unresolved", cap: 160), count: 1),
        ]
        let workflow = try await singleCall(
            caseID: "ambiguous-schema.distinct-values-clarify-filter",
            policy: .localDataInspection(allowFullTableScans: true),
            database: database,
            table: "tickets",
            column: "state",
            tool: .inspectDistinctValues
        )
        var messages = workflow.messages
        let text = try encodedPayloadText(workflow.results)
        if !text.contains("resolved") || !text.contains("unresolved") {
            messages.append("Distinct values did not disambiguate ticket state.")
        }
        return try await result(workflow.caseID, messages: messages, session: workflow.session, results: workflow.results)
    }

    private struct Workflow {
        var caseID: String
        var messages: [String]
        var session: DatabaseInspectionToolSession
        var results: [DatabaseInspectionResult]
    }

    private func singleCall(
        caseID: String,
        policy: DatabaseInspectionPolicy,
        database: EvalInspectionDatabase,
        table tableName: String,
        column columnName: String?,
        tool: DatabaseInspectionToolName,
        argumentsExtra: [String: JSONValue] = [:]
    ) async throws -> Workflow {
        let session = try makeSession(policy: policy, database: database)
        let tableHandle = try await requireHandle(
            session,
            .table(schema: "public", name: tableName)
        )
        var arguments: [String: JSONValue] = ["table_id": .string(tableHandle)]
        if let columnName {
            let columnHandle = try await requireHandle(
                session,
                .column(schema: "public", table: tableName, name: columnName)
            )
            if tool == .inspectSampleRows {
                arguments["column_ids"] = .array([.string(columnHandle)])
            } else {
                arguments["column_id"] = .string(columnHandle)
            }
        }
        arguments.merge(argumentsExtra) { _, new in new }
        let result = try await session.invoke(
            DatabaseInspectionToolInvocation(
                callID: caseID,
                toolName: tool.rawValue,
                arguments: .object(arguments)
            )
        )
        return Workflow(caseID: caseID, messages: [], session: session, results: [result])
    }

    private func makeSession(
        policy: DatabaseInspectionPolicy,
        database: EvalInspectionDatabase
    ) throws -> DatabaseInspectionToolSession {
        let schema = Self.schema()
        let snapshot = SchemaSearchSnapshot(
            connectionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            selectedSchemas: ["public"],
            schema: schema
        )
        return try DatabaseInspectionToolSessionFactory().makeSession(
            snapshot: snapshot,
            policy: policy,
            database: database
        )
    }

    private func requireHandle(
        _ session: DatabaseInspectionToolSession,
        _ objectID: SchemaObjectID
    ) async throws -> String {
        guard let handle = await session.handle(for: objectID) else {
            throw EvalCLIError.invalidValue("handle", objectID.description)
        }
        return handle
    }

    private func result(
        _ caseID: String,
        messages: [String],
        session: DatabaseInspectionToolSession,
        results: [DatabaseInspectionResult]
    ) async throws -> DatabaseInspectionEvalResult {
        let traceSnapshot = await session.tracesSnapshot()
        let payloadData = try JSONEncoder.schemaToolEncoder.encode(
            results.map(StableDatabaseInspectionToolResult.init)
        )
        let policyDenied = results.filter { $0.error?.code == .policyDenied }.count
        return DatabaseInspectionEvalResult(
            caseID: caseID,
            passed: messages.isEmpty,
            messages: messages,
            callsAttempted: results.count,
            policyDeniedCalls: policyDenied,
            redactedValues: traceSnapshot.reduce(0) { $0 + $1.redactionCount },
            resultByteSizes: results.map(\.outputByteCount),
            latencyMs: traceSnapshot.reduce(0) { $0 + $1.latencyMs },
            truncated: results.contains { $0.truncation.truncated },
            deterministicDigest: Self.sha256(payloadData)
        )
    }

    private func encodedPayloadText(_ results: [DatabaseInspectionResult]) throws -> String {
        String(decoding: try JSONEncoder.schemaToolEncoder.encode(results.map(\.payload)), as: UTF8.self)
    }

    private func summarize(_ results: [DatabaseInspectionEvalResult]) -> DatabaseInspectionEvalSummary {
        DatabaseInspectionEvalSummary(
            caseCount: results.count,
            passed: results.filter(\.passed).count,
            failed: results.filter { !$0.passed }.count,
            callsAttempted: results.reduce(0) { $0 + $1.callsAttempted },
            policyDeniedCalls: results.reduce(0) { $0 + $1.policyDeniedCalls },
            redactedValues: results.reduce(0) { $0 + $1.redactedValues },
            maxResultBytes: results.flatMap(\.resultByteSizes).max() ?? 0,
            truncationCount: results.filter(\.truncated).count,
            totalLatencyMs: results.reduce(0) { $0 + $1.latencyMs }
        )
    }

    private func acceptance(results: [DatabaseInspectionEvalResult]) -> DatabaseInspectionEvalAcceptance {
        let failures = results.filter { !$0.passed }
        if failures.isEmpty {
            return DatabaseInspectionEvalAcceptance(passed: true, messages: [])
        }
        return DatabaseInspectionEvalAcceptance(
            passed: false,
            messages: failures.map { "\($0.caseID): \($0.messages.joined(separator: "; "))" }
        )
    }

    private static func schema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table("accounts", [
                    column("id", "integer", false, 1, table: "accounts"),
                    column("email", "text", false, 2, table: "accounts"),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "accounts",
                        name: "state",
                        dataType: "text",
                        isNullable: false,
                        ordinalPosition: 3,
                        valueConstraints: [
                            ColumnValueConstraint(kind: .check, values: ["active", "disabled"])
                        ]
                    ),
                ]),
                table("orders", [
                    column("id", "integer", false, 1, table: "orders"),
                    column("status", "text", false, 2, table: "orders"),
                    column("created_at", "date", false, 3, table: "orders"),
                ]),
                table("tickets", [
                    column("id", "integer", false, 1, table: "tickets"),
                    column("state", "text", false, 2, table: "tickets"),
                    column("resolved_at", "timestamp with time zone", true, 3, table: "tickets"),
                ]),
            ]
        )
    }

    private static func table(_ name: String, _ columns: [ColumnInfo]) -> TableInfo {
        TableInfo(schema: "public", name: name, type: .baseTable, columns: columns)
    }

    private static func column(
        _ name: String,
        _ dataType: String,
        _ nullable: Bool,
        _ ordinal: Int,
        table: String
    ) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: table,
            name: name,
            dataType: dataType,
            isNullable: nullable,
            ordinalPosition: ordinal
        )
    }

    private static func commitSHA() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "unknown" : text
        } catch {
            return "unknown"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class EvalInspectionDatabase: DatabaseInspectionQuerying, @unchecked Sendable {
    var relationSize = DatabaseRelationSizeSnapshot(approximateRowCount: 10, source: "fake")
    var statistics = DatabaseColumnStatisticsSnapshot(approximateNullFraction: 0.1, approximateDistinctCount: 2)
    var aggregate = DatabaseColumnAggregateSnapshot(rowCount: 3, nullCount: 0, distinctCount: 2)
    var distinctRows = [
        DatabaseDistinctValueRow(value: .text("active", cap: 160), count: 2),
        DatabaseDistinctValueRow(value: .text("disabled", cap: 160), count: 1),
    ]

    func inspectRelationSize(
        schema: String,
        table: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseRelationSizeSnapshot {
        relationSize
    }

    func inspectColumnStatistics(
        schema: String,
        table: String,
        column: String,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnStatisticsSnapshot {
        statistics
    }

    func inspectColumnAggregate(
        table: TableInfo,
        column: ColumnInfo,
        includeDistinct: Bool,
        includeMinMax: Bool,
        policy: DatabaseInspectionPolicy
    ) async throws -> DatabaseColumnAggregateSnapshot {
        aggregate
    }

    func inspectDistinctValues(
        table: TableInfo,
        column: ColumnInfo,
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseDistinctValueRow] {
        distinctRows
    }

    func inspectSampleRows(
        table: TableInfo,
        columns: [ColumnInfo],
        limit: Int,
        policy: DatabaseInspectionPolicy
    ) async throws -> [DatabaseSampleRow] {
        []
    }
}
