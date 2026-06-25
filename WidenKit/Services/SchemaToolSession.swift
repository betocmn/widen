import CryptoKit
import Foundation

public struct SchemaToolExecutor: Sendable {
    public init() {}

    func execute(
        _ invocation: SchemaToolInvocation,
        snapshot: SchemaSearchSnapshot,
        searcher: any SchemaSearching,
        handles: SchemaToolHandleRegistry,
        policy: SchemaToolPolicy,
        matchedColumnsByTable: [String: Set<SchemaObjectID>]
    ) -> SchemaToolExecution {
        guard let toolName = SchemaToolName(rawValue: invocation.toolName) else {
            return .failure(
                .init(
                    code: .unknownTool,
                    message: "Unknown schema tool.",
                    argument: "tool_name"
                )
            )
        }
        guard let arguments = invocation.arguments.objectValue else {
            return .failure(
                .init(
                    code: .malformedArguments,
                    message: "Tool arguments must be a JSON object."
                )
            )
        }

        switch toolName {
        case .searchSchema:
            return searchSchema(
                arguments: arguments,
                snapshot: snapshot,
                searcher: searcher,
                handles: handles
            )
        case .describeTables:
            return describeTables(
                arguments: arguments,
                snapshot: snapshot,
                searcher: searcher,
                handles: handles,
                policy: policy,
                matchedColumnsByTable: matchedColumnsByTable
            )
        case .findJoinPaths:
            return findJoinPaths(
                arguments: arguments,
                snapshot: snapshot,
                searcher: searcher,
                handles: handles
            )
        case .inspectColumnConstraints:
            return inspectColumnConstraints(
                arguments: arguments,
                snapshot: snapshot,
                handles: handles
            )
        }
    }

    private func searchSchema(
        arguments: [String: JSONValue],
        snapshot: SchemaSearchSnapshot,
        searcher: any SchemaSearching,
        handles: SchemaToolHandleRegistry
    ) -> SchemaToolExecution {
        if let validation = validateKeys(arguments, allowed: ["query", "limit"]) {
            return .failure(validation)
        }

        guard let query = arguments["query"]?.stringValue else {
            return .failure(missingOrTyped(arguments, key: "query", expected: "string"))
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return .failure(.range("Search query must be 1...256 characters.", argument: "query"))
        }
        guard trimmedQuery.count <= 256 else {
            return .failure(.range("Search query must be 1...256 characters.", argument: "query"))
        }
        let limit: Int
        if let value = arguments["limit"] {
            guard let intValue = value.intValue else {
                return .failure(.typed("limit must be an integer.", argument: "limit"))
            }
            guard (1...8).contains(intValue) else {
                return .failure(.range("limit must be in 1...8.", argument: "limit"))
            }
            limit = intValue
        } else {
            limit = 8
        }

        let response = searcher.search(
            SchemaSearchRequest(query: trimmedQuery, limit: limit),
            in: snapshot
        )
        let tablesByID = handles.tablesByStableID
        var matchedByTable: [String: Set<SchemaObjectID>] = [:]
        let hits = response.hits.compactMap { hit -> JSONValue? in
            guard let table = tablesByID[hit.tableObjectID.stableString],
                let tableHandle = handles.handle(for: hit.tableObjectID)
            else {
                return nil
            }
            let matchedColumns = compactColumns(
                hit.matchedColumnIDs,
                handles: handles,
                table: table,
                limit: 8
            )
            matchedByTable[hit.tableObjectID.stableString] = Set(hit.matchedColumnIDs)
            let relevantColumns = compactColumns(
                relevantColumns(
                    for: table,
                    matched: hit.matchedColumnIDs,
                    relationships: snapshot.schemaSearchRelationships,
                    query: trimmedQuery
                ),
                handles: handles,
                table: table,
                limit: 8
            )
            return [
                "table_id": .string(tableHandle),
                "sql_name": .string(quotedTableName(table.schema, table.name)),
                "table_type": .string(table.type.rawValue),
                "match_reasons": .array(matchReasons(hit.matchedFields).map { .string($0) }),
                "matched_columns": .array(matchedColumns),
                "relevant_columns": .array(relevantColumns),
            ]
        }

        return .success(
            payload: [
                "hits": .array(hits),
                "no_strong_match": .bool(response.noStrongMatch),
                "exact_identifier_match": .bool(response.exactIdentifierMatch),
                "query_token_coverage": .number(response.queryTokenCoverage),
            ],
            returnedObjectCount: hits.count,
            matchedColumnIDsByTable: matchedByTable
        )
    }

