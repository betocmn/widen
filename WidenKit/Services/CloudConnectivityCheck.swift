import Foundation

/// Tests an API key against its profile's provider without sending any
/// database context. It lists the provider's models to confirm the key
/// works, that the profile's model is listed and that tool calling is on,
/// then optionally sends one tiny JSON completion and checks which model
/// answered. Nothing is cached, so every run asks the provider again.
struct CloudConnectivityCheck: Sendable {
    struct Result: Equatable, Sendable {
        /// True once the provider accepted the signed model-list request;
        /// cleared when a later request is rejected as unauthenticated.
        var keyAccepted: Bool
        var modelListed: Bool
        /// `nil` when the model list does not say.
        var toolCallingAdvertised: Bool?
        var contextWindowTokens: Int?
        var defaultReasoningEffort: String?
        var returnedModelID: String?
        /// The tiny completion came back as a JSON object from the model the
        /// profile pins.
        var completionVerified: Bool
        var latencyMs: Int
        var error: CloudRequestFailure?
    }

    /// The model list and the completion are each sent at most this often.
    static let maximumHTTPAttempts = 2
    static let defaultTimeoutSeconds: TimeInterval = 30
    static let completionInstructions = #"Reply with {"ok":true}"#
    static let completionPrompt = "ping"

    let apiKey: String
    let profile: CloudModelProfile
    let transport: any HTTPTransport
    let includeCompletion: Bool

    /// Requests go only to `profile`'s host. Without a transport, one is
    /// built with a 30-second request timeout.
    init(
        apiKey: String,
        profile: CloudModelProfile = .particle,
        transport: (any HTTPTransport)? = nil,
        includeCompletion: Bool = true
    ) {
        self.apiKey = apiKey
        self.profile = profile
        self.transport = transport ?? URLSessionTransport(timeout: Self.defaultTimeoutSeconds)
        self.includeCompletion = includeCompletion
    }

    func run() async -> Result {
        let started = Date()
        var result = Result(
            keyAccepted: false,
            modelListed: false,
            toolCallingAdvertised: nil,
            contextWindowTokens: nil,
            defaultReasoningEffort: nil,
            returnedModelID: nil,
            completionVerified: false,
            latencyMs: 0,
            error: nil
        )
        do {
            let (models, listAttempts) = try await fetchModelList()
            result.keyAccepted = true
            guard let model = listedModel(in: models) else {
                throw CloudRequestFailure(
                    category: .modelNotFound,
                    message: "\(profile.displayName) is not in the \(profile.provider.displayName) model list for this API key.",
                    requestedModelID: profile.requestedModelID,
                    attemptCount: listAttempts
                )
            }
            result.modelListed = true
            result.toolCallingAdvertised = model.toolCalling
            result.contextWindowTokens = model.contextWindowTokens
            result.defaultReasoningEffort = model.defaultReasoningEffort
            if model.toolCalling == false {
                throw CloudRequestFailure(
                    category: .unsupportedFeature,
                    message: "\(profile.provider.displayName) does not advertise tool calling for \(profile.displayName), which Widen's text-to-SQL agent needs.",
                    requestedModelID: profile.requestedModelID,
                    attemptCount: listAttempts
                )
            }
            if includeCompletion {
                let metadata = try await verifyCompletion()
                result.returnedModelID = metadata.returnedModelID
                result.completionVerified = true
            }
        } catch let failure as CloudRequestFailure {
            if failure.category == .authentication {
                result.keyAccepted = false
            }
            result.returnedModelID = failure.diagnostic.returnedModelID
            result.error = failure
        } catch {
            result.error = CloudRequestFailure(
                category: .networkTransport,
                message: error.localizedDescription,
                requestedModelID: profile.requestedModelID
            )
        }
        result.latencyMs = elapsedMilliseconds(since: started)
        return result
    }

    // MARK: - Model list

