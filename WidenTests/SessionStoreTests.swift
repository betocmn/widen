import Foundation
import Testing

@testable import WidenKit

@Suite("SessionStore")
struct SessionStoreTests {
    private func makeTempStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        return (SessionStore(directory: dir), dir)
    }

    private func makeGeneration() -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "SELECT id FROM users LIMIT 10",
            explanation: "Lists user ids.",
            assumptions: ["Assumes id is the primary key."],
            referencedTables: ["public.users"],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
    }

    @Test func loadFromEmptyDirectoryReturnsNoSessions() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load().isEmpty)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let connectionID = UUID()
        var session = QuerySession(connectionID: connectionID)
        session.title = "Top spenders"
        session.titleWasManuallySet = true
        session.messages = [
            ChatMessage(role: .user, text: "Which users have spent the most?"),
            ChatMessage(
                role: .assistant, text: "Lists user ids.", generation: makeGeneration()),
        ]
        session.sqlText = "SELECT id FROM users LIMIT 10"
        session.lastGeneration = makeGeneration()
        session.viewDataTarget = QuerySession.ViewDataTarget(schema: "public", table: "users")
        session.isArchived = true
        session.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        session.updatedAt = Date(timeIntervalSince1970: 1_750_000_100)

        try store.save([session])
        let loaded = try store.load()

        #expect(loaded.count == 1)
        let restored = try #require(loaded.first)
        #expect(restored.id == session.id)
        #expect(restored.connectionID == connectionID)
        #expect(restored.title == "Top spenders")
        #expect(restored.titleWasManuallySet)
        #expect(restored.messages.count == 2)
        #expect(restored.messages[0].role == .user)
        #expect(restored.messages[1].generation == makeGeneration())
        #expect(restored.sqlText == "SELECT id FROM users LIMIT 10")
        #expect(restored.lastGeneration == makeGeneration())
        #expect(restored.viewDataTarget == QuerySession.ViewDataTarget(schema: "public", table: "users"))
        #expect(restored.isArchived)
        #expect(restored.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(restored.updatedAt == Date(timeIntervalSince1970: 1_750_000_100))
    }

    @Test func legacySessionWithoutViewDataTargetDecodes() throws {
        let legacy = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "connectionID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "title": "New Session",
              "titleWasManuallySet": false,
              "messages": [],
              "sqlText": "",
              "isArchived": false,
              "createdAt": "2025-06-15T12:00:00Z",
              "updatedAt": "2025-06-15T12:00:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(QuerySession.self, from: Data(legacy.utf8))

        #expect(decoded.viewDataTarget == nil)
    }

    @Test func saveOverwritesPreviousContents() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([QuerySession(connectionID: UUID()), QuerySession(connectionID: UUID())])
        let survivor = QuerySession(connectionID: UUID(), title: "Only one")
        try store.save([survivor])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Only one")
    }

    @Test func corruptedFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test func unreadableFileIsCopiedAsideBeforeLoadThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data("not json".utf8)
        try original.write(to: store.fileURL)
        let start = Date()

        let error = try #require(throws: SessionStore.UnreadableFileError.self) {
            try store.load()
        }

        let backup = error.backupURL
        let name = backup.lastPathComponent
        #expect(backup.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: store.fileURL) == original)
        #expect(error.localizedDescription.contains(name))

        let prefix = "sessions.unreadable-"
        let suffix = ".json"
        #expect(name.hasPrefix(prefix))
        #expect(name.hasSuffix(suffix))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let stampDate = try #require(formatter.date(from: stamp))
        #expect(abs(stampDate.timeIntervalSince(start)) < 60)
    }

    @Test func fileFromANewerFormatIsCopiedAsideBeforeLoadThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON, but a required field holds a value this build lacks.
        let original = Data(
            SavedCloudSessionsFixture.json
                .replacingOccurrences(of: #""riskLevel": "low""#, with: #""riskLevel": "severe""#)
                .utf8
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try original.write(to: store.fileURL)

        let error = try #require(throws: SessionStore.UnreadableFileError.self) {
            try store.load()
        }

        #expect(try Data(contentsOf: error.backupURL) == original)
    }

    @Test func readableFileLeavesNoBackup() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save([QuerySession(connectionID: UUID())])

        _ = try store.load()

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sessions.json"])
    }

    // MARK: - Saved cloud generations

    private func writeSessionsFile(_ json: String, for store: SessionStore) throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: store.fileURL)
    }

    /// Every key path in a JSON document, with array elements folded into
    /// `[]`, so a renamed or dropped key shows up by name in a failure.
    private func jsonKeyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: []) { paths, entry in
                let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                paths.insert(path)
                paths.formUnion(jsonKeyPaths(entry.value, prefix: path))
            }
        case let array as [Any]:
            return array.reduce(into: []) { paths, element in
                paths.formUnion(jsonKeyPaths(element, prefix: "\(prefix)[]"))
            }
        default:
            return []
        }
    }

    @Test func savedCloudGenerationsDecode() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSessionsFile(SavedCloudSessionsFixture.json, for: store)

        let session = try #require(try store.load().first)

        #expect(session.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        let oneShot = try #require(session.messages[1].generation?.backendMetadata)
        #expect(oneShot.structuredOutputMode == .strictJSONSchema)
        #expect(oneShot.requestedModelID == "openai/gpt-5.5")
        #expect(oneShot.agentDiagnostics == nil)

        let generation = try #require(session.lastGeneration)
        #expect(session.messages[3].generation == generation)
        #expect(generation.riskLevel == .medium)
        let metadata = try #require(generation.backendMetadata)
        #expect(metadata.structuredOutputMode == .promptOnlyJSON)
        #expect(metadata.agentTerminalOutcome == "sql")
        #expect(metadata.agentSchemaToolCallCount == 2)
        #expect(metadata.agentInspectionToolCallCount == 2)
        let diagnostics = try #require(metadata.agentDiagnostics)
        #expect(diagnostics.appSideRejectionReason == .uninspectedObject)
        #expect(diagnostics.schemaEvidence.describedTableIDs == ["public.orders", "public.users"])
        #expect(diagnostics.planConsistencyCorrectionSucceeded)

        #expect(generation.schemaToolCalls.map(\.outcome) == [.success, .error])
        #expect(generation.schemaToolCalls.map(\.errorCode) == [nil, .staleObjectID])
        #expect(generation.inspectionToolCalls.map(\.outcome) == [.success, .error])
        #expect(generation.inspectionToolCalls.map(\.errorCode) == [nil, .policyDenied])
    }

    @Test func savedCloudGenerationsSurviveSaveUnchanged() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSessionsFile(SavedCloudSessionsFixture.json, for: store)

        let loaded = try store.load()
        try store.save(loaded)
        #expect(try store.load() == loaded)

        let fixture = try #require(
            JSONSerialization.jsonObject(with: Data(SavedCloudSessionsFixture.json.utf8)) as? NSArray
        )
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? NSArray
        )
        // Frozen key set. A renamed or dropped key loses data that older
        // builds wrote; a new field must be optional (omitted while nil) or
        // be added to the fixture on purpose.
        let fixtureKeys = jsonKeyPaths(fixture)
        let savedKeys = jsonKeyPaths(saved)
        #expect(fixtureKeys.subtracting(savedKeys).sorted() == [])
        #expect(savedKeys.subtracting(fixtureKeys).sorted() == [])
        #expect(saved == fixture)
    }

    /// Loads the fixture after one textual edit, standing in for a file
    /// written by a newer build.
    private func loadFixture(replacing original: String, with replacement: String) throws -> QuerySession {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = SavedCloudSessionsFixture.json
        #expect(json.contains(original))
        try writeSessionsFile(json.replacingOccurrences(of: original, with: replacement), for: store)
        return try #require(try store.load().first)
    }

    @Test func unknownStructuredOutputModeDropsOnlyBackendMetadata() throws {
        let session = try loadFixture(
            replacing: #""structuredOutputMode": "promptOnlyJSON""#,
            with: #""structuredOutputMode": "jsonObject""#
        )

        let generation = try #require(session.lastGeneration)
        #expect(generation.backendMetadata == nil)
        #expect(generation.explanation == "Top ten users by paid order revenue.")
        #expect(generation.schemaToolCalls.count == 2)
        #expect(generation.inspectionToolCalls.count == 2)
        #expect(session.messages[3].generation == generation)
        #expect(session.messages[1].generation?.backendMetadata?.structuredOutputMode == .strictJSONSchema)
    }

    @Test func unknownAppSideRejectionReasonDropsOnlyBackendMetadata() throws {
        let session = try loadFixture(
            replacing: #""appSideRejectionReason": "uninspectedObject""#,
            with: #""appSideRejectionReason": "criticRejected""#
        )

        let generation = try #require(session.lastGeneration)
        #expect(generation.backendMetadata == nil)
        #expect(generation.schemaToolCalls.count == 2)
        #expect(generation.inspectionToolCalls.count == 2)
    }

    @Test func unknownSchemaToolErrorCodeDropsOnlySchemaToolTraces() throws {
        let session = try loadFixture(
            replacing: #""errorCode": "staleObjectID""#,
            with: #""errorCode": "budgetRejected""#
        )

        let generation = try #require(session.lastGeneration)
        #expect(generation.schemaToolCalls.isEmpty)
        #expect(generation.inspectionToolCalls.map(\.errorCode) == [nil, .policyDenied])
        #expect(generation.backendMetadata?.agentDiagnostics?.appSideRejectionReason == .uninspectedObject)
    }

    @Test func unknownInspectionErrorCodeDropsOnlyInspectionTraces() throws {
        let session = try loadFixture(
            replacing: #""errorCode": "policyDenied""#,
            with: #""errorCode": "retentionDenied""#
        )

        let generation = try #require(session.lastGeneration)
        #expect(generation.inspectionToolCalls.isEmpty)
        #expect(generation.schemaToolCalls.map(\.errorCode) == [nil, .staleObjectID])
        #expect(generation.backendMetadata?.structuredOutputMode == .promptOnlyJSON)
    }

    @Test func savedGenerationWithoutInvocationCountSpendsOneInvocation() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSessionsFile(SavedCloudSessionsFixture.json, for: store)

        let generation = try #require(try store.load().first?.lastGeneration)

        // Older builds wrote an HTTP-inclusive call count and no invocation
        // count; repair budgets read that as one invocation.
        #expect(generation.generationCallCount == 2)
        #expect(generation.generatorInvocationCount == nil)
        #expect(TextToSQLRepairPolicy.spentInvocations(after: generation) == 1)
    }

    @Test func unreadableInvocationCountReadsAsLegacy() throws {
        let session = try loadFixture(
            replacing: #""generationCallCount": 2,"#,
            with: #""generationCallCount": 2, "generatorInvocationCount": "two","#
        )

        let generation = try #require(session.lastGeneration)
        #expect(generation.generatorInvocationCount == nil)
        #expect(generation.generationCallCount == 2)
        #expect(generation.backendMetadata?.structuredOutputMode == .promptOnlyJSON)
    }

    @Test func generatorInvocationCountSurvivesSaveAndLoad() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var generation = makeGeneration()
        generation.generationCallCount = 11
        generation.generatorInvocationCount = 3
        var session = QuerySession(connectionID: UUID())
        session.messages = [
            ChatMessage(role: .assistant, text: generation.explanation, generation: generation),
        ]
        session.lastGeneration = generation

        try store.save([session])
        let restored = try #require(try store.load().first)

        #expect(restored.lastGeneration == generation)
        #expect(restored.lastGeneration?.generatorInvocationCount == 3)
        #expect(restored.messages.first?.generation?.generatorInvocationCount == 3)
        let saved = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(saved.contains("generatorInvocationCount"))
    }

    @Test func persistedEnumRawValuesAreFrozen() {
        // These raw values are stored in sessions.json and in eval results.
        // An older build can't decode a case it doesn't know, so adding,
        // removing, or renaming one loses saved data on rollback.
        #expect(SQLRiskLevel.allCases.map(\.rawValue) == ["low", "medium", "high"])
        #expect(
            StructuredOutputMode.allCases.map(\.rawValue)
                == ["strictJSONSchema", "promptOnlyJSON"]
        )
        #expect(
            SchemaToolAppRejectionReason.allCases.map(\.rawValue) == [
                "uninspectedObject",
                "invalidSQL",
                "intentCoverageRejected",
                "planConsistencyRejected",
                "unsupportedAction",
                "malformedTerminal",
                "budgetExhausted",
                "timedOut",
                "clarificationRejected",
            ]
        )
        #expect(SchemaToolCallOutcome.allCases.map(\.rawValue) == ["success", "error"])
        #expect(
            SchemaToolErrorCode.allCases.map(\.rawValue) == [
                "unknownTool",
                "malformedArguments",
                "missingArgument",
                "invalidArgumentType",
                "argumentOutOfRange",
                "invalidObjectID",
                "staleObjectID",
                "wrongObjectKind",
                "objectOutsideSnapshot",
                "columnTableMismatch",
                "resultBudgetExceeded",
                "sessionBudgetExceeded",
                "cancelled",
                "internalFailure",
            ]
        )
        #expect(
            DatabaseInspectionErrorCode.allCases.map(\.rawValue) == [
                "unknownTool",
                "malformedArguments",
                "missingArgument",
                "invalidArgumentType",
                "argumentOutOfRange",
                "invalidObjectID",
                "staleObjectID",
                "wrongObjectKind",
                "objectOutsideSnapshot",
                "columnTableMismatch",
                "policyDenied",
                "unsafeColumnType",
                "resultBudgetExceeded",
                "sessionBudgetExceeded",
                "timeout",
                "cancelled",
                "databaseError",
                "internalFailure",
            ]
        )
        #expect(
            TextToSQLStage.allCases.map(\.rawValue) == [
                "modelGeneration",
                "postprocessing",
                "canonicalization",
                "safetyValidation",
                "schemaValidation",
                "postgresVerification",
                "postgresVerificationRepair",
                "validationRepair",
                "finalDecision",
            ]
        )
        #expect(
            TextToSQLFailureCategory.allCases.map(\.rawValue) == [
                "backendUnavailable",
                "transport",
                "contextWindow",
                "structuredResponseParsing",
                "modelGeneration",
                "httpBudgetExhausted",
                "safetyValidation",
                "schemaValidation",
                "postgresVerification",
                "repeatedNoProgressRepair",
                "cancellation",
                "emptySQL",
            ]
        )
    }
}