    private func describeTables(
        arguments: [String: JSONValue],
        snapshot: SchemaSearchSnapshot,
        searcher: any SchemaSearching,
        handles: SchemaToolHandleRegistry,
        policy: SchemaToolPolicy,
        matchedColumnsByTable: [String: Set<SchemaObjectID>]
    ) -> SchemaToolExecution {
        if let validation = validateKeys(
            arguments,
            allowed: ["table_ids", "focus_column_ids"]
        ) {
            return .failure(validation)
        }

        guard let tableIDValues = arguments["table_ids"]?.arrayValue else {
            return .failure(missingOrTyped(arguments, key: "table_ids", expected: "array"))
        }
        guard (1...4).contains(tableIDValues.count) else {
            return .failure(.range("table_ids must contain 1...4 handles.", argument: "table_ids"))
        }
        let tableIDs: [SchemaObjectID]
        do {
            tableIDs = try tableIDValues.enumerated().map { offset, value in
                guard let handle = value.stringValue else {
                    throw SchemaToolError.typed(
                        "table_ids[\(offset)] must be a string.",
                        argument: "table_ids"
                    )
                }
                return try handles.resolve(handle, expectedKind: .table)
            }
        } catch let error as SchemaToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure("Failed to resolve table handles."))
        }

        let focusValues = arguments["focus_column_ids"]?.arrayValue ?? []
        guard focusValues.count <= 16 else {
            return .failure(
                .range("focus_column_ids may contain at most 16 handles.", argument: "focus_column_ids")
            )
        }
        let focusIDs: [SchemaObjectID]
        do {
            focusIDs = try focusValues.enumerated().map { offset, value in
                guard let handle = value.stringValue else {
                    throw SchemaToolError.typed(
                        "focus_column_ids[\(offset)] must be a string.",
                        argument: "focus_column_ids"
                    )
                }
                return try handles.resolve(handle, expectedKind: .column)
            }
        } catch let error as SchemaToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure("Failed to resolve focus column handles."))
        }

        let tableStableIDs = Set(tableIDs.map(\.stableString))
        for columnID in focusIDs {
            guard let tableName = columnID.table else {
                return .failure(.objectKind("Focus handle is not a column.", argument: "focus_column_ids"))
            }
            let parent = SchemaObjectID.table(schema: columnID.schema, name: tableName)
            guard tableStableIDs.contains(parent.stableString) else {
                return .failure(
                    .init(
                        code: .columnTableMismatch,
                        message: "Focus column does not belong to the supplied table handles.",
                        argument: "focus_column_ids"
                    )
                )
            }
        }

        let descriptions = searcher.describe(objectIDs: tableIDs, in: snapshot)
        guard descriptions.count == tableIDs.count else {
            return .failure(.stale("A table handle is outside the current schema snapshot.", argument: "table_ids"))
        }

        let focusByTable = Dictionary(grouping: focusIDs) {
            SchemaObjectID.table(schema: $0.schema, name: $0.table ?? "").stableString
        }
        var truncated = false
        var cards = tableCards(
            tableIDs: tableIDs,
            snapshot: snapshot,
            handles: handles,
            focusByTable: focusByTable,
            matchedColumnsByTable: matchedColumnsByTable,
            maxColumnsPerTable: 36,
            maxRelationshipsPerTable: 24,
            truncated: &truncated
        )
        var payload: JSONValue = [
            "tables": .array(cards),
            "truncated": .bool(truncated),
        ]

        var maxColumns = 24
        var maxRelationships = 12
        while (try? payload.utf8ByteCount()) ?? Int.max > max(512, policy.maximumResultBytes - 512),
            (maxColumns > 8 || maxRelationships > 4)
        {
            truncated = true
            maxColumns = max(8, maxColumns / 2)
            maxRelationships = max(4, maxRelationships / 2)
            cards = tableCards(
                tableIDs: tableIDs,
                snapshot: snapshot,
                handles: handles,
                focusByTable: focusByTable,
                matchedColumnsByTable: matchedColumnsByTable,
                maxColumnsPerTable: maxColumns,
                maxRelationshipsPerTable: maxRelationships,
                truncated: &truncated
            )
            payload = [
                "tables": .array(cards),
                "truncated": .bool(truncated),
                "next_tool_suggestion": .string("Call describe_tables with fewer table_ids or focus_column_ids for omitted columns."),
            ]
        }

        return .success(
            payload: payload,
            truncation: SchemaToolTruncation(
                truncated: truncated,
                reason: truncated ? "semantic_boundary_limit" : nil,
                suggestion: truncated ? "Call describe_tables with fewer table_ids or focus_column_ids." : nil
            ),
            returnedObjectCount: cards.count
        )
    }

    private func findJoinPaths(
        arguments: [String: JSONValue],
        snapshot: SchemaSearchSnapshot,
        searcher: any SchemaSearching,
        handles: SchemaToolHandleRegistry
    ) -> SchemaToolExecution {
        if let validation = validateKeys(
            arguments,
            allowed: ["from_table_id", "to_table_id", "max_hops", "max_paths"]
        ) {
            return .failure(validation)
        }

        let from: SchemaObjectID
        let to: SchemaObjectID
        do {
            from = try resolveTableID(arguments, key: "from_table_id", handles: handles)
            to = try resolveTableID(arguments, key: "to_table_id", handles: handles)
        } catch let error as SchemaToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure("Failed to resolve join endpoints."))
        }
        let maxHops: Int
        do {
            maxHops = try requiredInt(arguments, key: "max_hops", range: 1...3)
        } catch let error as SchemaToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure("Failed to validate max_hops."))
        }
        let maxPaths: Int
        if arguments["max_paths"] != nil {
            do {
                maxPaths = try requiredInt(arguments, key: "max_paths", range: 1...3)
            } catch let error as SchemaToolError {
                return .failure(error)
            } catch {
                return .failure(.internalFailure("Failed to validate max_paths."))
            }
        } else {
            maxPaths = 3
        }

        let paths = Array(
            searcher.findJoinPaths(from: from, to: to, maxHops: maxHops, in: snapshot)
                .prefix(maxPaths)
        )
        let pathObjects = paths.map { path in
            JSONValue.object([
                "hop_count": .number(Double(path.hopCount)),
                "edges": .array(path.edges.map { edge in
                    [
                        "traversal_direction": .string(edge.traversalDirection.rawValue),
                        "constraint_name": .string(sanitizedMetadata(edge.constraintName, maxCharacters: 160)),
                        "from_table": .string(quotedName(edge.fromTableID)),
                        "to_table": .string(quotedName(edge.toTableID)),
                        "source_table": .string(quotedName(edge.sourceTableID)),
                        "target_table": .string(quotedName(edge.targetTableID)),
                        "column_pairs": .array(edge.columnPairs.map { pair in
                            [
                                "source_column": .string(quotedIdentifier(pair.sourceColumn)),
                                "target_column": .string(quotedIdentifier(pair.targetColumn)),
                                "ordinal_position": .number(Double(pair.ordinalPosition)),
                            ]
                        }),
                    ]
                }),
            ])
        }
        return .success(
            payload: [
                "source_table": .string(quotedName(from)),
                "target_table": .string(quotedName(to)),
                "paths": .array(pathObjects),
                "no_path": .bool(pathObjects.isEmpty),
            ],
            returnedObjectCount: pathObjects.count
        )
    }

    private func inspectColumnConstraints(
        arguments: [String: JSONValue],
        snapshot: SchemaSearchSnapshot,
        handles: SchemaToolHandleRegistry
    ) -> SchemaToolExecution {
        if let validation = validateKeys(arguments, allowed: ["table_id", "column_id"]) {
            return .failure(validation)
        }

        let tableID: SchemaObjectID
        let columnID: SchemaObjectID
        do {
            tableID = try resolveTableID(arguments, key: "table_id", handles: handles)
            columnID = try resolveColumnID(arguments, key: "column_id", handles: handles)
        } catch let error as SchemaToolError {
            return .failure(error)
        } catch {
            return .failure(.internalFailure("Failed to resolve handles."))
        }
        guard columnID.schema == tableID.schema,
            columnID.table == tableID.table
        else {
            return .failure(
                .init(
                    code: .columnTableMismatch,
                    message: "column_id does not belong to table_id.",
                    argument: "column_id"
                )
            )
        }
        guard let table = handles.tablesByStableID[tableID.stableString],
            let columnName = columnID.column,
            let column = table.columns.first(where: { $0.name == columnName })
        else {
            return .failure(.stale("Column handle is outside the current schema snapshot.", argument: "column_id"))
        }

        let valueLimit = 32
        let constraints = (column.valueConstraints ?? []).prefix(16).map { constraint -> JSONValue in
            let values = constraint.values.prefix(valueLimit).map {
                JSONValue.string(sanitizedMetadata($0, maxCharacters: 160))
            }
            var object: [String: JSONValue] = [
                "kind": .string(constraint.kind.rawValue),
                "database_values": .array(Array(values)),
                "values_complete": .bool(!constraint.values.isEmpty && constraint.values.count <= valueLimit),
                "unparsed_check_exists": .bool(
                    constraint.kind == .check
                        && constraint.values.isEmpty
                        && constraint.expression?.isEmpty == false
                ),
            ]
            if let name = constraint.constraintName {
                object["constraint_name"] = .string(sanitizedMetadata(name, maxCharacters: 160))
            }
            if let expression = constraint.expression, constraint.values.isEmpty {
                object["database_check_expression"] = .string(
                    sanitizedMetadata(expression, maxCharacters: 240)
                )
            }
            if constraint.values.count > valueLimit {
                object["omitted_value_count"] = .number(Double(constraint.values.count - valueLimit))
            }
            return .object(object)
        }
        let enumValues = (column.valueConstraints ?? [])
            .filter { $0.kind == .enumValues }
            .flatMap(\.values)
            .prefix(32)
            .map { JSONValue.string(sanitizedMetadata($0, maxCharacters: 160)) }
        let checkValues = (column.valueConstraints ?? [])
            .filter { $0.kind == .check }
            .flatMap(\.values)
            .prefix(32)
            .map { JSONValue.string(sanitizedMetadata($0, maxCharacters: 160)) }
        let unparsed = (column.valueConstraints ?? []).contains {
            $0.kind == .check && $0.values.isEmpty && $0.expression?.isEmpty == false
        }

        return .success(
            payload: [
                "table_id": .string(handles.handle(for: tableID) ?? ""),
                "column_id": .string(handles.handle(for: columnID) ?? ""),
                "sql_name": .string(quotedColumnName(column)),
                "enum_values": .array(Array(enumValues)),
                "check_values": .array(Array(checkValues)),
                "constraints": .array(Array(constraints)),
                "finite_values_known": .bool(!enumValues.isEmpty || !checkValues.isEmpty),
                "unparsed_check_exists": .bool(unparsed),
                "live_data_queried": false,
            ],
            returnedObjectCount: enumValues.count + checkValues.count
        )
    }
}

