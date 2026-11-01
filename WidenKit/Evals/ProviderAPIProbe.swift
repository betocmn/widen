import Foundation

/// Checks, with a handful of tiny paid requests, how a provider's chat API
/// handles the request shapes Widen's agent depends on: the model list, a
/// plain completion, a tool turn, four second-turn message shapes, a named
/// `tool_choice` and `json_object`. It builds each body by hand so it can
/// send shapes the shared request builder never would, and reads response
/// headers the parsers ignore.
///
/// Every request is signed by the profile, so it can reach only the
/// profile's host. Every chat body caps `max_completion_tokens` at 1,024 and
/// names its `reasoning_effort`. Nothing is retried, so each finding is the
/// provider's first answer. The report keeps no API key, header value,
/// tool-call id or model output beyond a short excerpt of an invalid JSON
/// reply, and provider messages pass through `EvalReportRedaction`.
public struct ProviderAPIProbe: Sendable {
    /// The largest `max_completion_tokens` any probe request sends.
    public static let maximumCompletionTokens = 1_024
    static let plainCompletionTokens = 64
    static let jsonObjectCompletionTokens = 256
    static let toolTurnEffort = ReasoningEffort.low
    static let namedToolName = "get_time"
    /// The most completions one run sends, after its one model-list request.
    public static let maximumCompletionCount = 8

    let apiKey: String
    let profile: CloudModelProfile
    let transport: any HTTPTransport

    /// Probes Particle-1. Without a transport, one is built with the
    /// profile's timeouts.
    public init(apiKey: String, transport: (any HTTPTransport)? = nil) {
        self.init(apiKey: apiKey, profile: .particle, transport: transport)
    }

    init(apiKey: String, profile: CloudModelProfile, transport: (any HTTPTransport)? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profile = profile
        self.transport = transport ?? URLSessionTransport(timeoutsOf: profile)
    }

    /// The Particle eval key from `environment`. No other key is read.
    public static func apiKey(in environment: [String: String]) -> String? {
        CloudModelProfile.particle.evalAPIKey(in: environment)
    }

    public static var missingAPIKeyMessage: String {
        let variable = CloudModelProfile.particle.evalAPIKeyEnvironmentVariable
        return "--provider-probe needs \(variable). Add it to .env.eval.local, which make eval-provider-probe loads, or export it. No request was sent."
    }

    /// Runs every step in order. It stops before any completion when the
    /// model is not listed, and after the plain completion when that fails,
    /// so a broken key or model costs nothing more.
    public func run() async -> ProviderAPIProbeReport {
        let startedAt = Self.timestamp()
        var report = ProviderAPIProbeReport(
            provider: profile.provider.rawValue,
            endpointHost: profile.baseURL.host ?? "",
            requestedModelID: profile.requestedModelID,
            expectedReturnedModelID: profile.expectedReturnedModelID,
            startedAt: startedAt,
            modelList: await probeModelList()
        )

        if let failure = criticalFailure(modelList: report.modelList) {
            report.criticalFailures.append(failure)
            return finished(report, stoppedEarly: true)
        }

        let plain = await probePlainCompletion()
        report.plainCompletion = plain
        if let failure = criticalFailure(plainCompletion: plain) {
            report.criticalFailures.append(failure)
            return finished(report, stoppedEarly: true)
        }

        let (toolTurn, firstTurn) = await probeToolTurn()
        report.toolTurn = toolTurn
        report.secondTurnVariants = await probeSecondTurnVariants(after: firstTurn)
        report.namedToolChoice = await probeNamedToolChoice()
        report.jsonObject = await probeJSONObject()

        let ids = firstTurn.toolCalls.compactMap(\.id)
            + report.secondTurnVariants.flatMap(\.responseToolCallIDs)
            + (report.namedToolChoice?.responseToolCallIDs ?? [])
        report.toolCallIDsUniqueAcrossTurns = ids.count < 2 ? nil : Set(ids).count == ids.count

        if !report.secondTurnVariants.contains(where: \.request.accepted) {
            report.criticalFailures.append(
                "No second-turn variant was accepted."
                    + (firstTurn.toolCalls.isEmpty ? " The tool turn returned no tool call to answer." : "")
            )
        } else if let variant = report.secondTurnVariants.first(where: \.matchesProfile),
            !variant.request.accepted
        {
            report.warnings.append(
                "The second-turn shape the \(profile.displayName) profile sends (\(variant.label)) was not accepted; set echoesReasoningContent and sendsToolMessageName from an accepted variant."
            )
        }
        if let named = report.namedToolChoice, !named.honored {
            report.warnings.append(
                named.request.accepted
                    ? "Named tool_choice was not honored: the model called \(named.calledTools.isEmpty ? "no tool" : named.calledTools.joined(separator: ", ")) instead of \(named.namedTool)."
                    : "The named tool_choice request was not accepted."
            )
        }
        if let jsonObject = report.jsonObject, !jsonObject.validJSONObject {
            report.criticalFailures.append(
                "The json_object completion did not return a JSON object\(Self.statusSuffix(jsonObject.request))."
            )
        }
        return finished(report, stoppedEarly: false)
    }

    // MARK: - Step 0: model list