/// A sessions.json as 0.1.x writes it after two cloud generations: a one-shot
/// answer (strict JSON schema) and a schema-agent answer (prompt-only JSON)
/// that sets every agent diagnostics field and both tool traces. Keys and
/// values match what `SessionStore.save` writes, so a round trip reproduces
/// them exactly.
private enum SavedCloudSessionsFixture {
    static let oneShotGeneration = """
        {
          "sql": "SELECT user_id, sum(total) AS spend FROM public.orders GROUP BY user_id ORDER BY spend DESC LIMIT 10",
          "explanation": "Lists users by total order spend.",
          "assumptions": ["Spend is the sum of order totals."],
          "referencedTables": ["public.orders"],
          "confidence": 0.9,
          "riskLevel": "low",
          "needsClarification": false,
          "generationCallCount": 1,
          "backendMetadata": {
            "requestedModelID": "openai/gpt-5.5",
            "returnedModelID": "openai/gpt-5.5-20260115",
            "providerName": "OpenAI",
            "completionID": "gen-oneshot-1",
            "requestID": "req-oneshot-1",
            "structuredOutputMode": "strictJSONSchema",
            "requestCount": 1,
            "retryCount": 0,
            "promptTokens": 1800,
            "completionTokens": 210,
            "reasoningTokens": 64,
            "totalTokens": 2010,
            "costUSD": 0.0042,
            "serviceTier": "default",
            "finishReason": "stop",
            "nativeFinishReason": "stop"
          }
        }
        """