public actor SchemaToolSession {
    private let snapshot: SchemaSearchSnapshot
    private let searcher: any SchemaSearching
    private let schemaFingerprint: String
    private let selectedSchemas: [String]
    private let policy: SchemaToolPolicy
    private let executor: SchemaToolExecutor
    private let handles: SchemaToolHandleRegistry
    private var callCount = 0
    private var cumulativeOutputBytes = 0
    private var traces: [SchemaToolCallTrace] = []
    private var cache: [SchemaToolInvocationCacheKey: SchemaToolCachedExecution] = [:]
    private var matchedColumnsByTable: [String: Set<SchemaObjectID>] = [:]

    public init(
        snapshot: SchemaSearchSnapshot,
        searcher: any SchemaSearching,
        schemaFingerprint: String,
        selectedSchemas: [String],
        policy: SchemaToolPolicy,
        executor: SchemaToolExecutor = SchemaToolExecutor()
    ) {
        let sortedSelectedSchemas = selectedSchemas.sorted()
        self.snapshot = snapshot
        self.searcher = searcher
        self.schemaFingerprint = schemaFingerprint
        self.selectedSchemas = sortedSelectedSchemas
        self.policy = policy
        self.executor = executor
        self.handles = SchemaToolHandleRegistry(
            snapshot: snapshot,
            schemaFingerprint: schemaFingerprint,
            selectedSchemas: sortedSelectedSchemas
        )
    }

    public nonisolated var definitions: [SchemaToolDefinition] {
        SchemaToolRegistry.definitions
    }

    public func handle(for objectID: SchemaObjectID) -> String? {
        handles.handle(for: objectID)
    }

    public func tracesSnapshot() -> [SchemaToolCallTrace] {
        traces
    }

    public func invoke(
        callID: String,
        toolName: String,
        argumentsJSON: Data
    ) async throws -> SchemaToolResult {
        try Task.checkCancellation()
        let arguments: JSONValue
        do {
            arguments = try JSONDecoder().decode(JSONValue.self, from: argumentsJSON)
        } catch {
            return try await invoke(
                SchemaToolInvocation(callID: callID, toolName: toolName, arguments: .object([:])),
                forcedError: .init(
                    code: .malformedArguments,
                    message: "Tool arguments are malformed JSON."
                )
            )
        }
        return try await invoke(SchemaToolInvocation(callID: callID, toolName: toolName, arguments: arguments))
    }

    public func invoke(_ invocation: SchemaToolInvocation) async throws -> SchemaToolResult {
        try await invoke(invocation, forcedError: nil)
    }

    public func invoke(_ invocations: [SchemaToolInvocation]) async throws -> [SchemaToolResult] {
        var results: [SchemaToolResult] = []
        results.reserveCapacity(invocations.count)
        for invocation in invocations {
            results.append(try await invoke(invocation, forcedError: nil))
        }
        return results
    }

    private func invoke(
        _ invocation: SchemaToolInvocation,
        forcedError: SchemaToolError?
    ) async throws -> SchemaToolResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now

        let cacheKey = SchemaToolInvocationCacheKey(invocation: invocation)
        let cachedExecution = forcedError == nil ? cache[cacheKey]?.execution : nil
        let cacheHit = cachedExecution != nil
        let countsAgainstCallBudget = !cacheHit || policy.countCachedCalls

        guard !countsAgainstCallBudget || callCount < policy.maximumCallCount else {
            return record(
                result: finalizedError(
                    callID: invocation.callID,
                    toolName: invocation.toolName,
                    error: .init(
                        code: .sessionBudgetExceeded,
                        message: "Schema tool call budget exceeded."
                    )
                ),
                started: started,
                returnedObjectCount: 0,
                cacheHit: false
            )
        }
        if countsAgainstCallBudget {
            callCount += 1
        }

        let execution: SchemaToolExecution
        if let forcedError {
            execution = .failure(forcedError)
        } else if let cachedExecution {
            execution = cachedExecution
        } else {
            execution = executor.execute(
                invocation,
                snapshot: snapshot,
                searcher: searcher,
                handles: handles,
                policy: policy,
                matchedColumnsByTable: matchedColumnsByTable
            )
            cache[cacheKey] = SchemaToolCachedExecution(execution: execution)
        }

        for (tableID, columns) in execution.matchedColumnIDsByTable {
            matchedColumnsByTable[tableID, default: []].formUnion(columns)
        }

        var result = finalizedResult(
            callID: invocation.callID,
            toolName: invocation.toolName,
            execution: execution
        )
        if result.outputByteCount > policy.maximumResultBytes {
            result = finalizedError(
                callID: invocation.callID,
                toolName: invocation.toolName,
                error: .init(
                    code: .resultBudgetExceeded,
                    message: "Schema tool result exceeded the per-call output budget."
                ),
                truncation: SchemaToolTruncation(
                    truncated: true,
                    reason: "result_budget_exceeded",
                    suggestion: "Call the tool with fewer IDs or a lower limit."
                )
            )
        }
        if cumulativeOutputBytes + result.outputByteCount > policy.maximumSessionResultBytes {
            result = finalizedError(
                callID: invocation.callID,
                toolName: invocation.toolName,
                error: .init(
                    code: .sessionBudgetExceeded,
                    message: "Schema tool session output budget exceeded."
                )
            )
        }
        cumulativeOutputBytes += result.outputByteCount
        return record(
            result: result,
            started: started,
            returnedObjectCount: execution.returnedObjectCount,
            cacheHit: cacheHit
        )
    }

    private func record(
        result: SchemaToolResult,
        started: ContinuousClock.Instant,
        returnedObjectCount: Int,
        cacheHit: Bool
    ) -> SchemaToolResult {
        traces.append(
            SchemaToolCallTrace(
                callID: result.callID,
                toolName: result.toolName,
                outcome: result.success ? .success : .error,
                latencyMs: schemaSearchMilliseconds(started.duration(to: .now)),
                returnedObjectCount: result.success ? returnedObjectCount : 0,
                outputByteCount: result.outputByteCount,
                truncated: result.truncation.truncated,
                errorCode: result.error?.code,
                schemaFingerprintPrefix: String(schemaFingerprint.prefix(12)),
                cacheHit: cacheHit
            )
        )
        return result
    }

    private func finalizedResult(
        callID: String,
        toolName: String,
        execution: SchemaToolExecution
    ) -> SchemaToolResult {
        switch execution {
        case .success(let payload, let truncation, _, _):
            return finalized(
                SchemaToolResult(
                    callID: callID,
                    toolName: toolName,
                    success: true,
                    payload: payload,
                    error: nil,
                    truncation: truncation
                )
            )
        case .failure(let error):
            return finalizedError(callID: callID, toolName: toolName, error: error)
        }
    }

    private func finalizedError(
        callID: String,
        toolName: String,
        error: SchemaToolError,
        truncation: SchemaToolTruncation = SchemaToolTruncation()
    ) -> SchemaToolResult {
        finalized(
            SchemaToolResult(
                callID: callID,
                toolName: toolName,
                success: false,
                payload: error.payload,
                error: error,
                truncation: truncation
            )
        )
    }

    private func finalized(_ result: SchemaToolResult) -> SchemaToolResult {
        var result = result
        for _ in 0..<6 {
            let bytes = (try? JSONEncoder.schemaToolEncoder.encode(result).count) ?? 0
            if bytes == result.outputByteCount {
                return result
            }
            result.outputByteCount = bytes
        }
        return result
    }
}