    private func fetchModelList() async throws -> (models: [CloudModelListEntry], attempts: Int) {
        guard let modelsURL = profile.modelsURL else {
            throw CloudRequestFailure(
                category: .unsupportedFeature,
                message: "\(profile.provider.displayName) has no model list for Widen to check.",
                requestedModelID: profile.requestedModelID,
                attemptCount: 0
            )
        }
        let request = try profile.authorizedRequest(modelsURL, apiKey: apiKey, httpMethod: "GET")
        return try await send(request) { data, response, attempt in
            guard (200..<300).contains(response.statusCode) else {
                throw CloudSQLResponseParser.failure(
                    from: data,
                    response: response,
                    requestedModelID: profile.requestedModelID,
                    attemptCount: attempt,
                    profile: profile
                )
            }
            guard let list = try? JSONDecoder().decode(JSONValue.self, from: data),
                let entries = CloudModelListEntry.entries(in: list)
            else {
                throw CloudRequestFailure(
                    category: .malformedStructuredResponse,
                    message: "\(profile.provider.displayName) returned a model list Widen could not read.",
                    httpStatus: response.statusCode,
                    requestID: CloudSQLResponseParser.requestID(from: response, profile: profile),
                    requestedModelID: profile.requestedModelID,
                    attemptCount: attempt
                )
            }
            return (entries, attempt)
        }
    }

    private func listedModel(in models: [CloudModelListEntry]) -> CloudModelListEntry? {
        CloudModelListEntry.entry(for: profile, in: models)
    }

    // MARK: - Completion

    /// Sends the connectivity-probe call site's tiny `json_object` request.
    /// It carries only the fixed instructions and "ping": no schema, no
    /// database context and no question.
    private func verifyCompletion() async throws -> CloudGenerationMetadata {
        let built = try ChatCompletionRequestBuilder(profile: profile).build(
            apiKey: apiKey,
            instructions: Self.completionInstructions,
            prompt: Self.completionPrompt,
            capabilities: probeCapabilities,
            callSite: .connectivityProbe
        )
        let parser = ChatToolParser(profile: profile)
        return try await send(built.request) { data, response, attempt in
            // The parser applies the shared error mapping and the identity
            // check before any content is read.
            let turn = try parser.parse(
                data: data,
                response: response,
                requestedModelID: profile.requestedModelID,
                requestCount: attempt,
                retryCount: attempt - 1
            )
            guard let content = turn.content,
                let objectData = CloudSQLResponseParser.promptOnlyJSONObjectData(from: content),
                (try? JSONSerialization.jsonObject(with: objectData)) is [String: Any]
            else {
                throw CloudRequestFailure(
                    category: .malformedStructuredResponse,
                    message: "\(profile.displayName) did not reply with a JSON object.",
                    httpStatus: response.statusCode,
                    completionID: turn.metadata.completionID,
                    requestID: turn.metadata.requestID,
                    requestedModelID: profile.requestedModelID,
                    returnedModelID: turn.metadata.returnedModelID,
                    providerName: turn.metadata.providerName,
                    attemptCount: attempt
                )
            }
            return turn.metadata
        }
    }

    private var probeCapabilities: CloudModelCapabilities {
        if case .staticCapabilities(let capabilities) = profile.capabilityResolution {
            return capabilities
        }
        return .conservative()
    }

    // MARK: - Transport