    static let agentGeneration = """
        {
          "sql": "SELECT u.id, sum(o.total) AS revenue FROM public.users u JOIN public.orders o ON o.user_id = u.id WHERE o.status = 'paid' GROUP BY u.id ORDER BY revenue DESC LIMIT 10",
          "explanation": "Top ten users by paid order revenue.",
          "assumptions": ["Revenue counts paid orders only."],
          "referencedTables": ["public.orders", "public.users"],
          "confidence": 0.82,
          "riskLevel": "medium",
          "needsClarification": false,
          "generationSchemaName": "public",
          "generationCallCount": 2,
          "backendMetadata": {
            "requestedModelID": "openai/gpt-5.5",
            "returnedModelID": "openai/gpt-5.5-20260115",
            "providerName": "OpenAI",
            "completionID": "gen-agent-4",
            "requestID": "req-agent-4",
            "structuredOutputMode": "promptOnlyJSON",
            "requestCount": 5,
            "retryCount": 1,
            "promptTokens": 9200,
            "completionTokens": 1300,
            "reasoningTokens": 512,
            "totalTokens": 10500,
            "costUSD": 0.0213,
            "serviceTier": "default",
            "finishReason": "tool_calls",
            "nativeFinishReason": "tool_calls",
            "agentSelectionReason": "tools",
            "agentLogicalTurnCount": 4,
            "agentHTTPAttemptCount": 5,
            "agentSchemaToolCallCount": 2,
            "agentInspectionToolCallCount": 2,
            "agentTerminalOutcome": "sql",
            "agentFinishReasons": ["tool_calls", "tool_calls", "tool_calls", "tool_calls"],
            "agentCompletionIDs": ["gen-agent-1", "gen-agent-2", "gen-agent-3", "gen-agent-4"],
            "agentRequestIDs": ["req-agent-1", "req-agent-2", "req-agent-3", "req-agent-4"],
            "agentReturnedModelIDs": ["openai/gpt-5.5-20260115"],
            "agentProviderNames": ["OpenAI"],
            "agentDiagnostics": {
              "logicalTurnCount": 4,
              "terminalToolSeen": true,
              "terminalAction": "sql",
              "terminalQueryPlan": "Sum paid order totals per user, highest first.",
              "terminalValidationFailureReason": "public.orders.status was not inspected.",
              "triedSchemaToolsAfterTerminal": true,
              "producedProseInsteadOfTools": true,
              "redundantDuplicateToolCallCount": 1,
              "redundantZeroResultSearchCount": 2,
              "redundantJoinPathCallCount": 3,
              "schemaEvidence": {
                "searched": true,
                "describedTableIDs": ["public.orders", "public.users"],
                "exposedColumnIDs": ["public.orders.total", "public.orders.user_id", "public.users.id"],
                "exposedForeignKeyPathIDs": ["public.orders.user_id->public.users.id"],
                "inspectedConstraintToolUsed": true,
                "inspectedValueToolUsed": true
              },
              "appSideRejectionReason": "uninspectedObject",
              "clarificationCorrectionMode": "diagnosticsOnly",
              "intentCoverageMode": "correctAndRetryExperimental",
              "clarificationPolicyDecision": "shouldAnswerWithSQL",
              "clarificationPolicyReason": "The schema defines paid orders.",
              "overClarificationCorrectionAttempted": true,
              "overClarificationCorrectionSucceeded": true,
              "databaseContextFactsUsed": ["Revenue means paid order totals."],
              "evidenceSufficientForSQL": true,
              "unresolvedDecisionKinds": ["metric"],
              "sqlIntentCoverageDecision": "needsCorrection",
              "sqlIntentCoverageReason": "The first draft ignored the paid filter.",
              "sqlIntentCoverageMissingSignals": ["paid status filter"],
              "sqlIntentCoverageMismatchCategory": "missing filter",
              "intentCoverageCorrectionAttempted": true,
              "intentCoverageCorrectionSucceeded": true,
              "planConsistencyMode": "diagnosticsOnly",
              "planConsistencyDecision": "divergent",
              "planConsistencyReason": "The plan grouped by email; the SQL groups by id.",
              "planConsistencyDivergences": ["grouping key"],
              "planConsistencyCorrectionAttempted": true,
              "planConsistencyCorrectionSucceeded": true
            }
          },
          "schemaToolCalls": [
            {
              "callID": "call_search_1",
              "toolName": "search_schema",
              "outcome": "success",
              "latencyMs": 3,
              "returnedObjectCount": 4,
              "outputByteCount": 812,
              "truncated": false,
              "schemaFingerprintPrefix": "3f9a1c2b",
              "cacheHit": false
            },
            {
              "callID": "call_describe_2",
              "toolName": "describe_tables",
              "outcome": "error",
              "latencyMs": 1,
              "returnedObjectCount": 0,
              "outputByteCount": 96,
              "truncated": true,
              "errorCode": "staleObjectID",
              "schemaFingerprintPrefix": "3f9a1c2b",
              "cacheHit": true
            }
          ],
          "inspectionToolCalls": [
            {
              "callID": "call_profile_3",
              "toolName": "inspect_column_profile",
              "outcome": "success",
              "tableID": "public.orders",
              "columnIDs": ["public.orders.status"],
              "rowCount": 1,
              "valueCount": 3,
              "outputByteCount": 240,
              "redactionCount": 1,
              "cloudShareable": true,
              "latencyMs": 18,
              "truncated": false
            },
            {
              "callID": "call_sample_4",
              "toolName": "inspect_sample_rows",
              "outcome": "error",
              "columnIDs": [],
              "rowCount": 0,
              "valueCount": 0,
              "outputByteCount": 88,
              "redactionCount": 0,
              "cloudShareable": false,
              "latencyMs": 0,
              "truncated": true,
              "errorCode": "policyDenied"
            }
          ]
        }
        """