public struct SchemaToolSessionFactory: Sendable {
    private let indexStore: SchemaSearchIndexStore

    public init(indexStore: SchemaSearchIndexStore) {
        self.indexStore = indexStore
    }

    public func makeSession(
        snapshot: SchemaSearchSnapshot,
        policy: SchemaToolPolicy
    ) async throws -> SchemaToolSession {
        let searcher = try await indexStore.searcher(for: snapshot)
        let key = try SchemaSearchIndexStore.cacheKey(for: snapshot)
        return SchemaToolSession(
            snapshot: snapshot,
            searcher: searcher,
            schemaFingerprint: key.schemaFingerprint,
            selectedSchemas: key.selectedSchemas,
            policy: policy
        )
    }
}

enum SchemaToolExecution: Sendable {
    case success(
        payload: JSONValue,
        truncation: SchemaToolTruncation = SchemaToolTruncation(),
        returnedObjectCount: Int,
        matchedColumnIDsByTable: [String: Set<SchemaObjectID>] = [:]
    )
    case failure(SchemaToolError)

    var returnedObjectCount: Int {
        if case .success(_, _, let count, _) = self { count } else { 0 }
    }

    var matchedColumnIDsByTable: [String: Set<SchemaObjectID>] {
        if case .success(_, _, _, let matches) = self { matches } else { [:] }
    }
}

