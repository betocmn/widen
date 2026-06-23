import Foundation

/// Generates SQL with a hosted model through OpenRouter's OpenAI-compatible
/// chat-completions API. The cloud counterpart of
/// `FoundationModelsSQLGenerator`: same prompts, same structured fields, but
/// JSON-schema output over HTTPS instead of @Generable on-device.
public final class OpenRouterSQLGenerator: SQLGenerator, Sendable {
    /// Cloud models have large context windows, so the schema budget is
    /// generous compared to the 8k/4k characters the on-device model gets.
    static let schemaCharacterBudget = 60_000

    private let apiKey: String
    private let model: String
    private let transport: any HTTPTransport
    private let endpoint: URL

    public init(
        apiKey: String,
        model: String,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.endpoint = endpoint
    }

    public func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        let instructions =
            SQLPromptBuilder.instructions(defaultRowLimit: config.defaultRowLimit)
            + "\n\n" + Self.jsonInstructions
        let bundle = SQLPromptBuilder.promptBundle(
            question: question,
            schema: schema,
            context: context,
            databaseContext: config.databaseContext,
            maxSchemaCharacters: Self.schemaCharacterBudget
        )
        let prompt = bundle.prompt
        let started = Date()
        do {
            let attempt = try await respond(instructions: instructions, prompt: prompt)
            let callCount = max(1, context.modelCallCount) + max(0, attempt.requestCount - 1)
            var result = attempt.result
            result.generationCallCount = callCount
            await GenerationLog.shared.append(
                prompt: prompt,
                outcome: result.logDescription,
                durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                telemetry: PromptTelemetry(
                    phase: context.mode,
                    package: bundle.schemaPackage,
                    context: context,
                    callCount: callCount,
                    stopReason: result.needsClarification ? "clarification" : "success"
                ))
            return result
        } catch {
            await GenerationLog.shared.append(
                prompt: prompt,
                outcome: "error: \(error)",
                durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                telemetry: PromptTelemetry(
                    phase: context.mode,
                    package: bundle.schemaPackage,
                    context: context,
                    callCount: max(1, context.modelCallCount),
                    stopReason: "error"
                ))
            throw error
        }
    }

    private struct OpenRouterAttempt {
        var result: SQLGenerationResult
        var requestCount: Int
    }

    private func respond(instructions: String, prompt: String) async throws -> OpenRouterAttempt {
        do {
            return OpenRouterAttempt(
                result: try await requestOnce(
                    instructions: instructions,
                    prompt: prompt,
                    includeResponseFormat: true
                ),
                requestCount: 1
            )
        } catch is ResponseFormatUnsupported {
            // Some models reject response_format; the JSON paragraph in the
            // system message carries the schema on its own.
            return OpenRouterAttempt(
                result: try await requestOnce(
                    instructions: instructions, prompt: prompt, includeResponseFormat: false),
                requestCount: 2
            )
        }
    }

    private func requestOnce(
        instructions: String,
        prompt: String,
        includeResponseFormat: Bool
    ) async throws -> SQLGenerationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Widen", forHTTPHeaderField: "X-Title")
        request.httpBody = try Self.requestBody(
            model: model,
            instructions: instructions,
            prompt: prompt,
            includeResponseFormat: includeResponseFormat
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw Self.map(error)
        }

        switch response.statusCode {
        case 200..<300:
            return try Self.result(from: data)
        case 400 where includeResponseFormat && Self.complainsAboutResponseFormat(data):
            throw ResponseFormatUnsupported()
        case 401, 403:
            throw SQLGenerationFailure.backendUnavailable(
                "OpenRouter rejected the API key. Check it in Settings › LLM.")
        case 402:
            throw SQLGenerationFailure.backendUnavailable(
                "Your OpenRouter account is out of credits. Add credits at openrouter.ai and try again."
            )
        case 429:
            throw SQLGenerationFailure.generation(
                "OpenRouter is rate-limiting requests. Try again in a moment.")
        default:
            let detail =
                Self.serverErrorMessage(from: data)
                ?? "OpenRouter returned status \(response.statusCode)."
            if Self.isContextWindowMessage(detail) {
                throw SQLGenerationFailure.contextWindow(detail)
            }
            throw SQLGenerationFailure.generation(detail)
        }
    }

    // MARK: - Request building

    /// JSON-output contract appended to the shared system instructions, so
    /// models without response_format support still answer in shape.
    static let jsonInstructions = """
        Respond with a single JSON object and nothing else, using exactly these keys:
        {"sql": string, "explanation": string, "assumptions": [string], "referencedTables": [string], "confidence": number between 0 and 1, "riskLevel": "low" or "medium" or "high", "needsClarification": boolean, "clarificationQuestion": string or null}
        """

    private static func requestBody(
        model: String,
        instructions: String,
        prompt: String,
        includeResponseFormat: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0,
            "max_tokens": 2_048,
        ]
        if includeResponseFormat {
            body["response_format"] = responseFormat()
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Strict JSON schema mirroring `SQLGenerationResult` / the on-device
    /// `GeneratedSQLResponse` fields.
    private static func responseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "generated_sql",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "sql", "explanation", "assumptions", "referencedTables",
                        "confidence", "riskLevel", "needsClarification", "clarificationQuestion",
                    ],
                    "properties": [
                        "sql": ["type": "string"],
                        "explanation": ["type": "string"],
                        "assumptions": ["type": "array", "items": ["type": "string"]],
                        "referencedTables": ["type": "array", "items": ["type": "string"]],
                        "confidence": ["type": "number"],
                        "riskLevel": ["type": "string", "enum": ["low", "medium", "high"]],
                        "needsClarification": ["type": "boolean"],
                        "clarificationQuestion": ["type": ["string", "null"]],
                    ],
                ],
            ],
        ]
    }

    // MARK: - Response parsing

    private struct ResponseFormatUnsupported: Error {}

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct APIErrorBody: Decodable {
        struct APIError: Decodable {
            let message: String?
        }
        let error: APIError?
    }

    /// The model's answer, tolerant of partially filled objects: only `sql`
    /// is required, everything else gets a conservative default.
    private struct CloudGeneratedSQLResponse: Decodable {
        let sql: String
        let explanation: String?
        let assumptions: [String]?
        let referencedTables: [String]?
        let confidence: Double?
        let riskLevel: String?
        let needsClarification: Bool?
        let clarificationQuestion: String?
    }

    private static func result(from data: Data) throws -> SQLGenerationResult {
        let parseFailure = SQLGenerationFailure.structuredResponseParsing(
            "The cloud model returned an unparseable response. Try again or pick a different model in Settings › LLM."
        )
        guard
            let completion = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = completion.choices.first?.message.content,
            let objectData = extractJSONObject(from: content),
            let generated = try? JSONDecoder().decode(
                CloudGeneratedSQLResponse.self, from: objectData)
        else {
            throw parseFailure
        }
        let needsClarification = generated.needsClarification ?? false
        let sql = generated.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let clarificationQuestion = generated.clarificationQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard needsClarification || !sql.isEmpty else { throw parseFailure }
        guard !needsClarification || clarificationQuestion?.isEmpty == false else {
            throw parseFailure
        }
        return SQLGenerationResult(
            sql: needsClarification ? "" : sql,
            explanation: generated.explanation ?? "",
            assumptions: generated.assumptions ?? [],
            referencedTables: generated.referencedTables ?? [],
            confidence: min(max(generated.confidence ?? 0.5, 0), 1),
            riskLevel: SQLRiskLevel(rawValue: (generated.riskLevel ?? "").lowercased()) ?? .medium,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion
        )
    }

    /// Extracts the JSON object from model output that may be wrapped in
    /// Markdown fences or prose.
    private static func extractJSONObject(from content: String) -> Data? {
        guard
            let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}"),
            start <= end
        else { return nil }
        return Data(content[start...end].utf8)
    }

    private static func complainsAboutResponseFormat(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return body.contains("response_format") || body.contains("json_schema")
            || body.contains("structured output")
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        guard
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: data),
            let message = body.error?.message, !message.isEmpty
        else { return nil }
        return message
    }

    private static func isContextWindowMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("context window")
            || lower.contains("context length")
            || lower.contains("maximum context")
            || lower.contains("context_length")
            || lower.contains("prompt is too long")
            || lower.contains("too many tokens")
            || lower.contains("token limit")
    }

    private static func map(_ error: URLError) -> SQLGenerationFailure {
        switch error.code {
        case .timedOut:
            .transport("The cloud request timed out. Try again.")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed:
            .transport("No internet connection. Check your network and try again.")
        default:
            .transport(error.localizedDescription)
        }
    }
}