    static let json = """
        [
          {
            "id": "11111111-2222-3333-4444-555555555555",
            "connectionID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "title": "Top Spenders",
            "titleWasManuallySet": false,
            "messages": [
              {
                "id": "00000000-0000-0000-0000-000000000001",
                "role": "user",
                "text": "Which users spent the most?",
                "timestamp": "2025-06-15T12:00:00Z"
              },
              {
                "id": "00000000-0000-0000-0000-000000000002",
                "role": "assistant",
                "text": "Lists users by total order spend.",
                "generation": \(oneShotGeneration),
                "timestamp": "2025-06-15T12:00:05Z"
              },
              {
                "id": "00000000-0000-0000-0000-000000000003",
                "role": "user",
                "text": "Only count paid orders.",
                "timestamp": "2025-06-15T12:01:00Z"
              },
              {
                "id": "00000000-0000-0000-0000-000000000004",
                "role": "assistant",
                "text": "Top ten users by paid order revenue.",
                "generation": \(agentGeneration),
                "timestamp": "2025-06-15T12:01:20Z"
              }
            ],
            "sqlText": "SELECT u.id, sum(o.total) AS revenue FROM public.users u JOIN public.orders o ON o.user_id = u.id WHERE o.status = 'paid' GROUP BY u.id ORDER BY revenue DESC LIMIT 10",
            "lastGeneration": \(agentGeneration),
            "isArchived": false,
            "createdAt": "2025-06-15T12:00:00Z",
            "updatedAt": "2025-06-15T12:01:20Z"
          }
        ]
        """
}