    private func probeModelList() async -> ProviderAPIProbeReport.ModelListFinding {
        let exchange = await send(method: "GET", url: profile.modelsURL, chat: nil)
        var finding = ProviderAPIProbeReport.ModelListFinding(request: exchange.outcome)
        guard exchange.outcome.accepted,
            let entries = exchange.json.flatMap(CloudModelListEntry.entries(in:))
        else {
            if exchange.outcome.accepted {
                finding.request.accepted = false
                finding.request.errorMessage = "The model list could not be read."
            }
            return finding
        }
        guard let model = CloudModelListEntry.entry(for: profile, in: entries) else { return finding }
        finding.listed = true
        finding.listedID = model.id
        finding.contextWindowTokens = model.contextWindowTokens
        finding.maxOutputTokens = model.maxOutputTokens
        finding.capabilities = model.capabilities
        finding.defaultReasoningEffort = model.defaultReasoningEffort
        finding.supportedReasoningEfforts = model.supportedReasoningEfforts
        return finding
    }

    private func criticalFailure(modelList: ProviderAPIProbeReport.ModelListFinding) -> String? {
        guard !modelList.listed else { return nil }
        guard modelList.request.accepted else {
            return "The model list request failed\(Self.statusSuffix(modelList.request))."
        }
        return "\(profile.requestedModelID) is not in the \(profile.provider.displayName) model list for this API key."
    }

    // MARK: - Step 1: plain completion

    private func probePlainCompletion() async -> ProviderAPIProbeReport.PlainCompletionFinding {
        let exchange = await send(
            chat: ChatRequest(
                messages: [
                    Self.message("system", "Reply with the single word ok."),
                    Self.message("user", "ping"),
                ],
                reasoningEffort: ReasoningEffort.none,
                maxCompletionTokens: Self.plainCompletionTokens
            )
        )
        let returned = exchange.outcome.returnedModelID
        let headerNames = exchange.response.map(Self.requestIDHeaderNames(in:)) ?? []
        return ProviderAPIProbeReport.PlainCompletionFinding(
            request: exchange.outcome,
            returnedModelMatches: exchange.outcome.accepted
                && (profile.expectedReturnedModelID.map { $0 == returned } ?? (returned != nil)),
            requestIDHeaderNames: headerNames,
            profileRequestIDHeaderPresent: exchange.response.map { response in
                profile.requestIDHeaderNames.contains {
                    response.value(forHTTPHeaderField: $0) != nil
                }
            } ?? false,
            cachedTokensReported: exchange.outcome.usage?.cachedTokens != nil,
            reasoningTokensReported: exchange.outcome.usage?.reasoningTokens != nil
        )
    }

    private func criticalFailure(
        plainCompletion: ProviderAPIProbeReport.PlainCompletionFinding
    ) -> String? {
        guard plainCompletion.request.accepted else {
            return "The plain completion failed\(Self.statusSuffix(plainCompletion.request))."
        }
        guard plainCompletion.returnedModelMatches else {
            let returned = plainCompletion.request.returnedModelID ?? "an unnamed model"
            let expected = profile.expectedReturnedModelID ?? profile.requestedModelID
            return "The plain completion came from \(returned), not \(expected)."
        }
        return nil
    }

    // MARK: - Step 2: tool turn

    /// The parts of the first tool turn the second turn echoes. Held in
    /// memory only; the report keeps shapes, not values.
    private struct FirstTurn {
        struct ToolCall {
            var id: String?
            var name: String?
            var arguments: String
        }

        var content: String?
        var reasoningContent: String?
        var toolCalls: [ToolCall] = []
    }

    private static var toolTurnMessages: [[String: Any]] {
        [
            message(
                "system",
                "You are testing tool calls. Call get_weather once per city, one city per turn, before you answer."
            ),
            message("user", "What is the weather in Paris and in Rome?"),
        ]
    }

    private func probeToolTurn() async -> (ProviderAPIProbeReport.ToolTurnFinding, FirstTurn) {
        let exchange = await send(
            chat: ChatRequest(
                messages: Self.toolTurnMessages,
                reasoningEffort: Self.toolTurnEffort,
                maxCompletionTokens: Self.maximumCompletionTokens,
                tools: [Self.weatherTool],
                toolChoice: "required",
                parallelToolCalls: false
            )
        )
        let message = exchange.outcome.accepted ? Self.firstMessage(in: exchange.json) : nil
        let firstTurn = FirstTurn(
            content: message?["content"]?.stringValue,
            reasoningContent: message?["reasoning_content"]?.stringValue.flatMap {
                $0.isEmpty ? nil : $0
            },
            toolCalls: Self.toolCalls(in: message)
        )
        let finding = ProviderAPIProbeReport.ToolTurnFinding(
            request: exchange.outcome,
            toolCalls: firstTurn.toolCalls.map(Self.finding(for:)),
            reasoningContentPresent: firstTurn.reasoningContent != nil,
            assistantMessageFields: message?.objectValue.map { $0.keys.sorted() } ?? []
        )
        return (finding, firstTurn)
    }

    // MARK: - Step 3: second turn

    private static let weatherToolResult = #"{"conditions":"sunny","temperature_c":21}"#

    private struct SecondTurnShape: Equatable {
        var echoesReasoningContent: Bool
        var sendsToolMessageName: Bool
    }

    /// The profile's own shape first, then every other combination.
    private var secondTurnShapes: [SecondTurnShape] {
        let own = SecondTurnShape(
            echoesReasoningContent: profile.echoesReasoningContent,
            sendsToolMessageName: profile.sendsToolMessageName
        )
        let all = [false, true].flatMap { echoes in
            [false, true].map {
                SecondTurnShape(echoesReasoningContent: echoes, sendsToolMessageName: $0)
            }
        }
        return [own] + all.filter { $0 != own }
    }