private struct SchemaToolCachedExecution: Sendable {
    var execution: SchemaToolExecution
}

private struct SchemaToolInvocationCacheKey: Hashable, Sendable {
    var toolName: String
    var argumentsData: Data

    init(invocation: SchemaToolInvocation) {
        self.toolName = invocation.toolName
        self.argumentsData = (try? invocation.arguments.encodedData()) ?? Data()
    }
}

struct SchemaToolHandleRegistry: Sendable {
    var handlesByStableID: [String: String] = [:]
    var objectIDsByHandle: [String: SchemaObjectID] = [:]
    var tablesByStableID: [String: TableInfo] = [:]
    var columnsByStableID: [String: ColumnInfo] = [:]
    var relationshipsByStableID: [String: SchemaForeignKeyConstraintInfo] = [:]

    init(
        snapshot: SchemaSearchSnapshot,
        schemaFingerprint: String,
        selectedSchemas: [String]
    ) {
        let namespace = [
            snapshot.connectionID.uuidString.lowercased(),
            schemaFingerprint,
            selectedSchemas.joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")
        var usedHandles = Set<String>()
        for table in snapshot.schemaSearchTables.sorted(by: Self.tableSort) {
            let tableID = SchemaObjectID.table(schema: table.schema, name: table.name)
            register(tableID, prefix: "tbl", namespace: namespace, usedHandles: &usedHandles)
            tablesByStableID[tableID.stableString] = table
            for column in table.columns.sorted(by: { $0.ordinalPosition < $1.ordinalPosition }) {
                let columnID = SchemaObjectID.column(
                    schema: column.tableSchema,
                    table: column.tableName,
                    name: column.name
                )
                register(columnID, prefix: "col", namespace: namespace, usedHandles: &usedHandles)
                columnsByStableID[columnID.stableString] = column
            }
        }
        for relationship in snapshot.schemaSearchRelationships {
            let relationshipID = SchemaObjectID.foreignKeyConstraint(
                schema: relationship.sourceSchema,
                table: relationship.sourceTable,
                name: relationship.constraintName
            )
            register(relationshipID, prefix: "fk", namespace: namespace, usedHandles: &usedHandles)
            relationshipsByStableID[relationshipID.stableString] = relationship
        }
    }

    func handle(for objectID: SchemaObjectID) -> String? {
        handlesByStableID[objectID.stableString]
    }

    func resolve(_ handle: String, expectedKind: SchemaObjectKind) throws -> SchemaObjectID {
        guard isPlausibleHandle(handle) else {
            throw SchemaToolError(
                code: .invalidObjectID,
                message: "Object handle is malformed.",
                argument: "object_id"
            )
        }
        guard let objectID = objectIDsByHandle[handle] else {
            throw SchemaToolError(
                code: .staleObjectID,
                message: "Object handle is not valid for this schema snapshot.",
                argument: "object_id"
            )
        }
        guard objectID.kind == expectedKind else {
            throw SchemaToolError(
                code: .wrongObjectKind,
                message: "Object handle has the wrong kind.",
                argument: "object_id"
            )
        }
        switch expectedKind {
        case .table:
            guard tablesByStableID[objectID.stableString] != nil else {
                throw SchemaToolError(
                    code: .objectOutsideSnapshot,
                    message: "Table handle is outside the current schema snapshot.",
                    argument: "object_id"
                )
            }
        case .column:
            guard columnsByStableID[objectID.stableString] != nil else {
                throw SchemaToolError(
                    code: .objectOutsideSnapshot,
                    message: "Column handle is outside the current schema snapshot.",
                    argument: "object_id"
                )
            }
        case .foreignKeyConstraint:
            guard relationshipsByStableID[objectID.stableString] != nil else {
                throw SchemaToolError(
                    code: .objectOutsideSnapshot,
                    message: "Foreign-key handle is outside the current schema snapshot.",
                    argument: "object_id"
                )
            }
        case .schema, .keyConstraint:
            break
        }
        return objectID
    }

    private mutating func register(
        _ objectID: SchemaObjectID,
        prefix: String,
        namespace: String,
        usedHandles: inout Set<String>
    ) {
        let stable = objectID.stableString
        let digestInput = "\(namespace)\u{1e}\(stable)"
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var length = 12
        var handle = "\(prefix)_\(String(digest.prefix(length)))"
        while usedHandles.contains(handle), length < digest.count {
            length += 4
            handle = "\(prefix)_\(String(digest.prefix(length)))"
        }
        precondition(usedHandles.insert(handle).inserted, "Schema tool handle collision")
        handlesByStableID[stable] = handle
        objectIDsByHandle[handle] = objectID
    }

    private func isPlausibleHandle(_ handle: String) -> Bool {
        let parts = handle.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2,
            ["tbl", "col", "fk"].contains(parts[0]),
            parts[1].count >= 12
        else {
            return false
        }
        return parts[1].allSatisfy { character in
            character.isNumber || ("a"..."f").contains(String(character))
        }
    }

    private static func tableSort(_ lhs: TableInfo, _ rhs: TableInfo) -> Bool {
        if lhs.schema == rhs.schema {
            return lhs.name < rhs.name
        }
        return lhs.schema < rhs.schema
    }
}

private func validateKeys(
    _ arguments: [String: JSONValue],
    allowed: Set<String>
) -> SchemaToolError? {
    for key in arguments.keys.sorted() where !allowed.contains(key) {
        return .init(
            code: .malformedArguments,
            message: "Unknown argument '\(key)'.",
            argument: key
        )
    }
    return nil
}

private func missingOrTyped(
    _ arguments: [String: JSONValue],
    key: String,
    expected: String
) -> SchemaToolError {
    if arguments[key] == nil {
        return .init(
            code: .missingArgument,
            message: "Missing required argument '\(key)'.",
            argument: key
        )
    }
    return .typed("\(key) must be a \(expected).", argument: key)
}

private func requiredInt(
    _ arguments: [String: JSONValue],
    key: String,
    range: ClosedRange<Int>
) throws -> Int {
    guard let value = arguments[key] else {
        throw SchemaToolError(
            code: .missingArgument,
            message: "Missing required argument '\(key)'.",
            argument: key
        )
    }
    guard let intValue = value.intValue else {
        throw SchemaToolError.typed("\(key) must be an integer.", argument: key)
    }
    guard range.contains(intValue) else {
        throw SchemaToolError.range("\(key) must be in \(range.lowerBound)...\(range.upperBound).", argument: key)
    }
    return intValue
}

private func resolveTableID(
    _ arguments: [String: JSONValue],
    key: String,
    handles: SchemaToolHandleRegistry
) throws -> SchemaObjectID {
    guard let value = arguments[key] else {
        throw SchemaToolError(code: .missingArgument, message: "Missing required argument '\(key)'.", argument: key)
    }
    guard let handle = value.stringValue else {
        throw SchemaToolError.typed("\(key) must be a string.", argument: key)
    }
    do {
        return try handles.resolve(handle, expectedKind: .table)
    } catch var error as SchemaToolError {
        error.argument = key
        throw error
    }
}

private func resolveColumnID(
    _ arguments: [String: JSONValue],
    key: String,
    handles: SchemaToolHandleRegistry
) throws -> SchemaObjectID {
    guard let value = arguments[key] else {
        throw SchemaToolError(code: .missingArgument, message: "Missing required argument '\(key)'.", argument: key)
    }
    guard let handle = value.stringValue else {
        throw SchemaToolError.typed("\(key) must be a string.", argument: key)
    }
    do {
        return try handles.resolve(handle, expectedKind: .column)
    } catch var error as SchemaToolError {
        error.argument = key
        throw error
    }
}

private func compactColumns(
    _ columnIDs: [SchemaObjectID],
    handles: SchemaToolHandleRegistry,
    table: TableInfo,
    limit: Int
) -> [JSONValue] {
    var seen = Set<String>()
    return columnIDs.compactMap { columnID -> JSONValue? in
        guard seen.insert(columnID.stableString).inserted,
            let handle = handles.handle(for: columnID),
            let columnName = columnID.column,
            table.columns.contains(where: { $0.name == columnName })
        else {
            return nil
        }
        return [
            "column_id": .string(handle),
            "sql_name": .string(quotedName(columnID)),
        ]
    }
    .prefix(limit)
    .map { $0 }
}

private func relevantColumns(
    for table: TableInfo,
    matched: [SchemaObjectID],
    relationships: [SchemaForeignKeyConstraintInfo],
    query: String
) -> [SchemaObjectID] {
    var columns = matched
    let canonicalQuery = query.lowercased()
    let temporalRequested = ["last", "week", "month", "year", "day", "recent", "today", "yesterday"]
        .contains { canonicalQuery.contains($0) }
    let relationshipColumns = relationships.filter {
        ($0.sourceSchema == table.schema && $0.sourceTable == table.name)
            || ($0.targetSchema == table.schema && $0.targetTable == table.name)
    }
    .flatMap { relationship in
        relationship.columnPairs.flatMap { pair in
            [
                SchemaObjectID.column(
                    schema: relationship.sourceSchema,
                    table: relationship.sourceTable,
                    name: pair.sourceColumn
                ),
                SchemaObjectID.column(
                    schema: relationship.targetSchema,
                    table: relationship.targetTable,
                    name: pair.targetColumn
                ),
            ]
        }
    }
    .filter { $0.schema == table.schema && $0.table == table.name }
    columns.append(contentsOf: relationshipColumns)
    for column in table.columns where column.valueConstraints?.isEmpty == false {
        columns.append(.column(schema: table.schema, table: table.name, name: column.name))
    }
    if temporalRequested {
        for column in table.columns where isTemporal(column) {
            columns.append(.column(schema: table.schema, table: table.name, name: column.name))
        }
    }
    for column in table.columns where isNameLike(column) {
        columns.append(.column(schema: table.schema, table: table.name, name: column.name))
    }
    var seen = Set<String>()
    return columns.filter { seen.insert($0.stableString).inserted }
}

private func tableCards(
    tableIDs: [SchemaObjectID],
    snapshot: SchemaSearchSnapshot,
    handles: SchemaToolHandleRegistry,
    focusByTable: [String: [SchemaObjectID]],
    matchedColumnsByTable: [String: Set<SchemaObjectID>],
    maxColumnsPerTable: Int,
    maxRelationshipsPerTable: Int,
    truncated: inout Bool
) -> [JSONValue] {
    tableIDs.compactMap { tableID in
        guard let table = handles.tablesByStableID[tableID.stableString],
            let tableHandle = handles.handle(for: tableID)
        else { return nil }
        let relationships = snapshot.schemaSearchRelationships.filter {
            ($0.sourceSchema == table.schema && $0.sourceTable == table.name)
                || ($0.targetSchema == table.schema && $0.targetTable == table.name)
        }
        let keptRelationships = Array(relationships.prefix(maxRelationshipsPerTable))
        if keptRelationships.count < relationships.count {
            truncated = true
        }
        let requiredRelationshipColumnNames = Set(
            keptRelationships.flatMap { relationship in
                relationship.columnPairs.compactMap { pair -> String? in
                    if relationship.sourceSchema == table.schema && relationship.sourceTable == table.name {
                        return pair.sourceColumn
                    }
                    if relationship.targetSchema == table.schema && relationship.targetTable == table.name {
                        return pair.targetColumn
                    }
                    return nil
                }
            }
        )
        let focusColumnNames = Set(
            (focusByTable[tableID.stableString] ?? []).compactMap(\.column)
        )
        let priority = columnPriority(
            table: table,
            focus: Set(focusByTable[tableID.stableString] ?? []),
            matched: matchedColumnsByTable[tableID.stableString] ?? [],
            relationshipColumnNames: requiredRelationshipColumnNames
        )
        var keptColumns = Array(priority.prefix(maxColumnsPerTable))
        let requiredColumnNames = focusColumnNames.union(requiredRelationshipColumnNames)
        var keptNames = Set(keptColumns.map(\.name))
        let missingRequiredColumns = table.columns
            .filter { requiredColumnNames.contains($0.name) && !keptNames.contains($0.name) }
            .sorted { lhs, rhs in
                if lhs.ordinalPosition == rhs.ordinalPosition {
                    return lhs.name < rhs.name
                }
                return lhs.ordinalPosition < rhs.ordinalPosition
            }
        if !missingRequiredColumns.isEmpty {
            truncated = true
            keptColumns.append(contentsOf: missingRequiredColumns)
            keptNames.formUnion(missingRequiredColumns.map(\.name))
        }
        if keptColumns.count < table.columns.count {
            truncated = true
        }
        let omittedColumnCount = max(0, table.columns.count - keptColumns.count)
        let omittedRelationshipCount = max(0, relationships.count - keptRelationships.count)
        var object: [String: JSONValue] = [
            "table_id": .string(tableHandle),
            "sql_name": .string(quotedTableName(table.schema, table.name)),
            "table_type": .string(table.type.rawValue),
            "columns": .array(keptColumns.map { columnJSON($0, handles: handles) }),
            "primary_keys": .array(keyJSON(table.keyConstraints.filter { $0.kind == .primaryKey })),
            "unique_keys": .array(keyJSON(table.keyConstraints.filter { $0.kind == .unique })),
            "foreign_keys": .array(keptRelationships.map { foreignKeyJSON($0) }),
            "omitted_column_count": .number(Double(omittedColumnCount)),
            "omitted_relationship_count": .number(Double(omittedRelationshipCount)),
            "truncated": .bool(omittedColumnCount > 0 || omittedRelationshipCount > 0),
        ]
        if let comment = table.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
            !comment.isEmpty
        {
            object["database_comment"] = .string(sanitizedMetadata(comment, maxCharacters: 240))
        }
        if omittedColumnCount > 0 || omittedRelationshipCount > 0 {
            object["next_tool_suggestion"] = .string(
                "Call describe_tables again with this table_id and focus_column_ids for omitted columns."
            )
        }
        return .object(object)
    }
}

private func columnPriority(
    table: TableInfo,
    focus: Set<SchemaObjectID>,
    matched: Set<SchemaObjectID>,
    relationshipColumnNames: Set<String>
) -> [ColumnInfo] {
    let keyColumns = table.keyConstraints.flatMap(\.columns)
    func score(_ column: ColumnInfo) -> (Int, Int, String) {
        let columnID = SchemaObjectID.column(
            schema: column.tableSchema,
            table: column.tableName,
            name: column.name
        )
        let identifier = column.name
        let rank: Int
        if focus.contains(columnID) {
            rank = 0
        } else if table.keyConstraints.contains(where: { $0.kind == .primaryKey && $0.columns.contains(identifier) }) {
            rank = 1
        } else if table.keyConstraints.contains(where: { $0.kind == .unique && $0.columns.contains(identifier) }) {
            rank = 2
        } else if relationshipColumnNames.contains(identifier) {
            rank = 3
        } else if matched.contains(columnID) {
            rank = 4
        } else if requiresQuoting(identifier) {
            rank = 5
        } else if column.valueConstraints?.isEmpty == false {
            rank = 6
        } else if isTemporal(column) || isNameLike(column) || identifier.lowercased().contains("status") {
            rank = 7
        } else if keyColumns.contains(identifier) {
            rank = 8
        } else {
            rank = 9
        }
        return (rank, column.ordinalPosition, column.name)
    }
    return table.columns.sorted { lhs, rhs in
        let lhsScore = score(lhs)
        let rhsScore = score(rhs)
        if lhsScore.0 != rhsScore.0 {
            return lhsScore.0 < rhsScore.0
        }
        if lhsScore.1 != rhsScore.1 {
            return lhsScore.1 < rhsScore.1
        }
        return lhsScore.2 < rhsScore.2
    }
}

private func columnJSON(_ column: ColumnInfo, handles: SchemaToolHandleRegistry) -> JSONValue {
    let columnID = SchemaObjectID.column(
        schema: column.tableSchema,
        table: column.tableName,
        name: column.name
    )
    var object: [String: JSONValue] = [
        "column_id": .string(handles.handle(for: columnID) ?? ""),
        "sql_name": .string(quotedColumnName(column)),
        "name": .string(quotedIdentifier(column.name)),
        "data_type": .string(sanitizedMetadata(column.dataType, maxCharacters: 120)),
        "nullable": .bool(column.isNullable),
    ]
    if let comment = column.comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        object["database_comment"] = .string(sanitizedMetadata(comment, maxCharacters: 160))
    }
    if column.valueConstraints?.isEmpty == false {
        object["has_schema_values"] = true
    }
    return .object(object)
}

