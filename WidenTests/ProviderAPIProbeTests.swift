import Foundation
import Testing

@testable import WidenKit

@Suite("Provider API probe")
struct ProviderAPIProbeTests {
    private struct Reply: Sendable {
        var status = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    /// Answers each probe step by the shape of its request, so a test can
    /// change one step's reply without scripting the order of the others.
    private struct FakeProvider: Sendable {
        var modelList = Reply(body: ProviderAPIProbeTests.modelList([ProviderAPIProbeTests.particleModel()]))
        var plain = Reply(
            body: ProviderAPIProbeTests.completion(content: "ok"),
            headers: ["X-Request-Id": "req-plain", "X-RateLimit-Remaining": "99"]
        )
        var toolTurn = Reply(
            body: ProviderAPIProbeTests.completion(
                content: nil,
                toolCalls: [ProviderAPIProbeTests.toolCall(id: ProviderAPIProbeTests.firstTurnID)],
                reasoningContent: "Paris first."
            )
        )
        var secondTurn: @Sendable (_ echoesReasoning: Bool, _ sendsName: Bool) -> Reply = { echoes, named in
            Reply(
                body: ProviderAPIProbeTests.completion(
                    content: nil,
                    toolCalls: [
                        ProviderAPIProbeTests.toolCall(
                            id: "call_second\(echoes ? "E" : "e")\(named ? "N" : "n")0123456789abcdef",
                            arguments: #"{"city":"Rome"}"#
                        )
                    ]
                )
            )
        }
        var namedTool = Reply(
            body: ProviderAPIProbeTests.completion(
                content: nil,
                toolCalls: [
                    ProviderAPIProbeTests.toolCall(id: "call_named0123456789abcdefgh", name: "get_time")
                ]
            )
        )
        var jsonObject = Reply(body: ProviderAPIProbeTests.completion(content: #"{"ok":true,"city":"Paris"}"#))

        func reply(to request: URLRequest) throws -> Reply {
            if request.httpMethod == "GET" { return modelList }
            let body = try ProviderAPIProbeTests.jsonBody(request)
            if body["response_format"] != nil { return jsonObject }
            if body["tool_choice"] is [String: Any] { return namedTool }
            let messages = try #require(body["messages"] as? [[String: Any]])
            if let tool = messages.first(where: { $0["role"] as? String == "tool" }) {
                let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
                return secondTurn(assistant["reasoning_content"] != nil, tool["name"] != nil)
            }
            return body["tools"] == nil ? plain : toolTurn
        }

        func transport() -> RecordingTransport {
            RecordingTransport { request, _ in
                let reply = try reply(to: request)
                return (
                    reply.body,
                    RecordingTransport.response(to: request, status: reply.status, headers: reply.headers)
                )
            }
        }
    }

    private static let apiKey = "pai-probeTestKey0123456789"
    private static let firstTurnID = "call_first0123456789abcdefgh"

    // MARK: - Findings

    @Test func probeRecordsEveryFindingFromAcceptedResponses() async throws {
        let transport = FakeProvider().transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(report.passed)
        #expect(report.criticalFailures.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.stoppedReason == nil)
        #expect(report.provider == "particle")
        #expect(report.endpointHost == "particle.test")
        #expect(report.requestedModelID == "particle-1")
        #expect(report.expectedReturnedModelID == ParticleTestSupport.returnedModelID)

        let models = report.modelList
        #expect(models.request.accepted)
        #expect(models.listed)
        #expect(models.listedID == "particle-1")
        #expect(models.contextWindowTokens == 1_048_576)
        #expect(models.maxOutputTokens == 131_072)
        #expect(models.capabilities == ["tool_calling": true, "structured_outputs": false])
        #expect(models.defaultReasoningEffort == "high")
        #expect(models.supportedReasoningEfforts == ["none", "low", "medium", "high"])

        let plain = try #require(report.plainCompletion)
        #expect(plain.request.accepted)
        #expect(plain.request.httpStatus == 200)
        #expect(plain.request.returnedModelID == ParticleTestSupport.returnedModelID)
        #expect(plain.request.reasoningEffort == "none")
        #expect(plain.returnedModelMatches)
        #expect(plain.requestIDHeaderNames == ["x-request-id"])
        #expect(plain.profileRequestIDHeaderPresent)
        #expect(plain.cachedTokensReported)
        #expect(plain.reasoningTokensReported)
        #expect((plain.request.latencyMs ?? -1) >= 0)

        let toolTurn = try #require(report.toolTurn)
        #expect(toolTurn.request.accepted)
        #expect(toolTurn.request.reasoningEffort == "low")
        #expect(toolTurn.reasoningContentPresent)
        #expect(toolTurn.assistantMessageFields == ["content", "reasoning_content", "role", "tool_calls"])
        #expect(
            toolTurn.toolCalls == [
                ProviderAPIProbeReport.ToolCallFinding(
                    name: "get_weather",
                    idShape: ProviderAPIProbeReport.ToolCallIDShape(id: Self.firstTurnID),
                    argumentsAreJSONObject: true
                )
            ]
        )
        let shape = try #require(toolTurn.toolCalls.first?.idShape)
        #expect(shape.prefix == "call_")
        #expect(shape.length == Self.firstTurnID.count)
        #expect(shape.bodyCharacters == "alphanumeric")

        // The profile's own shape is tried first, then the other three.
        #expect(
            report.secondTurnVariants.map { [$0.echoesReasoningContent, $0.sendsToolMessageName] }
                == [[false, false], [false, true], [true, false], [true, true]]
        )
        #expect(report.secondTurnVariants.map(\.matchesProfile) == [true, false, false, false])
        for variant in report.secondTurnVariants {
            #expect(variant.skippedReason == nil)
            #expect(variant.request.accepted)
            #expect(variant.request.httpStatus == 200)
            #expect(variant.reusesToolTurnID == false)
            #expect(variant.toolCalls.count == 1)
        }
        #expect(report.toolCallIDsUniqueAcrossTurns == true)