    private func probeSecondTurnVariants(
        after firstTurn: FirstTurn
    ) async -> [ProviderAPIProbeReport.SecondTurnVariant] {
        var variants: [ProviderAPIProbeReport.SecondTurnVariant] = []
        let firstTurnIDs = Set(firstTurn.toolCalls.compactMap(\.id))
        for shape in secondTurnShapes {
            var variant = ProviderAPIProbeReport.SecondTurnVariant(
                echoesReasoningContent: shape.echoesReasoningContent,
                sendsToolMessageName: shape.sendsToolMessageName,
                matchesProfile: shape.echoesReasoningContent == profile.echoesReasoningContent
                    && shape.sendsToolMessageName == profile.sendsToolMessageName,
                request: ProviderAPIProbeReport.RequestOutcome(
                    reasoningEffort: Self.toolTurnEffort.rawValue,
                    maxCompletionTokens: Self.maximumCompletionTokens
                )
            )
            if firstTurn.toolCalls.isEmpty {
                variant.skippedReason = "The tool turn returned no tool call to answer."
            } else if firstTurn.toolCalls.contains(where: { $0.id == nil }) {
                variant.skippedReason = "The tool turn returned a tool call without an id."
            } else if shape.echoesReasoningContent, firstTurn.reasoningContent == nil {
                variant.skippedReason = "The tool turn returned no reasoning_content to echo."
            }
            guard variant.skippedReason == nil else {
                variants.append(variant)
                continue
            }

            var assistant: [String: Any] = [
                "role": "assistant",
                "content": firstTurn.content ?? NSNull(),
                "tool_calls": firstTurn.toolCalls.map { call in
                    [
                        "id": call.id ?? "",
                        "type": "function",
                        "function": ["name": call.name ?? "", "arguments": call.arguments],
                    ] as [String: Any]
                },
            ]
            if shape.echoesReasoningContent {
                assistant["reasoning_content"] = firstTurn.reasoningContent
            }
            let toolMessages: [[String: Any]] = firstTurn.toolCalls.map { call in
                var message: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": call.id ?? "",
                    "content": Self.weatherToolResult,
                ]
                if shape.sendsToolMessageName {
                    message["name"] = call.name ?? Self.weatherToolName
                }
                return message
            }
            let exchange = await send(
                chat: ChatRequest(
                    messages: Self.toolTurnMessages + [assistant] + toolMessages,
                    reasoningEffort: Self.toolTurnEffort,
                    maxCompletionTokens: Self.maximumCompletionTokens,
                    tools: [Self.weatherTool],
                    toolChoice: "required",
                    parallelToolCalls: false
                )
            )
            variant.request = exchange.outcome
            let calls = exchange.outcome.accepted
                ? Self.toolCalls(in: Self.firstMessage(in: exchange.json))
                : []
            variant.toolCalls = calls.map(Self.finding(for:))
            variant.responseToolCallIDs = calls.compactMap(\.id)
            if !variant.responseToolCallIDs.isEmpty {
                variant.reusesToolTurnID = variant.responseToolCallIDs.contains {
                    firstTurnIDs.contains($0)
                }
            }
            variants.append(variant)
        }
        return variants
    }

    // MARK: - Step 4: named tool choice

    private func probeNamedToolChoice() async -> ProviderAPIProbeReport.NamedToolChoiceFinding {
        let exchange = await send(
            chat: ChatRequest(
                messages: [
                    Self.message("system", "You are testing tool calls."),
                    Self.message("user", "What is the weather in Paris?"),
                ],
                reasoningEffort: Self.toolTurnEffort,
                maxCompletionTokens: Self.maximumCompletionTokens,
                tools: [Self.weatherTool, Self.timeTool],
                toolChoice: ["type": "function", "function": ["name": Self.namedToolName]],
                parallelToolCalls: false
            )
        )
        let calls = exchange.outcome.accepted
            ? Self.toolCalls(in: Self.firstMessage(in: exchange.json))
            : []
        let names = calls.map { $0.name ?? "" }
        var finding = ProviderAPIProbeReport.NamedToolChoiceFinding(
            request: exchange.outcome,
            namedTool: Self.namedToolName,
            calledTools: names,
            honored: !names.isEmpty && names.allSatisfy { $0 == Self.namedToolName }
        )
        finding.responseToolCallIDs = calls.compactMap(\.id)
        return finding
    }

    // MARK: - Step 5: json_object

    private func probeJSONObject() async -> ProviderAPIProbeReport.JSONObjectFinding {
        let exchange = await send(
            chat: ChatRequest(
                messages: [
                    Self.message(
                        "system",
                        #"Reply with only a JSON object of the form {"ok": true, "city": "<city>"} for the city the user names."#
                    ),
                    Self.message("user", "Paris"),
                ],
                reasoningEffort: ReasoningEffort.none,
                maxCompletionTokens: Self.jsonObjectCompletionTokens,
                responseFormatType: "json_object"
            )
        )
        let content = exchange.outcome.accepted
            ? Self.firstMessage(in: exchange.json)?["content"]?.stringValue
            : nil
        let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedStrictly = trimmed.map { Self.isJSONObject(Data($0.utf8)) } ?? false
        let valid = parsedStrictly
            || (content.flatMap(CloudSQLResponseParser.promptOnlyJSONObjectData(from:))
                .map(Self.isJSONObject) ?? false)
        return ProviderAPIProbeReport.JSONObjectFinding(
            request: exchange.outcome,
            parsedStrictly: parsedStrictly,
            validJSONObject: valid,
            invalidContentExcerpt: valid ? nil : content.map { redacted(String($0.prefix(200))) }
        )
    }

    // MARK: - Report

    private func finished(
        _ report: ProviderAPIProbeReport,
        stoppedEarly: Bool
    ) -> ProviderAPIProbeReport {
        var report = report
        if stoppedEarly {
            report.stoppedReason = "Stopped after a critical failure; later steps were not sent."
        }
        if let plain = report.plainCompletion, plain.request.accepted,
            !plain.profileRequestIDHeaderPresent
        {
            let seen = plain.requestIDHeaderNames.isEmpty
                ? "none came back"
                : "the response had \(plain.requestIDHeaderNames.joined(separator: ", "))"
            report.warnings.append(
                "None of the profile's request-ID headers (\(profile.requestIDHeaderNames.joined(separator: ", "))) came back; \(seen)."
            )
        }
        report.cost = cost(of: report.completionRequests)
        if report.cost.unpricedCompletionCount > 0 {
            report.warnings.append(
                "\(report.cost.unpricedCompletionCount) sent completion(s) reported no usage, so the estimate leaves them out."
            )
        }
        report.criticalFailures = report.criticalFailures.map(redacted)
        report.warnings = report.warnings.map(redacted)
        report.passed = report.criticalFailures.isEmpty
        report.finishedAt = Self.timestamp()
        return report
    }

    private func cost(
        of requests: [ProviderAPIProbeReport.RequestOutcome]
    ) -> ProviderAPIProbeReport.CostEstimate {
        var estimate = ProviderAPIProbeReport.CostEstimate(
            pricing: profile.pricing.map(ProviderAPIProbeReport.Pricing.init)
        )
        for request in requests where request.sent {
            estimate.sentCompletionCount += 1
            guard let usage = request.usage, let cost = usage.estimatedCostUSD else {
                // A 4xx rejects the request before the model runs. Anything
                // else without usage may still have been billed.
                if !(400..<500).contains(request.httpStatus ?? 0) {
                    estimate.unpricedCompletionCount += 1
                }
                continue
            }
            estimate.pricedCompletionCount += 1
            estimate.promptTokens += usage.promptTokens ?? 0
            estimate.cachedTokens += usage.cachedTokens ?? 0
            estimate.completionTokens += usage.completionTokens ?? 0
            estimate.reasoningTokens += usage.reasoningTokens ?? 0
            estimate.estimatedCostUSD += cost
        }
        return estimate
    }

    // MARK: - Transport

    private struct ChatRequest {
        var messages: [[String: Any]]
        var reasoningEffort: ReasoningEffort
        var maxCompletionTokens: Int
        var tools: [[String: Any]]? = nil
        var toolChoice: Any? = nil
        var parallelToolCalls: Bool? = nil
        var responseFormatType: String? = nil

        /// The capped token limit actually sent.
        var sentCompletionTokens: Int {
            min(maxCompletionTokens, ProviderAPIProbe.maximumCompletionTokens)
        }

        func body(model: String) -> [String: Any] {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": false,
                "max_completion_tokens": sentCompletionTokens,
                "reasoning_effort": reasoningEffort.rawValue,
            ]
            if let tools { body["tools"] = tools }
            if let toolChoice { body["tool_choice"] = toolChoice }
            if let parallelToolCalls { body["parallel_tool_calls"] = parallelToolCalls }
            if let responseFormatType { body["response_format"] = ["type": responseFormatType] }
            return body
        }
    }

    private struct Exchange {
        var outcome: ProviderAPIProbeReport.RequestOutcome
        var json: JSONValue?
        var response: HTTPURLResponse?
    }

    private func send(chat: ChatRequest) async -> Exchange {
        await send(method: "POST", url: profile.chatCompletionsURL, chat: chat)
    }

    /// Signs and sends one request once. A request the profile refuses to
    /// sign is recorded as not sent.
    private func send(method: String, url: URL?, chat: ChatRequest?) async -> Exchange {
        var outcome = ProviderAPIProbeReport.RequestOutcome(
            reasoningEffort: chat?.reasoningEffort.rawValue,
            maxCompletionTokens: chat?.sentCompletionTokens
        )
        guard let url else {
            outcome.errorMessage = "\(profile.provider.displayName) has no model list to probe."
            return Exchange(outcome: outcome)
        }
        let request: URLRequest
        do {
            var signed = try profile.authorizedRequest(url, apiKey: apiKey, httpMethod: method)
            if let chat {
                signed.httpBody = try JSONSerialization.data(
                    withJSONObject: chat.body(model: profile.requestedModelID),
                    options: [.sortedKeys]
                )
            }
            request = signed
        } catch {
            outcome.errorMessage = redacted(error.localizedDescription)
            return Exchange(outcome: outcome)
        }

        let started = Date()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            outcome.sent = true
            outcome.latencyMs = Self.milliseconds(since: started)
            outcome.errorMessage = redacted(error.localizedDescription)
            return Exchange(outcome: outcome)
        }
        outcome.sent = true
        outcome.latencyMs = Self.milliseconds(since: started)
        outcome.httpStatus = response.statusCode

        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let apiError = json?["error"]
        let succeeded = (200..<300).contains(response.statusCode) && apiError == nil
        if !succeeded {
            outcome.errorCode = apiError?["code"]?.stringValue ?? apiError?["code"]?.intValue.map(String.init)
            outcome.errorType = apiError?["type"]?.stringValue
            outcome.errorMessage = (apiError?["message"]?.stringValue).map {
                redacted(String($0.prefix(300)))
            }
            outcome.errorCategory = CloudSQLResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: profile.requestedModelID,
                attemptCount: 1,
                profile: profile
            ).category.rawValue
        }
        if chat != nil {
            outcome.returnedModelID = json?["model"]?.stringValue
            outcome.finishReason = json?["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue
            outcome.usage = CloudSQLResponseParser.reportedUsage(from: data, profile: profile)
                .map(ProviderAPIProbeReport.Usage.init)
            outcome.accepted = succeeded && json?["choices"]?.arrayValue?.isEmpty == false
        } else {
            outcome.accepted = succeeded && json != nil
        }
        return Exchange(outcome: outcome, json: json, response: response)
    }

    /// Removes the key itself, then everything `EvalReportRedaction` strips.
    private func redacted(_ message: String) -> String {
        let withoutKey = apiKey.isEmpty
            ? message
            : message.replacingOccurrences(of: apiKey, with: "[redacted-key]")
        return EvalReportRedaction.redactedProviderMessage(withoutKey)
    }

    // MARK: - Helpers

    static let weatherToolName = "get_weather"

    private static var weatherTool: [String: Any] {
        tool(name: weatherToolName, description: "Returns the current weather for one city.")
    }

    private static var timeTool: [String: Any] {
        tool(name: namedToolName, description: "Returns the current local time for one city.")
    }

    private static func tool(name: String, description: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": ["city": ["type": "string", "description": "The city name."]],
                    "required": ["city"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func message(_ role: String, _ content: String) -> [String: Any] {
        ["role": role, "content": content]
    }

    private static func firstMessage(in json: JSONValue?) -> JSONValue? {
        json?["choices"]?.arrayValue?.first?["message"]
    }

    private static func toolCalls(in message: JSONValue?) -> [FirstTurn.ToolCall] {
        (message?["tool_calls"]?.arrayValue ?? []).map { call in
            let arguments = call["function"]?["arguments"]
            return FirstTurn.ToolCall(
                id: call["id"]?.stringValue,
                name: call["function"]?["name"]?.stringValue,
                arguments: arguments?.stringValue
                    ?? arguments.flatMap { try? $0.encodedData() }.map { String(decoding: $0, as: UTF8.self) }
                    ?? "{}"
            )
        }
    }

    private static func finding(for call: FirstTurn.ToolCall) -> ProviderAPIProbeReport.ToolCallFinding {
        ProviderAPIProbeReport.ToolCallFinding(
            name: call.name,
            idShape: call.id.map(ProviderAPIProbeReport.ToolCallIDShape.init(id:)),
            argumentsAreJSONObject: isJSONObject(Data(call.arguments.utf8))
        )
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Lowercased names of the response headers that look like request,
    /// trace or generation ids. Values are never read.
    static func requestIDHeaderNames(in response: HTTPURLResponse) -> [String] {
        let names = response.allHeaderFields.keys.compactMap { ($0 as? String)?.lowercased() }
        return Set(names.filter { name in
            (name.contains("request") && name.contains("id"))
                || name.contains("trace")
                || name.contains("correlation")
                || name.contains("generation-id")
        }).sorted()
    }

    private static func statusSuffix(_ request: ProviderAPIProbeReport.RequestOutcome) -> String {
        guard request.sent else {
            return request.errorMessage.map { ": it was not sent (\($0))" } ?? ": it was not sent"
        }
        var parts: [String] = []
        if let status = request.httpStatus { parts.append("HTTP \(status)") }
        if let detail = request.errorCode ?? request.errorMessage { parts.append(detail) }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func milliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

private extension ProviderAPIProbeReport.SecondTurnVariant {
    var label: String {
        "echo reasoning_content: \(echoesReasoningContent ? "yes" : "no"), tool-message name: \(sendsToolMessageName ? "yes" : "no")"
    }
}

// MARK: - Report

/// What `ProviderAPIProbe` found, written as `probe.json` and `probe.md`.
/// It holds no API key, header value, tool-call id or model output beyond a
/// short redacted excerpt of an invalid JSON reply.
public struct ProviderAPIProbeReport: Codable, Equatable, Sendable {
    public struct Usage: Codable, Equatable, Sendable {
        public var promptTokens: Int?
        public var cachedTokens: Int?
        public var completionTokens: Int?
        public var reasoningTokens: Int?
        /// The reported cost, or else an estimate at the profile's prices.
        public var estimatedCostUSD: Double?

        init(_ usage: ChatCompletionUsage) {
            promptTokens = usage.promptTokens
            cachedTokens = usage.cachedTokens
            completionTokens = usage.completionTokens
            reasoningTokens = usage.completionTokensDetails?.reasoningTokens
            estimatedCostUSD = usage.costUSD
        }
    }

    /// What one request sent and what came back.
    public struct RequestOutcome: Codable, Equatable, Sendable {
        /// False when the request was refused before sending.
        public var sent = false
        /// The provider answered 2xx with a readable body and no error.
        public var accepted = false
        public var reasoningEffort: String?
        public var maxCompletionTokens: Int?
        public var httpStatus: Int?
        public var errorCode: String?
        public var errorType: String?
        /// The `CloudRequestFailure.Category` Widen maps the error to.
        public var errorCategory: String?
        /// Redacted and shortened.
        public var errorMessage: String?
        public var returnedModelID: String?
        public var finishReason: String?
        public var latencyMs: Int?
        public var usage: Usage?

        init(reasoningEffort: String? = nil, maxCompletionTokens: Int? = nil) {
            self.reasoningEffort = reasoningEffort
            self.maxCompletionTokens = maxCompletionTokens
        }
    }

    /// The form of a tool-call id without its value: a leading word prefix
    /// such as `call_`, the total length and the characters after the prefix.
    public struct ToolCallIDShape: Codable, Equatable, Hashable, Sendable {
        public var prefix: String
        public var length: Int
        /// `uuid`, `digits`, `hex`, `alphanumeric`, `alphanumeric+separators`,
        /// `other` or `none`.
        public var bodyCharacters: String

        init(id: String) {
            let characters = Array(id)
            // Only a short run of letters ending in `_` or `-` counts as a
            // prefix, so no part of a random value is ever kept.
            var prefixLength = 0
            if let separator = characters.prefix(13).firstIndex(where: { $0 == "_" || $0 == "-" }),
                separator > 0,
                characters[..<separator].allSatisfy({ $0.isASCII && $0.isLetter })
            {
                prefixLength = separator + 1
            }
            prefix = String(characters[..<prefixLength])
            length = characters.count
            bodyCharacters = Self.characterClass(of: String(characters[prefixLength...]))
        }

        private static func characterClass(of body: String) -> String {
            if body.isEmpty { return "none" }
            if UUID(uuidString: body) != nil { return "uuid" }
            if body.allSatisfy({ $0.isASCII && $0.isNumber }) { return "digits" }
            if body.allSatisfy({ $0.isHexDigit }) { return "hex" }
            if body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return "alphanumeric" }
            if body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                return "alphanumeric+separators"
            }
            return "other"
        }
    }

    public struct ToolCallFinding: Codable, Equatable, Sendable {
        public var name: String?
        public var idShape: ToolCallIDShape?
        public var argumentsAreJSONObject: Bool
    }

    public struct ModelListFinding: Codable, Equatable, Sendable {
        public var request: RequestOutcome
        public var listed = false
        public var listedID: String?
        public var contextWindowTokens: Int?
        public var maxOutputTokens: Int?
        public var capabilities: [String: Bool]?
        public var defaultReasoningEffort: String?
        public var supportedReasoningEfforts: [String]?

        init(request: RequestOutcome) {
            self.request = request
        }
    }

    public struct PlainCompletionFinding: Codable, Equatable, Sendable {
        public var request: RequestOutcome
        /// Accepted, and the response names the profile's expected model.
        public var returnedModelMatches: Bool
        /// Names only, lowercased; values are never read.
        public var requestIDHeaderNames: [String]
        /// One of the profile's `requestIDHeaderNames` came back.
        public var profileRequestIDHeaderPresent: Bool
        /// `usage.prompt_tokens_details.cached_tokens` was present.
        public var cachedTokensReported: Bool
        /// `usage.completion_tokens_details.reasoning_tokens` was present.
        public var reasoningTokensReported: Bool
    }

    public struct ToolTurnFinding: Codable, Equatable, Sendable {
        public var request: RequestOutcome
        public var toolCalls: [ToolCallFinding]
        public var reasoningContentPresent: Bool
        /// The assistant message's field names.
        public var assistantMessageFields: [String]
    }

    public struct SecondTurnVariant: Codable, Equatable, Sendable {
        public var echoesReasoningContent: Bool
        public var sendsToolMessageName: Bool
        /// The shape the profile's request builder sends today.
        public var matchesProfile: Bool
        /// Why the variant was not sent, when it was not.
        public var skippedReason: String?
        public var request: RequestOutcome
        public var toolCalls: [ToolCallFinding] = []
        /// A tool-call id from the tool turn came back in this response.
        /// `nil` when the response had no tool call.
        public var reusesToolTurnID: Bool?
        /// Compared in memory only; never written.
        var responseToolCallIDs: [String] = []

        private enum CodingKeys: String, CodingKey {
            case echoesReasoningContent, sendsToolMessageName, matchesProfile, skippedReason
            case request, toolCalls, reusesToolTurnID
        }
    }

    public struct NamedToolChoiceFinding: Codable, Equatable, Sendable {
        public var request: RequestOutcome
        public var namedTool: String
        public var calledTools: [String]
        /// The model called the named tool and nothing else.
        public var honored: Bool
        /// Compared in memory only; never written.
        var responseToolCallIDs: [String] = []

        init(request: RequestOutcome, namedTool: String, calledTools: [String], honored: Bool) {
            self.request = request
            self.namedTool = namedTool
            self.calledTools = calledTools
            self.honored = honored
        }

        private enum CodingKeys: String, CodingKey {
            case request, namedTool, calledTools, honored
        }
    }

    public struct JSONObjectFinding: Codable, Equatable, Sendable {
        public var request: RequestOutcome
        /// The whole reply parsed as a JSON object.
        public var parsedStrictly: Bool
        /// Accepted, and the reply is a JSON object once Widen's parser
        /// strips any fence or surrounding text.
        public var validJSONObject: Bool
        public var invalidContentExcerpt: String?
    }

    /// USD per 1M tokens.
    public struct Pricing: Codable, Equatable, Sendable {
        public var input: Double
        public var cachedInput: Double
        public var output: Double

        init(_ pricing: CloudModelPricing) {
            input = pricing.input
            cachedInput = pricing.cachedInput
            output = pricing.output
        }
    }

    public struct CostEstimate: Codable, Equatable, Sendable {
        public var pricing: Pricing?
        public var sentCompletionCount = 0
        public var pricedCompletionCount = 0
        /// Sent completions that may have been billed but reported no usage:
        /// every one without usage except a 4xx rejection.
        public var unpricedCompletionCount = 0
        public var promptTokens = 0
        public var cachedTokens = 0
        public var completionTokens = 0
        public var reasoningTokens = 0
        /// At peak list prices, so an upper bound for the priced completions.
        public var estimatedCostUSD: Double = 0

        init(pricing: Pricing? = nil) {
            self.pricing = pricing
        }
    }

    public var schemaVersion = 1
    public var provider: String
    public var endpointHost: String
    public var requestedModelID: String
    public var expectedReturnedModelID: String?
    public var startedAt: String
    public var finishedAt = ""
    public var passed = false
    public var criticalFailures: [String] = []
    public var warnings: [String] = []
    public var stoppedReason: String?
    public var modelList: ModelListFinding
    public var plainCompletion: PlainCompletionFinding?
    public var toolTurn: ToolTurnFinding?
    public var secondTurnVariants: [SecondTurnVariant] = []
    /// No tool-call id came back in more than one response; `nil` with
    /// fewer than two ids.
    public var toolCallIDsUniqueAcrossTurns: Bool?
    public var namedToolChoice: NamedToolChoiceFinding?
    public var jsonObject: JSONObjectFinding?
    public var cost = CostEstimate()

    init(
        provider: String,
        endpointHost: String,
        requestedModelID: String,
        expectedReturnedModelID: String?,
        startedAt: String,
        modelList: ModelListFinding
    ) {
        self.provider = provider
        self.endpointHost = endpointHost
        self.requestedModelID = requestedModelID
        self.expectedReturnedModelID = expectedReturnedModelID
        self.startedAt = startedAt
        self.modelList = modelList
    }

    /// Every chat completion the probe tried, in order.
    var completionRequests: [RequestOutcome] {
        [plainCompletion?.request, toolTurn?.request].compactMap { $0 }
            + secondTurnVariants.map(\.request)
            + [namedToolChoice?.request, jsonObject?.request].compactMap { $0 }
    }

    /// One line for the console and the spend ledger.
    public var costLine: String {
        let completions = cost.sentCompletionCount
        var line = "Estimated cost: \(Self.usd(cost.estimatedCostUSD)) for \(completions) sent completion\(completions == 1 ? "" : "s")"
        if let pricing = cost.pricing {
            line += " from usage at list prices (\(Self.price(pricing.input)) input, \(Self.price(pricing.cachedInput)) cached input, \(Self.price(pricing.output)) output per 1M tokens; an upper bound)"
        } else {
            line += " from reported usage"
        }
        if cost.unpricedCompletionCount > 0 {
            line += "; \(cost.unpricedCompletionCount) reported no usage"
        }
        return line + "."
    }

    // MARK: Output

    public struct OutputPaths: Sendable {
        public var directory: URL
        public var json: URL
        public var markdown: URL
    }

    public enum OutputError: LocalizedError, Equatable {
        case containsAPIKey

        public var errorDescription: String? {
            "The provider probe report contained the API key, so it was not written."
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Writes `probe.json` and `probe.md` into `directory`. Nothing is
    /// written when either file would contain `apiKey`.
    public func write(to directory: URL, apiKey: String) throws -> OutputPaths {
        let json = try jsonData()
        let markdown = markdown()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty,
            String(decoding: json, as: UTF8.self).contains(key) || markdown.contains(key)
        {
            throw OutputError.containsAPIKey
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = OutputPaths(
            directory: directory,
            json: directory.appendingPathComponent("probe.json"),
            markdown: directory.appendingPathComponent("probe.md")
        )
        try json.write(to: paths.json)
        try markdown.write(to: paths.markdown, atomically: true, encoding: .utf8)
        return paths
    }

    public func markdown() -> String {
        var lines = [
            "# Provider API probe",
            "",
            "**Provider:** \(provider) at \(endpointHost). **Model:** `\(requestedModelID)`, expected to report `\(expectedReturnedModelID ?? "-")`.",
            "",
            "**Started:** \(startedAt). **Finished:** \(finishedAt).",
            "",
            "**Result:** \(passed ? "passed" : "failed")",
            "",
        ]
        if !criticalFailures.isEmpty {
            lines += ["## Critical failures", ""] + criticalFailures.map { "- \(Self.text($0))" } + [""]
        }
        if let stoppedReason {
            lines += [Self.text(stoppedReason), ""]
        }
        if !warnings.isEmpty {
            lines += ["## Warnings", ""] + warnings.map { "- \(Self.text($0))" } + [""]
        }

        lines += [
            "## Requests",
            "",
            "| Step | Sent | Accepted | HTTP | Code | Effort | Max tokens | Returned model | Finish | Latency ms | Prompt | Cached | Completion | Reasoning |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        var steps: [(String, RequestOutcome)] = [("0. GET models", modelList.request)]
        if let plainCompletion { steps.append(("1. Plain completion", plainCompletion.request)) }
        if let toolTurn { steps.append(("2. Tool turn", toolTurn.request)) }
        for variant in secondTurnVariants {
            steps.append(("3. Second turn (\(variant.label))", variant.request))
        }
        if let namedToolChoice { steps.append(("4. Named tool_choice", namedToolChoice.request)) }
        if let jsonObject { steps.append(("5. json_object", jsonObject.request)) }
        for (name, request) in steps {
            lines.append(
                "| \(Self.cell(name)) | \(Self.yesNo(request.sent)) | \(Self.yesNo(request.accepted)) | \(Self.value(request.httpStatus)) | \(Self.cell(request.errorCode ?? "-")) | \(Self.cell(request.reasoningEffort ?? "-")) | \(Self.value(request.maxCompletionTokens)) | \(Self.cell(request.returnedModelID ?? "-")) | \(Self.cell(request.finishReason ?? "-")) | \(Self.value(request.latencyMs)) | \(Self.value(request.usage?.promptTokens)) | \(Self.value(request.usage?.cachedTokens)) | \(Self.value(request.usage?.completionTokens)) | \(Self.value(request.usage?.reasoningTokens)) |"
            )
        }
        lines.append("")

        lines += [
            "## Model list",
            "",
            "| Field | Value |",
            "|---|---|",
            "| Listed | \(modelList.listed ? "yes, as `\(modelList.listedID ?? "-")`" : "no") |",
            "| Context window | \(Self.value(modelList.contextWindowTokens)) |",
            "| Max output tokens | \(Self.value(modelList.maxOutputTokens)) |",
            "| Capabilities | \(Self.cell(modelList.capabilities.map { capabilities in capabilities.keys.sorted().map { "\($0): \(Self.yesNo(capabilities[$0] ?? false))" }.joined(separator: ", ") } ?? "-")) |",
            "| Default effort | \(Self.cell(modelList.defaultReasoningEffort ?? "-")) |",
            "| Supported efforts | \(Self.cell(modelList.supportedReasoningEfforts?.joined(separator: ", ") ?? "-")) |",
            "",
        ]

        if let plainCompletion {
            lines += [
                "## Plain completion",
                "",
                "| Field | Value |",
                "|---|---|",
                "| Returned the expected model | \(Self.yesNo(plainCompletion.returnedModelMatches)) |",
                "| Request-ID header names | \(Self.cell(plainCompletion.requestIDHeaderNames.isEmpty ? "none" : plainCompletion.requestIDHeaderNames.joined(separator: ", "))) |",
                "| A profile request-ID header came back | \(Self.yesNo(plainCompletion.profileRequestIDHeaderPresent)) |",
                "| `cached_tokens` reported | \(Self.yesNo(plainCompletion.cachedTokensReported)) |",
                "| `reasoning_tokens` reported | \(Self.yesNo(plainCompletion.reasoningTokensReported)) |",
                "",
            ]
        }

        if let toolTurn {
            lines += [
                "## Tool turn",
                "",
                "| Field | Value |",
                "|---|---|",
                "| Tool calls | \(Self.cell(Self.describe(toolTurn.toolCalls))) |",
                "| `reasoning_content` present | \(Self.yesNo(toolTurn.reasoningContentPresent)) |",
                "| Assistant message fields | \(Self.cell(toolTurn.assistantMessageFields.isEmpty ? "-" : toolTurn.assistantMessageFields.joined(separator: ", "))) |",
                "",
            ]
        }

        if !secondTurnVariants.isEmpty {
            lines += [
                "## Second turn variants",
                "",
                "| Echo `reasoning_content` | Tool-message `name` | Profile's shape | Accepted | HTTP | Code | Tool calls | Reused a tool-turn id | Note |",
                "|---|---|---|---|---|---|---|---|---|",
            ]
            for variant in secondTurnVariants {
                lines.append(
                    "| \(Self.yesNo(variant.echoesReasoningContent)) | \(Self.yesNo(variant.sendsToolMessageName)) | \(Self.yesNo(variant.matchesProfile)) | \(Self.yesNo(variant.request.accepted)) | \(Self.value(variant.request.httpStatus)) | \(Self.cell(variant.request.errorCode ?? "-")) | \(Self.cell(Self.describe(variant.toolCalls))) | \(variant.reusesToolTurnID.map(Self.yesNo) ?? "-") | \(Self.cell(variant.skippedReason ?? variant.request.errorMessage ?? "-")) |"
                )
            }
            lines += [
                "",
                "Tool-call ids unique across turns: \(toolCallIDsUniqueAcrossTurns.map(Self.yesNo) ?? "not enough ids to tell").",
                "",
            ]
        }

        if let namedToolChoice {
            lines += [
                "## Named tool_choice",
                "",
                "Asked for `\(namedToolChoice.namedTool)`; the model called \(namedToolChoice.calledTools.isEmpty ? "no tool" : namedToolChoice.calledTools.map { "`\($0)`" }.joined(separator: ", ")). Honored: \(Self.yesNo(namedToolChoice.honored)).",
                "",
            ]
        }

        if let jsonObject {
            lines += [
                "## json_object",
                "",
                "Valid JSON object: \(Self.yesNo(jsonObject.validJSONObject)). Parsed without cleanup: \(Self.yesNo(jsonObject.parsedStrictly)).",
                "",
            ]
            if let excerpt = jsonObject.invalidContentExcerpt {
                lines += ["Reply excerpt: \(Self.text(excerpt))", ""]
            }
        }

        let errors = steps.compactMap { name, request in
            request.errorMessage.map { "- \(name): \(Self.text($0))" }
        }
        if !errors.isEmpty {
            lines += ["## Provider messages", ""] + errors + [""]
        }

        lines += ["## Cost", "", costLine, ""]
        return lines.joined(separator: "\n")
    }

    private static func describe(_ calls: [ToolCallFinding]) -> String {
        guard !calls.isEmpty else { return "none" }
        return calls.map { call in
            let shape = call.idShape.map {
                "id prefix `\($0.prefix.isEmpty ? "none" : $0.prefix)`, length \($0.length), \($0.bodyCharacters)"
            } ?? "no id"
            return "\(call.name ?? "unnamed") (\(shape); JSON arguments: \(yesNo(call.argumentsAreJSONObject)))"
        }
        .joined(separator: "; ")
    }

    private static func usd(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    private static func price(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func value(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private static func text(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    private static func cell(_ value: String) -> String {
        text(value).replacingOccurrences(of: "|", with: "\\|")
    }
}