@Suite("ChatMessage codable")
struct ChatMessageCodableTests {
    @Test func roundTripPreservesAllFields() throws {
        var message = ChatMessage(
            role: .assistant,
            text: "Lists user ids.",
            generation: SQLGenerationResult(
                sql: "SELECT 1",
                explanation: "Constant.",
                assumptions: [],
                referencedTables: [],
                confidence: 1.0,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            )
        )
        message.timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ChatMessage.self, from: encoder.encode(message))

        #expect(decoded == message)
    }

    @Test func roleRawValuesAreStable() {
        // Raw values are the on-disk format — changing them breaks old files.
        #expect(ChatMessage.Role.user.rawValue == "user")
        #expect(ChatMessage.Role.assistant.rawValue == "assistant")
        #expect(ChatMessage.Role.error.rawValue == "error")
        #expect(ChatMessage.Role.activity.rawValue == "activity")
        #expect(ChatMessage.Role.result.rawValue == "result")
    }

    @Test func activityMessagesAreExcludedFromPromptContext() {
        let messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .activity, text: "Focused repair started."),
            ChatMessage(role: .assistant, text: "Lists users."),
        ]

        let context = messages.sqlConversationMessages()
        let roles: [SQLConversationMessage.Role] = context.map { $0.role }
        let texts = context.map { $0.text }

        #expect(roles == [.user, .assistant])
        #expect(texts.contains("Focused repair started.") == false)
    }

    @Test func runRecordRoundTripPreservesSummary() throws {
        let summary = ChatMessage.RunSummary(
            rowCount: 42, executionTimeMs: 123, truncated: true,
            sql: "SELECT id FROM users LIMIT 100")
        var message = ChatMessage.runRecord(summary)
        message.timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: encoder.encode(message))

        #expect(decoded == message)
        #expect(decoded.role == .result)
        #expect(decoded.runSummary == summary)
        #expect(decoded.text == "Returned 42 rows in 123 ms (truncated at row limit)")
    }

    @Test func runRecordTextForSingleUntruncatedRow() {
        let message = ChatMessage.runRecord(
            ChatMessage.RunSummary(
                rowCount: 1, executionTimeMs: 7, truncated: false, sql: "SELECT 1"))
        #expect(message.text == "Returned 1 row in 7 ms")
    }

    @Test func runRecordUsesAffectedTextForUpsertUpdates() {
        let message = ChatMessage.runRecord(
            ChatMessage.RunSummary(
                rowCount: 2,
                executionTimeMs: 15,
                truncated: false,
                sql: """
                    INSERT INTO users (id, email) VALUES (1, 'a@example.com')
                    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email
                    """,
                kind: .insert
            ))

        #expect(message.text == "Affected 2 rows in 15 ms")
    }

    @Test func legacyMessageWithoutRunSummaryDecodes() throws {
        // A pre-runSummary message as written by older builds.
        let legacy = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "role": "assistant",
              "text": "Lists user ids.",
              "timestamp": "2025-06-15T12:00:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: Data(legacy.utf8))

        #expect(decoded.role == .assistant)
        #expect(decoded.runSummary == nil)
        #expect(decoded.generation == nil)
    }

    @Test func legacyGenerationWithoutGroundingFieldsDecodes() throws {
        let legacy = """
            {
              "sql": "SELECT 1",
              "explanation": "Constant.",
              "assumptions": [],
              "referencedTables": [],
              "confidence": 1.0,
              "riskLevel": "low",
              "needsClarification": false,
              "clarificationQuestion": null
            }
            """
        let decoded = try JSONDecoder().decode(
            SQLGenerationResult.self,
            from: Data(legacy.utf8)
        )

        #expect(decoded.sql == "SELECT 1")
        #expect(decoded.groundingConcepts.isEmpty)
        #expect(decoded.clarificationOptions.isEmpty)
        #expect(decoded.pendingClarification == nil)
    }
}