private func keyJSON(_ keys: [SchemaKeyConstraintInfo]) -> [JSONValue] {
    keys.sorted { lhs, rhs in
        lhs.constraintName < rhs.constraintName
    }
    .map { key in
        [
            "constraint_name": .string(sanitizedMetadata(key.constraintName, maxCharacters: 160)),
            "columns": .array(key.columns.map { .string(quotedIdentifier($0)) }),
        ]
    }
}

private func foreignKeyJSON(_ relationship: SchemaForeignKeyConstraintInfo) -> JSONValue {
    [
        "constraint_name": .string(sanitizedMetadata(relationship.constraintName, maxCharacters: 160)),
        "source_table": .string(quotedTableName(relationship.sourceSchema, relationship.sourceTable)),
        "target_table": .string(quotedTableName(relationship.targetSchema, relationship.targetTable)),
        "column_pairs": .array(relationship.columnPairs.map { pair in
            [
                "source_column": .string(quotedIdentifier(pair.sourceColumn)),
                "target_column": .string(quotedIdentifier(pair.targetColumn)),
                "ordinal_position": .number(Double(pair.ordinalPosition)),
            ]
        }),
    ]
}

private func matchReasons(_ fields: [SchemaSearchMatchedField]) -> [String] {
    var reasons: [String] = []
    for field in fields.map(\.field) {
        let reason: String
        switch field {
        case .exactTableQualified, .exactTableUnqualified:
            reason = "exact_identifier"
        case .columnName, .keyColumn:
            reason = "column_name"
        case .tableComment:
            reason = "table_comment"
        case .columnComment:
            reason = "column_comment"
        case .valueConstraint:
            reason = "schema_value"
        case .constraintName:
            reason = "constraint_name"
        case .connectedTableName, .connectedColumnPair, .foreignKeyNeighbor:
            reason = "relationship"
        case .dataType:
            reason = "data_type"
        case .schemaName:
            reason = "schema_name"
        }
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }
    return Array(reasons.prefix(8))
}