    /// Sends `request` and parses the reply, resending it once after a
    /// retryable failure.
    private func send<Parsed>(
        _ request: URLRequest,
        parse: (Data, HTTPURLResponse, Int) throws -> Parsed
    ) async throws -> Parsed {
        let retryPolicy = ChatCompletionRetryPolicy(maxAttempts: Self.maximumHTTPAttempts)
        var attempt = 1
        var noContentRetries = 0
        var invalidOutputRetries = 0
        while true {
            try Task.checkCancellation()
            var failure: CloudRequestFailure
            do {
                let (data, response) = try await transport.send(request)
                do {
                    return try parse(data, response, attempt)
                } catch let parsed as CloudRequestFailure {
                    failure = parsed
                    failure.diagnostic.retryAfterSeconds = retryPolicy.retryAfter(from: response)
                }
            } catch let error as URLError {
                if error.code == .cancelled, Task.isCancelled {
                    throw CancellationError()
                }
                failure = CloudRequestFailure.map(
                    error,
                    requestedModelID: profile.requestedModelID,
                    attempt: attempt
                )
            }
            if failure.category == .noContent { noContentRetries += 1 }
            guard let delay = retryPolicy.retryDelay(
                for: failure,
                attempt: attempt,
                noContentRetries: max(0, noContentRetries - 1),
                invalidOutputRetries: invalidOutputRetries
            ) else {
                throw failure.withAttemptCount(attempt)
            }
            if failure.isInvalidModelOutput { invalidOutputRetries += 1 }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
}

/// One entry of `GET {base}/models`. The list is `{"data": [M]}` or a bare
/// `[M]`. Particle's documented M is `{id, context_window?,
/// max_output_tokens?, capabilities?: {tool_calling?, structured_outputs?},
/// reasoning?: {default_effort?, supported_efforts?}}`; the live API answers
/// with its nested schema instead, where limits and parameters sit under
/// `input_modalities` / `output_modalities` entries of type `text`. Both
/// shapes are read. Every field but `id` is optional, and a field with an
/// unexpected type reads as missing.
struct CloudModelListEntry: Equatable, Sendable {
    var id: String
    var contextWindowTokens: Int?
    var maxOutputTokens: Int?
    /// The documented `capabilities` flags, or `tool_calling` derived from a
    /// listed `tools` parameter.
    var capabilities: [String: Bool]?
    var defaultReasoningEffort: String?
    var supportedReasoningEfforts: [String]?
    /// Set on alternate-tier listings (for example `flex`) of the same model.
    var serviceTier: String?

    var toolCalling: Bool? { capabilities?["tool_calling"] }

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue else { return nil }
        self.id = id
        let textInput = Self.textModality(value["input_modalities"])
        let textOutput = Self.textModality(value["output_modalities"])
        let parameters = textOutput?["supported_parameters"]
        contextWindowTokens = value["context_window"]?.intValue
            ?? textInput?["supported_inputs"]?["max_context_length"]?["value"]?.intValue
        maxOutputTokens = value["max_output_tokens"]?.intValue
            ?? textOutput?["max_length"]?["value"]?.intValue
        if let documented = value["capabilities"]?.objectValue?.compactMapValues(\.boolValue) {
            capabilities = documented
        } else if let parameters = parameters?.objectValue {
            capabilities = ["tool_calling": parameters["tools"] != nil]
        }
        defaultReasoningEffort = value["reasoning"]?["default_effort"]?.stringValue
        supportedReasoningEfforts = (value["reasoning"]?["supported_efforts"]
            ?? parameters?["reasoning_effort"]?["values"]
            ?? parameters?["reasoning"]?["properties"]?["effort"]?["values"])?
            .arrayValue?.compactMap(\.stringValue)
        serviceTier = value["service_tier"]?.stringValue
    }

    static func entries(in list: JSONValue) -> [CloudModelListEntry]? {
        (list["data"]?.arrayValue ?? list.arrayValue)?.compactMap(Self.init)
    }

    /// The entry for the profile's requested model, or else the one named
    /// like the model responses report. A default-tier listing wins over
    /// alternate-tier listings of the same model.
    static func entry(for profile: CloudModelProfile, in entries: [CloudModelListEntry]) -> CloudModelListEntry? {
        let ids = [profile.requestedModelID] + (profile.expectedReturnedModelID.map { [$0] } ?? [])
        for id in ids {
            let matches = entries.filter { $0.id == id }
            if let match = matches.first(where: { $0.serviceTier == nil }) ?? matches.first {
                return match
            }
        }
        return nil
    }

    private static func textModality(_ modalities: JSONValue?) -> JSONValue? {
        modalities?.arrayValue?.first { $0["type"]?.stringValue == "text" }
    }
}
