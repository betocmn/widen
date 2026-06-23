import Foundation
import Testing

@testable import WidenKit

@Suite("OpenRouterSQLGenerator")
struct OpenRouterSQLGeneratorTests {
    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Result<(Data, HTTPURLResponse), Error>]
        private var recorded: [URLRequest] = []

        init(_ results: [Result<(Data, HTTPURLResponse), Error>]) {
            self.queue = results
        }

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try lock.withLock {
                recorded.append(request)
                guard !queue.isEmpty else { throw URLError(.badServerResponse) }
                return try queue.removeFirst().get()
            }
        }
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: Self.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// A chat-completions body whose message content is `content`.
    private func completion(content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
    }

    private func makeGenerator(_ transport: StubTransport) -> OpenRouterSQLGenerator {
        OpenRouterSQLGenerator(
            apiKey: "test-key",
            model: "anthropic/claude-sonnet-4.6",
            transport: transport,
            endpoint: Self.endpoint
        )
    }

    private func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1)
                    ])
            ],
            foreignKeys: []
        )
    }

    private let goodContent = """
        {"sql": "SELECT id FROM public.users LIMIT 100", "explanation": "Lists user ids.", \
        "assumptions": ["All users wanted"], "referencedTables": ["public.users"], \
        "confidence": 0.9, "riskLevel": "low", "needsClarification": false, \
        "clarificationQuestion": null}
        """

    @Test func sendsBearerTokenModelAndPrompt() async throws {
        let transport = StubTransport([
            .success((try completion(content: goodContent), response(status: 200)))
        ])
        _ = try await makeGenerator(transport).generateSQL(
            question: "show users",
            schema: makeSchema(),
            config: SQLGenerationConfig(databaseContext: "Only active users count.")
        )

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try JSONSerialization.jsonObject(
            with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "anthropic/claude-sonnet-4.6")
        #expect(body?["response_format"] != nil)
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[0]["content"]?.contains("JSON object") == true)
        #expect(messages?[1]["content"]?.contains("TABLE \"public\".\"users\"") == true)
        #expect(messages?[1]["content"]?.contains("Database context:\nOnly active users count.") == true)
        #expect(messages?[1]["content"]?.contains("User question: show users") == true)
    }

    @Test func decodesStructuredResponse() async throws {
        let transport = StubTransport([
            .success((try completion(content: goodContent), response(status: 200)))
        ])
        let result = try await makeGenerator(transport).generateSQL(
            question: "show users", schema: makeSchema(), config: SQLGenerationConfig())

        #expect(result.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(result.explanation == "Lists user ids.")
        #expect(result.assumptions == ["All users wanted"])
        #expect(result.referencedTables == ["public.users"])
        #expect(result.confidence == 0.9)
        #expect(result.riskLevel == .low)
        #expect(result.needsClarification == false)
        #expect(result.clarificationQuestion == nil)
    }

    @Test func parsesFencedJSONContent() async throws {
        let fenced = "Here is the query:\n```json\n\(goodContent)\n```"
        let transport = StubTransport([
            .success((try completion(content: fenced), response(status: 200)))
        ])
        let result = try await makeGenerator(transport).generateSQL(
            question: "show users", schema: makeSchema(), config: SQLGenerationConfig())
        #expect(result.sql == "SELECT id FROM public.users LIMIT 100")
    }

    @Test func normalizesRiskCaseAndConfidenceRange() async throws {
        let sloppy = """
            {"sql": "  SELECT 1  ", "explanation": "x", "assumptions": [], \
            "referencedTables": [], "confidence": 1.7, "riskLevel": "LOW", \
            "needsClarification": false, "clarificationQuestion": null}
            """
        let transport = StubTransport([
            .success((try completion(content: sloppy), response(status: 200)))
        ])
        let result = try await makeGenerator(transport).generateSQL(
            question: "one", schema: makeSchema(), config: SQLGenerationConfig())
        #expect(result.sql == "SELECT 1")
        #expect(result.confidence == 1)
        #expect(result.riskLevel == .low)
    }

    @Test func decodesClarificationWithEmptySQL() async throws {
        let clarification = """
            {"sql": "", "explanation": "The requested metric is undefined.", \
            "assumptions": [], "referencedTables": [], "confidence": 0.2, \
            "riskLevel": "medium", "needsClarification": true, \
            "clarificationQuestion": "What metric defines best customers?"}
            """
        let transport = StubTransport([
            .success((try completion(content: clarification), response(status: 200)))
        ])
        let result = try await makeGenerator(transport).generateSQL(
            question: "Who are our best customers?",
            schema: makeSchema(),
            config: SQLGenerationConfig()
        )

        #expect(result.sql.isEmpty)
        #expect(result.needsClarification)
        #expect(result.clarificationQuestion == "What metric defines best customers?")
    }

    @Test func rejectedKeyBecomesModelUnavailable() async throws {
        let transport = StubTransport([
            .success((Data("{}".utf8), response(status: 401)))
        ])
        await #expect(throws: AppError.self) {
            _ = try await makeGenerator(transport).generateSQL(
                question: "show users", schema: makeSchema(), config: SQLGenerationConfig())
        }
        do {
            _ = try await makeGenerator(StubTransport([
                .success((Data("{}".utf8), response(status: 401)))
            ])).generateSQL(
                question: "show users", schema: makeSchema(), config: SQLGenerationConfig())
        } catch let error as AppError {
            guard case .modelUnavailable = error else {
                Issue.record("expected modelUnavailable, got \(error)")
                return
            }
        }
    }

    @Test func retriesWithoutResponseFormatWhenRejected() async throws {
        let complaint = Data(
            "{\"error\": {\"message\": \"response_format is not supported by this model\"}}".utf8)
        let transport = StubTransport([
            .success((complaint, response(status: 400))),
            .success((try completion(content: goodContent), response(status: 200))),
        ])
        let result = try await makeGenerator(transport).generateSQL(
            question: "show users", schema: makeSchema(), config: SQLGenerationConfig())

        #expect(result.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(transport.requests.count == 2)
        let retryBody = try JSONSerialization.jsonObject(
            with: #require(transport.requests[1].httpBody)) as? [String: Any]
        #expect(retryBody?["response_format"] == nil)
    }

    @Test func unparseableContentFailsGeneration() async throws {
        let transport = StubTransport([
            .success((try completion(content: "I cannot help with that."), response(status: 200)))
        ])
        do {
            _ = try await makeGenerator(transport).generateSQL(
                question: "show users", schema: makeSchema(), config: SQLGenerationConfig())
            Issue.record("expected an error")
        } catch let error as AppError {
            guard case .modelGenerationFailed = error else {
                Issue.record("expected modelGenerationFailed, got \(error)")
                return
            }
        }
    }

    @Test func serverErrorMessageSurfacesInError() async throws {
        let body = Data("{\"error\": {\"message\": \"model is overloaded\"}}".utf8)
        let transport = StubTransport([
            .success((body, response(status: 500)))
        ])
        do {
            _ = try await makeGenerator(transport).generateSQL(
                question: "show users", schema: makeSchema(), config: SQLGenerationConfig())
            Issue.record("expected an error")
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("model is overloaded") == true)
        }
    }
}