private func quotedName(_ objectID: SchemaObjectID) -> String {
    switch objectID.kind {
    case .schema:
        quotedIdentifier(objectID.schema)
    case .table:
        quotedTableName(objectID.schema, objectID.table ?? "")
    case .column:
        [objectID.schema, objectID.table, objectID.column]
            .compactMap { $0 }
            .map(quotedIdentifier)
            .joined(separator: ".")
    case .keyConstraint, .foreignKeyConstraint:
        [objectID.schema, objectID.table, objectID.constraintName]
            .compactMap { $0 }
            .map(quotedIdentifier)
            .joined(separator: ".")
    }
}

private func quotedColumnName(_ column: ColumnInfo) -> String {
    [
        quotedIdentifier(column.tableSchema),
        quotedIdentifier(column.tableName),
        quotedIdentifier(column.name),
    ]
    .joined(separator: ".")
}

private func quotedTableName(_ schema: String, _ table: String) -> String {
    "\(quotedIdentifier(schema)).\(quotedIdentifier(table))"
}

private func quotedIdentifier(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func requiresQuoting(_ identifier: String) -> Bool {
    guard let first = identifier.first,
        first.isLowercase || first == "_"
    else {
        return true
    }
    return !identifier.allSatisfy { character in
        character.isLowercase || character.isNumber || character == "_"
    }
}

private func isTemporal(_ column: ColumnInfo) -> Bool {
    let name = column.name.lowercased()
    let type = column.dataType.lowercased()
    return type.contains("date")
        || type.contains("time")
        || name.hasSuffix("_at")
        || name.contains("date")
        || name.contains("time")
        || name.contains("created")
        || name.contains("scheduled")
}

private func isNameLike(_ column: ColumnInfo) -> Bool {
    let name = column.name.lowercased()
    return ["name", "slug", "label", "title"].contains(name)
        || name.hasSuffix("_name")
        || name.hasSuffix("_slug")
        || name.hasSuffix("_label")
}

func sanitizedMetadata(_ text: String, maxCharacters: Int) -> String {
    var result = ""
    var previousWasWhitespace = false
    for scalar in text.unicodeScalars {
        guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
        let character = Character(scalar)
        if character.isWhitespace {
            if !previousWasWhitespace {
                result.append(" ")
                previousWasWhitespace = true
            }
        } else {
            result.append(character)
            previousWasWhitespace = false
        }
        if result.count >= maxCharacters {
            break
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension SchemaToolError {
    static func malformed(_ message: String, argument: String? = nil) -> SchemaToolError {
        SchemaToolError(code: .malformedArguments, message: message, argument: argument)
    }

    static func typed(_ message: String, argument: String? = nil) -> SchemaToolError {
        SchemaToolError(code: .invalidArgumentType, message: message, argument: argument)
    }

    static func range(_ message: String, argument: String? = nil) -> SchemaToolError {
        SchemaToolError(code: .argumentOutOfRange, message: message, argument: argument)
    }

    static func stale(_ message: String, argument: String? = nil) -> SchemaToolError {
        SchemaToolError(code: .staleObjectID, message: message, argument: argument)
    }

    static func objectKind(_ message: String, argument: String? = nil) -> SchemaToolError {
        SchemaToolError(code: .wrongObjectKind, message: message, argument: argument)
    }

    static func internalFailure(_ message: String) -> SchemaToolError {
        SchemaToolError(code: .internalFailure, message: message)
    }
}