        let named = try #require(report.namedToolChoice)
        #expect(named.namedTool == "get_time")
        #expect(named.calledTools == ["get_time"])
        #expect(named.honored)

        let jsonObject = try #require(report.jsonObject)
        #expect(jsonObject.validJSONObject)
        #expect(jsonObject.parsedStrictly)
        #expect(jsonObject.invalidContentExcerpt == nil)
        #expect(jsonObject.request.reasoningEffort == "none")

        #expect(transport.requests.count == 1 + ProviderAPIProbe.maximumCompletionCount)
        let paths: [String?] = ["/v1/models"]
            + Array(repeating: "/v1/chat/completions", count: ProviderAPIProbe.maximumCompletionCount)
        #expect(transport.requests.map { $0.url?.path } == paths)
    }

    @Test func everyRequestIsSignedForTheProfileHostWithCappedTokensAndAnExplicitEffort() async throws {
        let profile = CloudModelProfile.particle
        let transport = FakeProvider().transport()

        let report = await ProviderAPIProbe(apiKey: Self.apiKey, transport: transport).run()

        #expect(report.passed)
        #expect(report.endpointHost == "api.particle.ai")
        let requests = transport.requests
        try #require(requests.count == 9)
        let efforts = Set(ReasoningEffort.allCases.map(\.rawValue))
        for request in requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "api.particle.ai")
            #expect(request.url?.host == profile.baseURL.host)
            let headers = request.allHTTPHeaderFields ?? [:]
            #expect(headers["Authorization"] == "Bearer \(Self.apiKey)")
            #expect(!headers.keys.contains { $0.lowercased().hasPrefix("x-") })
        }
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].url == profile.modelsURL)

        let bodies = try requests.dropFirst().map(Self.jsonBody)
        for (request, body) in zip(requests.dropFirst(), bodies) {
            #expect(request.httpMethod == "POST")
            #expect(request.url == profile.chatCompletionsURL)
            #expect(body["model"] as? String == "particle-1")
            #expect(body["stream"] as? Bool == false)
            let maxTokens = try #require(body["max_completion_tokens"] as? Int)
            #expect(maxTokens > 0 && maxTokens <= ProviderAPIProbe.maximumCompletionTokens)
            let effort = try #require(body["reasoning_effort"] as? String)
            #expect(efforts.contains(effort))
            for key in ["max_tokens", "temperature", "provider", "n", "seed", "prompt_cache_key"] {
                #expect(body[key] == nil, "probe request must not send \(key)")
            }
        }
        let expectedEfforts: [String?] = ["none", "low", "low", "low", "low", "low", "low", "none"]
        let expectedTokens: [Int?] = [64, 1_024, 1_024, 1_024, 1_024, 1_024, 1_024, 256]
        #expect(bodies.map { $0["reasoning_effort"] as? String } == expectedEfforts)
        #expect(bodies.map { $0["max_completion_tokens"] as? Int } == expectedTokens)

        // The plain completion and json_object send no tools.
        for body in [bodies[0], bodies[7]] {
            #expect(body["tools"] == nil)
            #expect(body["tool_choice"] == nil)
            #expect(body["parallel_tool_calls"] == nil)
        }
        #expect(bodies[0]["response_format"] == nil)
        #expect((bodies[7]["response_format"] as? [String: Any])?["type"] as? String == "json_object")

        // The tool turn and every second turn require a tool, one at a time.
        for body in bodies[1...5] {
            #expect(body["tool_choice"] as? String == "required")
            #expect(body["parallel_tool_calls"] as? Bool == false)
            #expect(Self.toolNames(in: body) == ["get_weather"])
            #expect(body["response_format"] == nil)
        }

        // Each second turn answers the tool turn's call by its id, and only
        // its variant carries reasoning_content or a tool-message name.
        let expectedShapes = [(false, false), (false, true), (true, false), (true, true)]
        for (body, (echoes, named)) in zip(bodies[2...5], expectedShapes) {
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
            let assistant = messages[2]
            let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
            #expect(calls.map { $0["id"] as? String } == [Self.firstTurnID])
            #expect((assistant["reasoning_content"] as? String) == (echoes ? "Paris first." : nil))
            #expect(assistant["content"] is NSNull)
            let tool = messages[3]
            #expect(tool["tool_call_id"] as? String == Self.firstTurnID)
            #expect((tool["name"] as? String) == (named ? "get_weather" : nil))
        }

        // The named tool_choice forces get_time from two tools.
        let named = bodies[6]
        let toolChoice = try #require(named["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "function")
        #expect((toolChoice["function"] as? [String: Any])?["name"] as? String == "get_time")
        #expect(named["parallel_tool_calls"] as? Bool == false)
        #expect(Self.toolNames(in: named) == ["get_weather", "get_time"])
    }

    @Test func rejectedSecondTurnVariantsAreRecordedWithTheirStatusAndCode() async throws {
        var fake = FakeProvider()
        let accepted = fake.secondTurn
        fake.secondTurn = { echoes, named in
            named ? Self.unsupportedParameterReply : accepted(echoes, named)
        }
        let transport = fake.transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(report.passed)
        #expect(report.warnings.isEmpty)
        for variant in report.secondTurnVariants {
            if variant.sendsToolMessageName {
                #expect(!variant.request.accepted)
                #expect(variant.request.sent)
                #expect(variant.request.httpStatus == 400)
                #expect(variant.request.errorCode == "unsupported_parameter")
                #expect(variant.request.errorType == "invalid_request_error")
                #expect(variant.request.errorCategory == CloudRequestFailure.Category.unsupportedFeature.rawValue)
                #expect(variant.request.errorMessage == "Unsupported parameter: messages[3].name")
                #expect(variant.toolCalls.isEmpty)
                #expect(variant.reusesToolTurnID == nil)
            } else {
                #expect(variant.request.accepted)
                #expect(variant.request.errorCode == nil)
                #expect(variant.request.errorCategory == nil)
            }
        }
        // A 4xx rejection runs no model, so it is neither priced nor unpriced.
        #expect(report.cost.sentCompletionCount == 8)
        #expect(report.cost.pricedCompletionCount == 6)
        #expect(report.cost.unpricedCompletionCount == 0)
        let markdown = report.markdown()
        #expect(markdown.contains("| no | yes | no | no | 400 | unsupported_parameter |"))
        #expect(markdown.contains("| no | no | yes | yes | 200 | - |"))
    }

    @Test func rejectingTheProfilesOwnSecondTurnShapeIsAWarning() async throws {
        var fake = FakeProvider()
        let accepted = fake.secondTurn
        fake.secondTurn = { echoes, named in
            !echoes && !named ? Self.unsupportedParameterReply : accepted(echoes, named)
        }

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        #expect(report.passed)
        #expect(report.secondTurnVariants.first?.matchesProfile == true)
        #expect(report.secondTurnVariants.first?.request.accepted == false)
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.contains("echo reasoning_content: no, tool-message name: no") == true)
    }

    @Test func noAcceptedSecondTurnVariantIsACriticalFailure() async throws {
        var fake = FakeProvider()
        fake.secondTurn = { _, _ in Self.unsupportedParameterReply }

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        #expect(!report.passed)
        #expect(report.criticalFailures == ["No second-turn variant was accepted."])
        #expect(report.secondTurnVariants.count == 4)
        #expect(report.secondTurnVariants.allSatisfy { $0.request.httpStatus == 400 })
        // The later steps still ran.
        #expect(report.namedToolChoice?.honored == true)
        #expect(report.jsonObject?.validJSONObject == true)
    }

    @Test func echoVariantsAreSkippedWithoutReasoningContentAndReusedIDsAreReported() async throws {
        var fake = FakeProvider()
        fake.toolTurn = Reply(
            body: Self.completion(content: nil, toolCalls: [Self.toolCall(id: "call_0")])
        )
        fake.secondTurn = { _, _ in
            Reply(body: Self.completion(content: nil, toolCalls: [Self.toolCall(id: "call_0")]))
        }
        let transport = fake.transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(report.passed)
        let toolTurn = try #require(report.toolTurn)
        #expect(!toolTurn.reasoningContentPresent)
        #expect(toolTurn.toolCalls.first?.idShape?.bodyCharacters == "digits")
        let sent = report.secondTurnVariants.filter { $0.skippedReason == nil }
        let skipped = report.secondTurnVariants.filter { $0.skippedReason != nil }
        #expect(sent.map(\.echoesReasoningContent) == [false, false])
        #expect(skipped.map(\.echoesReasoningContent) == [true, true])
        #expect(skipped.allSatisfy { !$0.request.sent && !$0.request.accepted })
        #expect(skipped.allSatisfy { $0.skippedReason?.contains("reasoning_content") == true })
        #expect(sent.allSatisfy { $0.reusesToolTurnID == true })
        #expect(report.toolCallIDsUniqueAcrossTurns == false)
        // Skipped variants send nothing: 1 list + 1 plain + 1 tool + 2 + 1 named + 1 json.
        #expect(transport.requests.count == 7)
        #expect(report.cost.pricedCompletionCount == 6)
        #expect(report.cost.unpricedCompletionCount == 0)
    }

    @Test func toolTurnWithoutAToolCallSkipsEverySecondTurn() async throws {
        var fake = FakeProvider()
        fake.toolTurn = Reply(body: Self.completion(content: "It is sunny."))

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        #expect(!report.passed)
        #expect(report.secondTurnVariants.count == 4)
        #expect(report.secondTurnVariants.allSatisfy { !$0.request.sent })
        #expect(
            report.criticalFailures
                == ["No second-turn variant was accepted. The tool turn returned no tool call to answer."]
        )
    }

    @Test func namedToolChoiceThatIsNotHonoredIsAWarning() async throws {
        var fake = FakeProvider()
        fake.namedTool = Reply(
            body: Self.completion(content: nil, toolCalls: [Self.toolCall(id: "call_named")])
        )

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        #expect(report.passed)
        #expect(report.namedToolChoice?.honored == false)
        #expect(report.namedToolChoice?.calledTools == ["get_weather"])
        #expect(report.warnings == [
            "Named tool_choice was not honored: the model called get_weather instead of get_time."
        ])
    }

    // MARK: - Critical failures

    @Test func unlistedModelStopsBeforeAnyCompletion() async throws {
        var fake = FakeProvider()
        fake.modelList = Reply(body: Self.modelList([Self.particleModel(id: "particle-0")]))
        let transport = fake.transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(!report.passed)
        #expect(report.modelList.request.accepted)
        #expect(!report.modelList.listed)
        #expect(report.criticalFailures == ["particle-1 is not in the Particle model list for this API key."])
        #expect(report.stoppedReason != nil)
        #expect(report.plainCompletion == nil)
        #expect(report.toolTurn == nil)
        #expect(report.secondTurnVariants.isEmpty)
        #expect(report.jsonObject == nil)
        #expect(report.cost.estimatedCostUSD == 0)
        #expect(transport.requests.map(\.httpMethod) == ["GET"])
    }

    @Test func rejectedModelListStopsBeforeAnyCompletion() async throws {
        var fake = FakeProvider()
        fake.modelList = Reply(
            status: 401,
            body: Self.errorBody(
                code: "invalid_bearer_credential",
                type: "authentication_error",
                message: "Invalid bearer credential."
            )
        )
        let transport = fake.transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(!report.passed)
        #expect(report.modelList.request.errorCategory == CloudRequestFailure.Category.authentication.rawValue)
        #expect(report.criticalFailures == ["The model list request failed (HTTP 401, invalid_bearer_credential)."])
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [
        ("particle-ai/particle-2", 200, "The plain completion came from particle-ai/particle-2, not particle-ai/particle-1."),
        (nil, 200, "The plain completion came from an unnamed model, not particle-ai/particle-1."),
        (ParticleTestSupport.returnedModelID, 503, "The plain completion failed (HTTP 503, model_unavailable)."),
    ] as [(String?, Int, String)])
    func failedPlainCompletionStopsTheProbe(returnedModelID: String?, status: Int, failure: String) async throws {
        var fake = FakeProvider()
        fake.plain = status == 200
            ? Reply(body: Self.completion(model: returnedModelID, content: "ok"))
            : Reply(
                status: status,
                body: Self.errorBody(code: "model_unavailable", type: "server_error", message: "Model unavailable.")
            )
        let transport = fake.transport()

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(!report.passed)
        #expect(report.plainCompletion?.returnedModelMatches == false)
        #expect(report.criticalFailures == [failure])
        #expect(report.toolTurn == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func invalidJSONObjectRepliesAreCriticalFailures() async throws {
        var fenced = FakeProvider()
        fenced.jsonObject = Reply(body: Self.completion(content: "```json\n{\"ok\":true}\n```"))
        let fencedReport = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fenced.transport()
        ).run()
        // Widen's parser strips a fence, so this still counts as valid.
        #expect(fencedReport.passed)
        #expect(fencedReport.jsonObject?.validJSONObject == true)
        #expect(fencedReport.jsonObject?.parsedStrictly == false)

        var prose = FakeProvider()
        prose.jsonObject = Reply(body: Self.completion(content: "ok"))
        let proseReport = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: prose.transport()
        ).run()
        #expect(!proseReport.passed)
        #expect(proseReport.jsonObject?.validJSONObject == false)
        #expect(proseReport.jsonObject?.invalidContentExcerpt == "ok")
        #expect(proseReport.criticalFailures == ["The json_object completion did not return a JSON object (HTTP 200)."])

        var rejected = FakeProvider()
        rejected.jsonObject = Reply(
            status: 502,
            body: Self.errorBody(
                code: "invalid_model_output",
                type: "server_error",
                message: "The model output was not valid JSON."
            )
        )
        let rejectedReport = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: rejected.transport()
        ).run()
        #expect(!rejectedReport.passed)
        #expect(rejectedReport.jsonObject?.request.errorCode == "invalid_model_output")
        #expect(
            rejectedReport.jsonObject?.request.errorCategory
                == CloudRequestFailure.Category.malformedStructuredResponse.rawValue
        )
        #expect(
            rejectedReport.criticalFailures
                == ["The json_object completion did not return a JSON object (HTTP 502, invalid_model_output)."]
        )
    }

    @Test func foreignKeyIsRefusedBeforeAnythingIsSent() async throws {
        let transport = FakeProvider().transport()

        let report = await ProviderAPIProbe(
            apiKey: "sk-or-v1-abc",
            profile: .particleTest,
            transport: transport
        ).run()

        #expect(!report.passed)
        #expect(!report.modelList.request.sent)
        #expect(report.criticalFailures.first?.contains("it was not sent") == true)
        #expect(report.criticalFailures.first?.lowercased().contains("credential host mismatch") == true)
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Cost

    @Test func costIsEstimatedFromUsageAtTheProfilesPrices() async throws {
        var fake = FakeProvider()
        // The named tool_choice reply carries no usage.
        fake.namedTool = Reply(
            body: Self.completion(
                content: nil,
                toolCalls: [Self.toolCall(id: "call_named", name: "get_time")],
                usage: nil
            )
        )

        let report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        // Each priced reply: 600 uncached prompt tokens at $0.25, 400 cached
        // at $0.03 and 200 completion tokens at $1.00 per 1M.
        let perCompletion = (600 * 0.25 + 400 * 0.03 + 200 * 1.00) / 1_000_000
        let cost = report.cost
        #expect(cost.pricing == ProviderAPIProbeReport.Pricing(CloudModelProfile.particle.pricing!))
        #expect(cost.sentCompletionCount == 8)
        #expect(cost.pricedCompletionCount == 7)
        #expect(cost.unpricedCompletionCount == 1)
        #expect(cost.promptTokens == 7_000)
        #expect(cost.cachedTokens == 2_800)
        #expect(cost.completionTokens == 1_400)
        #expect(cost.reasoningTokens == 350)
        #expect(abs(cost.estimatedCostUSD - 7 * perCompletion) < 1e-12)
        #expect(abs((report.plainCompletion?.request.usage?.estimatedCostUSD ?? 0) - perCompletion) < 1e-12)
        #expect(report.namedToolChoice?.request.usage == nil)
        #expect(
            report.costLine
                == "Estimated cost: $0.0025 for 8 sent completions from usage at list prices ($0.25 input, $0.03 cached input, $1.00 output per 1M tokens; an upper bound); 1 reported no usage."
        )
        #expect(report.warnings.contains { $0.contains("1 sent completion(s) reported no usage") })
        #expect(report.markdown().contains(report.costLine))
    }

    // MARK: - Report safety

    @Test(arguments: ["pai-probeSecret0123456789", "particle-secret-without-a-known-prefix"])
    func reportNeverContainsTheKey(apiKey: String) async throws {
        var fake = FakeProvider()
        // The key comes back in a header value, a provider error message and
        // a model reply, so only the report's own redaction keeps it out.
        fake.plain = Reply(
            body: Self.completion(content: "ok"),
            headers: ["X-Request-Id": apiKey]
        )
        fake.secondTurn = { _, _ in
            Reply(
                status: 400,
                body: Self.errorBody(
                    code: "unsupported_parameter",
                    type: "invalid_request_error",
                    message: "Key \(apiKey) (Bearer \(apiKey)) may not call https://api.particle.ai/v1/chat/completions"
                )
            )
        }
        fake.jsonObject = Reply(body: Self.completion(content: "not json \(apiKey)"))

        let report = await ProviderAPIProbe(
            apiKey: apiKey,
            profile: .particleTest,
            transport: fake.transport()
        ).run()

        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        let markdown = report.markdown()
        for text in [json, markdown] {
            #expect(!text.contains(apiKey))
            #expect(!text.contains("Bearer"))
            #expect(!text.contains("https://"))
            #expect(!text.contains(Self.firstTurnID))
            #expect(!text.contains("req-plain"))
        }
        let message = try #require(report.secondTurnVariants.first?.request.errorMessage)
        #expect(message.contains("[redacted-key]"))
        #expect(message.contains("[redacted-url]"))
        #expect(report.jsonObject?.invalidContentExcerpt?.contains("[redacted-key]") == true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-provider-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try report.write(to: directory, apiKey: apiKey)
        #expect(paths.json.lastPathComponent == "probe.json")
        #expect(paths.markdown.lastPathComponent == "probe.md")
        for url in [paths.json, paths.markdown] {
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(!written.contains(apiKey))
        }
        let decoded = try JSONDecoder().decode(
            ProviderAPIProbeReport.self,
            from: Data(contentsOf: paths.json)
        )
        #expect(decoded.passed == report.passed)
        #expect(decoded.criticalFailures == report.criticalFailures)
        #expect(decoded.secondTurnVariants.map(\.request) == report.secondTurnVariants.map(\.request))
        #expect(try decoded.jsonData() == report.jsonData())
    }

    @Test func reportThatWouldContainTheKeyIsNotWritten() async throws {
        var report = await ProviderAPIProbe(
            apiKey: Self.apiKey,
            profile: .particleTest,
            transport: FakeProvider().transport()
        ).run()
        report.warnings.append("leaked \(Self.apiKey)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-provider-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ProviderAPIProbeReport.OutputError.containsAPIKey) {
            try report.write(to: directory, apiKey: Self.apiKey)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Key and id shape

    @Test func apiKeyIsReadFromTheParticleVariableOnly() {
        #expect(ProviderAPIProbe.apiKey(in: ["WIDEN_EVAL_PARTICLE_API_KEY": "  pai-abc \n"]) == "pai-abc")
        #expect(ProviderAPIProbe.apiKey(in: ["WIDEN_EVAL_PARTICLE_API_KEY": "  "]) == nil)
        #expect(ProviderAPIProbe.apiKey(in: ["WIDEN_EVAL_OPENROUTER_API_KEY": "sk-or-v1-abc"]) == nil)
        #expect(ProviderAPIProbe.apiKey(in: [:]) == nil)
        #expect(ProviderAPIProbe.missingAPIKeyMessage.contains("WIDEN_EVAL_PARTICLE_API_KEY"))
        #expect(ProviderAPIProbe.missingAPIKeyMessage.contains("No request was sent."))

        // The default probe targets Particle-1 over the profile's timeouts.
        let probe = ProviderAPIProbe(apiKey: "pai-abc")
        #expect(probe.profile == .particle)
        let transport = probe.transport as? URLSessionTransport
        #expect(transport?.sessionConfiguration.timeoutIntervalForRequest == 180)
    }

    @Test(arguments: [
        ("call_0", "call_", 6, "digits"),
        ("call_abcDEF0123456789abcdefgh", "call_", 29, "alphanumeric"),
        ("toolu_01AbC-x_Y", "toolu_", 15, "alphanumeric+separators"),
        ("chatcmpl-tool-9f8e7d6c5b4a", "chatcmpl-", 26, "alphanumeric+separators"),
        ("fc_9f8e7d6c5b4a", "fc_", 15, "hex"),
        ("3F2504E0-4F89-11D3-9A0C-0305E82C3301", "", 36, "uuid"),
        ("a1-xyz", "", 6, "alphanumeric+separators"),
        ("functions.get_weather:0", "", 23, "other"),
        ("abcdefghijklmn_1", "", 16, "alphanumeric+separators"),
        ("", "", 0, "none"),
    ])
    func toolCallIDShapeKeepsOnlyAShortWordPrefix(
        id: String,
        prefix: String,
        length: Int,
        bodyCharacters: String
    ) {
        let shape = ProviderAPIProbeReport.ToolCallIDShape(id: id)
        #expect(shape.prefix == prefix)
        #expect(shape.length == length)
        #expect(shape.bodyCharacters == bodyCharacters)
    }

    // MARK: - Helpers

    private static var unsupportedParameterReply: Reply {
        Reply(
            status: 400,
            body: errorBody(
                code: "unsupported_parameter",
                type: "invalid_request_error",
                message: "Unsupported parameter: messages[3].name"
            )
        )
    }

    fileprivate static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func toolNames(in body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }

    fileprivate static func particleModel(id: String = "particle-1") -> [String: Any] {
        [
            "id": id,
            "object": "model",
            "owned_by": "particle-ai",
            "context_window": 1_048_576,
            "max_output_tokens": 131_072,
            "capabilities": ["tool_calling": true, "structured_outputs": false],
            "reasoning": [
                "default_effort": "high",
                "supported_efforts": ["none", "low", "medium", "high"],
            ],
        ]
    }

    fileprivate static func modelList(_ models: [[String: Any]]) -> Data {
        jsonData(["object": "list", "data": models])
    }

    fileprivate static var usage: [String: Any] {
        [
            "prompt_tokens": 1_000,
            "completion_tokens": 200,
            "total_tokens": 1_200,
            "prompt_tokens_details": ["cached_tokens": 400],
            "completion_tokens_details": ["reasoning_tokens": 50],
        ]
    }

    fileprivate static func toolCall(
        id: String,
        name: String = "get_weather",
        arguments: String = #"{"city":"Paris"}"#
    ) -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }

    fileprivate static func completion(
        model: String? = ParticleTestSupport.returnedModelID,
        content: String?,
        toolCalls: [[String: Any]] = [],
        reasoningContent: String? = nil,
        usage: [String: Any]? = ProviderAPIProbeTests.usage
    ) -> Data {
        var message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        if let reasoningContent { message["reasoning_content"] = reasoningContent }
        var response: [String: Any] = [
            "id": "chatcmpl-probe",
            "object": "chat.completion",
            "choices": [
                [
                    "index": 0,
                    "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls",
                    "message": message,
                ] as [String: Any]
            ],
        ]
        if let model { response["model"] = model }
        if let usage { response["usage"] = usage }
        return jsonData(response)
    }

    private static func errorBody(code: String, type: String, message: String) -> Data {
        jsonData(["error": ["message": message, "type": type, "code": code]])
    }

    private static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
