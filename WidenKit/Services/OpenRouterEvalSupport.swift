import CryptoKit
import Foundation

public enum OpenRouterCapabilitySource: String, Codable, Equatable, Sendable {
    case authenticatedCatalog
    case singleModelLookup
    case staleCache
    case conservativeDefault
    /// Fixed in a cloud model profile; never written to the catalog cache.
    case staticProfile
}

struct OpenRouterModelCapabilitiesLookup: Equatable, Sendable {
    var capabilities: CloudModelCapabilities
    var httpRequestCount: Int
}

public struct OpenRouterPricing: Codable, Equatable, Sendable {
    public var prompt: String?
    public var completion: String?
    public var request: String?
    public var image: String?
}

public struct OpenRouterModelMetadata: Codable, Identifiable, Equatable, Sendable {
    public var requestedID: String
    public var id: String
    public var canonicalModelID: String?
    public var displayName: String
    public var contextLength: Int?
    public var maximumCompletionTokens: Int?
    public var supportedParameters: [String]
    public var pricing: OpenRouterPricing?
    public var expiration: String?
    public var isAvailableToAPIKey: Bool
    public var capabilitySource: OpenRouterCapabilitySource
    public var fetchedAt: Date

    public var capabilities: CloudModelCapabilities {
        let parameters = Set(supportedParameters.map { $0.lowercased() })
        return CloudModelCapabilities(
            supportsResponseFormat: parameters.contains("response_format"),
            supportsStructuredOutputs: parameters.contains("structured_outputs"),
            supportsTools: parameters.contains("tools"),
            supportsToolChoice: parameters.contains("tool_choice"),
            supportsTemperature: parameters.contains("temperature"),
            supportsSeed: parameters.contains("seed"),
            supportsMaxTokens: parameters.contains("max_tokens"),
            supportsMaxCompletionTokens: parameters.contains("max_completion_tokens"),
            contextLength: contextLength,
            maximumCompletionTokens: maximumCompletionTokens,
            capabilitySource: capabilitySource,
            fetchedAt: fetchedAt,
            canonicalModelID: canonicalModelID
        )
    }
}

enum OpenRouterCanonicalModelValidator {
    /// True when positively-sourced catalog metadata reports a canonical
    /// version other than the pinned expectation. Shared by the preflight
    /// check and the Settings rollover warning so the two cannot drift.
    static func canonicalHasRolled(
        catalogCanonicalModelID: String?,
        capabilitySource: OpenRouterCapabilitySource,
        expectedCanonicalModelID: String?
    ) -> Bool {
        guard let expectedCanonicalModelID,
            let catalogCanonicalModelID,
            capabilitySource == .authenticatedCatalog
                || capabilitySource == .singleModelLookup
        else { return false }
        return catalogCanonicalModelID != expectedCanonicalModelID
    }

    /// Fails fast on a canonical-version rollover using already-fetched
    /// catalog metadata, before any billed completion request. Only enforced
    /// when the catalog positively reports the canonical version; stale or
    /// conservative metadata defers to the post-response check.
    static func preflight(
        catalogCanonicalModelID: String?,
        capabilitySource: OpenRouterCapabilitySource,
        expectedCanonicalModelID: String?,
        requestedModelID: String
    ) throws {
        guard canonicalHasRolled(
            catalogCanonicalModelID: catalogCanonicalModelID,
            capabilitySource: capabilitySource,
            expectedCanonicalModelID: expectedCanonicalModelID
        ) else { return }
        throw CloudRequestFailure(
            category: .modelVersionMismatch,
            message: "OpenRouter reports the fixed model now resolves to an unevaluated version. Update Widen before using this cloud model.",
            requestedModelID: requestedModelID,
            returnedModelID: catalogCanonicalModelID,
            attemptCount: 0
        )
    }

    static func validate(
        returnedModelID: String?,
        routerMetadata: OpenRouterRouterMetadata?,
        expectedCanonicalModelID: String?,
        requestedModelID: String,
        httpStatus: Int?,
        completionID: String?,
        requestID: String?,
        providerName: String?,
        attemptCount: Int
    ) throws {
        guard let expectedCanonicalModelID else { return }
        let routerEvidenceMatches = routerMetadata.map {
            $0.requested == requestedModelID
                && $0.selectedModelID == expectedCanonicalModelID
        }
        let hasConflictingRouterEvidence =
            routerMetadata != nil && routerEvidenceMatches != true
        let returnedModelMatches =
            returnedModelID == expectedCanonicalModelID
            || (returnedModelID == requestedModelID && routerEvidenceMatches == true)
        guard !hasConflictingRouterEvidence, returnedModelMatches else {
            let message =
                hasConflictingRouterEvidence
                ? "OpenRouter reported conflicting model-version metadata, so Widen cannot confirm which version served this request. Try again, and update Widen if this persists."
                : returnedModelID == nil
                    ? "OpenRouter did not report which model version served this request, so Widen cannot confirm it matches the evaluated version. Try again, and update Widen if this persists."
                    : "OpenRouter resolved the fixed model to an unevaluated version. Update Widen before using this cloud model."
            throw CloudRequestFailure(
                category: .modelVersionMismatch,
                message: message,
                httpStatus: httpStatus,
                completionID: completionID,
                requestID: requestID,
                requestedModelID: requestedModelID,
                returnedModelID: returnedModelID,
                providerName: providerName,
                attemptCount: attemptCount
            )
        }
    }
}

enum OpenRouterJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: OpenRouterJSONValue])
    case array([OpenRouterJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenRouterJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([OpenRouterJSONValue].self))
        }
    }
}

/// Holds the eval-only catalog services, one per OpenRouter base URL.
private final class OpenRouterCatalogServiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [URL: OpenRouterModelCatalogService] = [:]

    func service(for profile: CloudModelProfile) -> OpenRouterModelCatalogService {
        lock.withLock {
            if let service = services[profile.baseURL] {
                return service
            }
            let service = OpenRouterModelCatalogService(profile: profile)
            services[profile.baseURL] = service
            return service
        }
    }
}

private final class OpenRouterRefreshWaiterState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func releaseOnce() -> Bool {
        lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
    }
}

actor OpenRouterModelCatalogService {
    private static let evalRegistry = OpenRouterCatalogServiceRegistry()

    /// The shared catalog for an OpenRouter eval profile, one per base URL.
    /// Every other profile gets nil, so no other provider's key can reach the
    /// OpenRouter catalog.
    static func evalShared(for profile: CloudModelProfile) -> OpenRouterModelCatalogService? {
        guard profile.provider == .openRouter,
            profile.capabilityResolution == .openRouterCatalog
        else { return nil }
        return evalRegistry.service(for: profile)
    }

    private struct CacheFile: Codable {
        var entries: [String: CachedCatalog]
    }

    private struct CachedCatalog: Codable {
        var fetchedAt: Date
        var models: [OpenRouterModelMetadata]
    }

    private struct CanonicalMismatchMemoKey: Hashable {
        var apiKeyFingerprint: String
        var requestedModelID: String
        var expectedCanonicalModelID: String
    }

    private struct CanonicalMismatchSnapshot: Equatable {
        var fetchedAt: Date
        var canonicalModelID: String?
        var capabilitySource: OpenRouterCapabilitySource

        init(capabilities: CloudModelCapabilities) {
            fetchedAt = capabilities.fetchedAt
            canonicalModelID = capabilities.canonicalModelID
            capabilitySource = capabilities.capabilitySource
        }
    }

    private struct CatalogResponse: Decodable {
        let data: [Model]
    }

    private struct SingleModelResponse: Decodable {
        let data: Model
    }

    private struct Model: Decodable {
        struct Provider: Decodable {
            let contextLength: Int?
            let maxCompletionTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case contextLength = "context_length"
                case maxCompletionTokens = "max_completion_tokens"
            }
        }

        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
            let request: String?
            let image: String?
        }

        let id: String
        let canonicalSlug: String?
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?
        let pricing: Pricing?
        let expirationDate: String?
        let topProvider: Provider?

        private enum CodingKeys: String, CodingKey {
            case id
            case canonicalSlug = "canonical_slug"
            case name
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
            case pricing
            case expirationDate = "expiration_date"
            case topProvider = "top_provider"
        }

        func metadata(
            requestedID: String,
            available: Bool,
            source: OpenRouterCapabilitySource,
            fetchedAt: Date
        ) -> OpenRouterModelMetadata {
            OpenRouterModelMetadata(
                requestedID: requestedID,
                id: id,
                canonicalModelID: canonicalSlug,
                displayName: name ?? id,
                contextLength: topProvider?.contextLength ?? contextLength,
                maximumCompletionTokens: topProvider?.maxCompletionTokens,
                supportedParameters: supportedParameters ?? [],
                pricing: pricing.map {
                    OpenRouterPricing(
                        prompt: $0.prompt,
                        completion: $0.completion,
                        request: $0.request,
                        image: $0.image
                    )
                },
                expiration: expirationDate,
                isAvailableToAPIKey: available,
                capabilitySource: source,
                fetchedAt: fetchedAt
            )
        }
    }

    private let profile: CloudModelProfile
    private let transport: any HTTPTransport
    private let cacheURL: URL
    private let ttl: TimeInterval
    private let staleRetention: TimeInterval
    private var memoryCache: [String: CachedCatalog] = [:]
    private var refreshTasks: [String: Task<CachedCatalog, Error>] = [:]
    private var refreshWaiterCounts: [String: Int] = [:]
    private var confirmedCanonicalMismatches: [
        CanonicalMismatchMemoKey: CanonicalMismatchSnapshot
    ] = [:]

    /// Requests go to the profile's base URL and are signed by the profile.
    /// The cache lives under the WidenEval caches folder, never in the app's
    /// Application Support folder.
    init(
        profile: CloudModelProfile,
        transport: (any HTTPTransport)? = nil,
        cacheURL: URL? = nil,
        ttl: TimeInterval = 6 * 60 * 60,
        staleRetention: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.profile = profile
        self.transport = transport ?? URLSessionTransport(timeoutsOf: profile)
        self.ttl = ttl
        self.staleRetention = staleRetention
        let directory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WidenEval", isDirectory: true)
        self.cacheURL =
            cacheURL
            ?? directory.appendingPathComponent("openrouter-model-catalog-cache.json")
    }

    func availableModels(apiKey: String, forceRefresh: Bool = false) async throws
        -> [OpenRouterModelMetadata]
    {
        try await catalog(apiKey: apiKey, forceRefresh: forceRefresh).models
    }

    func metadata(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool = false,
        allowStaleFallback: Bool = true
    ) async -> OpenRouterModelMetadata? {
        do {
            return try await lookupModel(apiKey: apiKey, modelID: modelID, forceRefresh: forceRefresh)
        } catch is CancellationError {
            return nil
        } catch {
            guard allowStaleFallback else { return nil }
            return staleCatalog(apiKey: apiKey)
                .map(staleCatalogWithSource)
                .flatMap { Self.find(modelID, in: $0.models) }
        }
    }

    /// Settings-facing lookup that rethrows the underlying catalog failure so
    /// the UI can say why metadata is unavailable, instead of a generic
    /// message. Transient failures still fall back to a stale cache entry;
    /// authentication and other non-servable failures propagate. The full
    /// catalog fetch is intentional even for a single pinned model: catalog
    /// membership is what proves the model is visible to the saved key.
    func metadataSurfacingErrors(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool = false
    ) async throws -> OpenRouterModelMetadata? {
        do {
            return try await lookupModel(apiKey: apiKey, modelID: modelID, forceRefresh: forceRefresh)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if canServeStaleCatalog(after: error),
                let stale = staleCatalog(apiKey: apiKey)
                    .map(staleCatalogWithSource)
                    .flatMap({ Self.find(modelID, in: $0.models) })
            {
                return stale
            }
            throw error
        }
    }

    /// The shared model-lookup flow: fresh catalog membership first, then
    /// the single-model endpoint. Both public lookups wrap this with their
    /// distinct error handling so Settings and generation cannot drift.
    /// `metadataWithUsage` keeps a budget-gated variant of the same sequence
    /// for counted eval lookups; changes here should be mirrored there.
    private func lookupModel(
        apiKey: String,
        modelID: String,
        forceRefresh: Bool
    ) async throws -> OpenRouterModelMetadata? {
        let catalog = try await catalog(apiKey: apiKey, forceRefresh: forceRefresh)
        if let model = Self.find(modelID, in: catalog.models) {
            return model
        }
        if let single = try await fetchSingleModel(apiKey: apiKey, modelID: modelID) {
            merge(single, apiKey: apiKey)
            return single
        }
        return nil
    }

    func capabilitiesForGeneration(apiKey: String, modelID: String) async
        -> CloudModelCapabilities
    {
        guard let metadata = await metadata(apiKey: apiKey, modelID: modelID) else {
            return .conservative()
        }
        return metadata.capabilities
    }

    func capabilitiesForGeneration(
        apiKey: String,
        modelID: String,
        maximumHTTPRequests: Int?
    ) async -> OpenRouterModelCapabilitiesLookup {
        let result = await metadataWithUsage(
            apiKey: apiKey,
            modelID: modelID,
            maximumHTTPRequests: maximumHTTPRequests
        )
        return OpenRouterModelCapabilitiesLookup(
            capabilities: result.metadata?.capabilities ?? .conservative(),
            httpRequestCount: result.httpRequestCount
        )
    }

    /// Resolves capabilities and enforces the pinned canonical version before
    /// a billed completion. A cache written before an app update can hold the
    /// previous canonical version for the cache TTL, so an unconfirmed cached
    /// mismatch refetches once. A mismatch already confirmed for the same
    /// catalog snapshot fails without another refetch. Lookup HTTP attempts
    /// are carried in the returned lookup and on the thrown failure.
    func validatedCapabilitiesForGeneration(
        apiKey: String,
        modelID: String,
        expectedCanonicalModelID: String?,
        maximumHTTPRequests: Int?
    ) async throws -> OpenRouterModelCapabilitiesLookup {
        let memoKey = expectedCanonicalModelID.map {
            CanonicalMismatchMemoKey(
                apiKeyFingerprint: Self.apiKeyFingerprint(apiKey),
                requestedModelID: modelID,
                expectedCanonicalModelID: $0
            )
        }
        for pass in 0..<2 {
            let lookup = await capabilitiesForGeneration(
                apiKey: apiKey,
                modelID: modelID,
                maximumHTTPRequests: maximumHTTPRequests
            )
            do {
                try OpenRouterCanonicalModelValidator.preflight(
                    catalogCanonicalModelID: lookup.capabilities.canonicalModelID,
                    capabilitySource: lookup.capabilities.capabilitySource,
                    expectedCanonicalModelID: expectedCanonicalModelID,
                    requestedModelID: modelID
                )
                if let memoKey {
                    confirmedCanonicalMismatches[memoKey] = nil
                }
                return lookup
            } catch let failure as CloudRequestFailure
                where failure.category == .modelVersionMismatch
            {
                let snapshot = CanonicalMismatchSnapshot(capabilities: lookup.capabilities)
                let wasNetworkFresh = lookup.httpRequestCount > 0
                let alreadyConfirmed = memoKey.map {
                    confirmedCanonicalMismatches[$0] == snapshot
                } ?? false

                // A network-fresh mismatch is authoritative. The second pass
                // follows an explicit cache invalidation, so it also confirms
                // the replacement snapshot even if it joined another refresh.
                if wasNetworkFresh || alreadyConfirmed || pass == 1 {
                    if let memoKey, (wasNetworkFresh || pass == 1) {
                        confirmedCanonicalMismatches[memoKey] = snapshot
                    }
                    throw lookup.httpRequestCount > 0
                        ? failure.withAttemptCount(lookup.httpRequestCount)
                        : failure
                }

                // Only an unconfirmed cache-served mismatch reaches here.
                // Invalidating before the second pass preserves the one-time
                // recovery for a cache written by an older app version.
                invalidate(apiKey: apiKey, modelID: modelID)
            }
        }
        preconditionFailure("Canonical model validation exceeded its bounded retry.")
    }

    func invalidate(apiKey: String? = nil, modelID: String? = nil) {
        loadDiskCacheIfNeeded()
        if let apiKey {
            let key = Self.apiKeyFingerprint(apiKey)
            confirmedCanonicalMismatches = confirmedCanonicalMismatches.filter { entry in
                let memoMatchesModel = modelID.map { invalidatedModelID in
                    invalidatedModelID == entry.key.requestedModelID
                        || invalidatedModelID == entry.value.canonicalModelID
                } ?? true
                return entry.key.apiKeyFingerprint != key || !memoMatchesModel
            }
            if modelID == nil {
                memoryCache.removeValue(forKey: key)
            } else if var cached = memoryCache[key] {
                cached.models.removeAll {
                    $0.requestedID == modelID || $0.id == modelID || $0.canonicalModelID == modelID
                }
                cached.fetchedAt = Date(timeIntervalSince1970: 0)
                memoryCache[key] = cached
            }
        } else {
            memoryCache.removeAll()
            confirmedCanonicalMismatches.removeAll()
        }
        writeDiskCache()
    }

    private func catalog(apiKey: String, forceRefresh: Bool) async throws -> CachedCatalog {
        let key = Self.apiKeyFingerprint(apiKey)
        loadDiskCacheIfNeeded()
        if !forceRefresh, let cached = memoryCache[key], isFresh(cached) {
            return cached
        }
        if let task = refreshTasks[key] {
            let value = try await refreshValue(task, key: key)
            try Task.checkCancellation()
            return value
        }
        let task = Task<CachedCatalog, Error> {
            let fetched = try await fetchCatalog(apiKey: apiKey)
            store(fetched, key: key)
            return fetched
        }
        refreshTasks[key] = task
        do {
            let value = try await refreshValue(task, key: key)
            try Task.checkCancellation()
            if refreshTasks[key] == task {
                refreshTasks[key] = nil
            }
            return value
        } catch {
            if refreshTasks[key] == task {
                refreshTasks[key] = nil
            }
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if canServeStaleCatalog(after: error), let stale = staleCatalog(apiKey: apiKey) {
                return staleCatalogWithSource(stale)
            }
            throw error
        }
    }

    private func metadataWithUsage(
        apiKey: String,
        modelID: String,
        maximumHTTPRequests: Int?
    ) async -> (metadata: OpenRouterModelMetadata?, httpRequestCount: Int) {
        var httpRequestCount = 0
        do {
            let shouldRequestCatalog = catalogLookupWillRequestHTTP(
                apiKey: apiKey,
                forceRefresh: false
            )
            if shouldRequestCatalog {
                guard maximumHTTPRequests.map({ httpRequestCount < $0 }) ?? true else {
                    return (nil, httpRequestCount)
                }
                httpRequestCount += 1
            }
            let catalog = try await catalog(apiKey: apiKey, forceRefresh: false)
            if let model = Self.find(modelID, in: catalog.models) {
                return (model, httpRequestCount)
            }
            guard maximumHTTPRequests.map({ httpRequestCount < $0 }) ?? true else {
                return (nil, httpRequestCount)
            }
            httpRequestCount += 1
            if let single = try await fetchSingleModel(apiKey: apiKey, modelID: modelID) {
                merge(single, apiKey: apiKey)
                return (single, httpRequestCount)
            }
            return (nil, httpRequestCount)
        } catch is CancellationError {
            return (nil, httpRequestCount)
        } catch {
            return (
                staleCatalog(apiKey: apiKey)
                    .map(staleCatalogWithSource)
                    .flatMap { Self.find(modelID, in: $0.models) },
                httpRequestCount
            )
        }
    }

    private func catalogLookupWillRequestHTTP(apiKey: String, forceRefresh: Bool) -> Bool {
        guard !forceRefresh else { return true }
        let key = Self.apiKeyFingerprint(apiKey)
        loadDiskCacheIfNeeded()
        guard let cached = memoryCache[key], isFresh(cached) else { return true }
        return false
    }

    private func refreshValue(
        _ task: Task<CachedCatalog, Error>,
        key: String
    ) async throws -> CachedCatalog {
        refreshWaiterCounts[key, default: 0] += 1
        let waiterState = OpenRouterRefreshWaiterState()
        defer {
            if waiterState.releaseOnce() {
                releaseRefreshWaiter(key: key, task: task, cancelIfUnused: false)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { [waiterState] in
                if waiterState.releaseOnce() {
                    await releaseRefreshWaiter(key: key, task: task, cancelIfUnused: true)
                }
            }
        }
    }

    private func releaseRefreshWaiter(
        key: String,
        task: Task<CachedCatalog, Error>,
        cancelIfUnused: Bool
    ) {
        let remaining = max(0, (refreshWaiterCounts[key] ?? 1) - 1)
        if remaining == 0 {
            refreshWaiterCounts[key] = nil
            if cancelIfUnused {
                task.cancel()
                if refreshTasks[key] == task {
                    refreshTasks[key] = nil
                }
            }
        } else {
            refreshWaiterCounts[key] = remaining
        }
    }

    private func fetchCatalog(apiKey: String) async throws -> CachedCatalog {
        let request = try profile.authorizedRequest(
            profile.baseURL.appendingPathComponent("models/user"),
            apiKey: apiKey,
            httpMethod: "GET"
        )
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CloudSQLResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: nil,
                attemptCount: 1,
                profile: profile
            )
        }
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
        let fetchedAt = Date()
        return CachedCatalog(
            fetchedAt: fetchedAt,
            models: decoded.data.map {
                $0.metadata(
                    requestedID: $0.id,
                    available: true,
                    source: .authenticatedCatalog,
                    fetchedAt: fetchedAt
                )
            }
        )
    }

    private func fetchSingleModel(
        apiKey: String,
        modelID: String
    ) async throws
        -> OpenRouterModelMetadata?
    {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var request = try profile.authorizedRequest(
            profile.baseURL
                .appendingPathComponent("model")
                .appendingPathComponent(parts[0])
                .appendingPathComponent(parts[1]),
            apiKey: apiKey,
            httpMethod: "GET"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { return nil }
            throw CloudSQLResponseParser.failure(
                from: data,
                response: response,
                requestedModelID: modelID,
                attemptCount: 1,
                profile: profile
            )
        }
        let decoded = try JSONDecoder().decode(SingleModelResponse.self, from: data)
        let fetchedAt = Date()
        return decoded.data.metadata(
            requestedID: modelID,
            available: false,
            source: .singleModelLookup,
            fetchedAt: fetchedAt
        )
    }

    private func merge(_ metadata: OpenRouterModelMetadata, apiKey: String) {
        let key = Self.apiKeyFingerprint(apiKey)
        var cached = memoryCache[key] ?? CachedCatalog(fetchedAt: Date(), models: [])
        let matchingIDs = Set([metadata.requestedID, metadata.id, metadata.canonicalModelID].compactMap { $0 })
        cached.models.removeAll {
            matchingIDs.contains($0.requestedID)
                || matchingIDs.contains($0.id)
                || $0.canonicalModelID.map(matchingIDs.contains) == true
        }
        cached.models.append(metadata)
        memoryCache[key] = cached
        writeDiskCache()
    }

    private func store(_ catalog: CachedCatalog, key: String) {
        memoryCache[key] = catalog
        writeDiskCache()
    }

    private func staleCatalog(apiKey: String) -> CachedCatalog? {
        loadDiskCacheIfNeeded()
        let key = Self.apiKeyFingerprint(apiKey)
        guard let cached = memoryCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.fetchedAt) <= staleRetention else { return nil }
        return cached
    }

    private func staleCatalogWithSource(_ catalog: CachedCatalog) -> CachedCatalog {
        CachedCatalog(
            fetchedAt: catalog.fetchedAt,
            models: catalog.models.map { model in
                var copy = model
                copy.capabilitySource = .staleCache
                return copy
            }
        )
    }

    private func canServeStaleCatalog(after error: any Error) -> Bool {
        if let failure = error as? CloudRequestFailure {
            switch failure.category {
            case .rateLimited, .providerOverloaded, .providerUnavailable, .timeout,
                .networkTransport, .serverFailure:
                return true
            case .authentication, .paymentRequired, .providerLimit, .permissionDenied,
                .guardrailBlocked, .modelNotFound, .modelVersionMismatch, .invalidRequest,
                .unsupportedFeature, .contextWindow, .maxTokensExceeded, .contentPolicy, .refusal, .noContent,
                .malformedStructuredResponse:
                return false
            }
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return false
    }

    private func isFresh(_ catalog: CachedCatalog) -> Bool {
        Date().timeIntervalSince(catalog.fetchedAt) <= ttl
    }

    private func loadDiskCacheIfNeeded() {
        guard memoryCache.isEmpty else { return }
        guard let data = try? Data(contentsOf: cacheURL),
            let decoded = try? JSONDecoder.widenOpenRouter.decode(CacheFile.self, from: data)
        else { return }
        memoryCache = decoded.entries.filter {
            Date().timeIntervalSince($0.value.fetchedAt) <= staleRetention
        }
    }

    private func writeDiskCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.widenOpenRouter.encode(CacheFile(entries: memoryCache))
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            // Cache failures must not break generation.
        }
    }

    private static func find(_ id: String, in models: [OpenRouterModelMetadata])
        -> OpenRouterModelMetadata?
    {
        models.first {
            $0.requestedID == id || $0.id == id || $0.canonicalModelID == id
        }
    }

    static func apiKeyFingerprint(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The only writer of the request `provider` block: every OpenRouter
/// completion demands endpoints with zero data retention, no provider data
/// collection, and full request-parameter support.
enum OpenRouterProviderPreferences {
    static let requireParameters = true
    static let zdr = true
    static let dataCollection = "deny"

    /// The one user-facing sentence describing the private routing Widen
    /// enforces on every OpenRouter completion. Interpolated by every view
    /// that makes this claim so the wording cannot drift; keep aligned with
    /// PRIVACY.md and the provider block below.
    static let privateRoutingClaim =
        "Widen requires OpenRouter endpoints that do not retain or collect the submitted question and schema context."

    static func apply(to body: inout [String: Any]) {
        body["provider"] = [
            "require_parameters": requireParameters,
            "zdr": zdr,
            "data_collection": dataCollection,
        ]
    }
}

struct OpenRouterRouterMetadata: Decodable, Equatable, Sendable {
    struct Endpoints: Decodable, Equatable, Sendable {
        struct Endpoint: Decodable, Equatable, Sendable {
            let provider: String?
            let model: String?
            let selected: Bool?
        }

        let available: [Endpoint]?
    }

    let requested: String?
    let summary: String?
    let attempt: Int?
    let endpoints: Endpoints?

    private var selectedEndpoint: Endpoints.Endpoint? {
        guard let selected = endpoints?.available?.filter({ $0.selected == true }),
            selected.count == 1
        else { return nil }
        return selected[0]
    }

    var selectedProvider: String? {
        selectedEndpoint?.provider
    }

    var selectedModelID: String? {
        selectedEndpoint?.model
    }
}

extension CloudSQLResponseParser {
    /// OpenRouter routing failures for provider data-policy preferences (ZDR,
    /// data collection) arrive as generic 404/503 messages; detect them so
    /// the user sees why generation failed closed. Keep the match specific to
    /// data-policy wording — generic "no endpoints" messages also cover model
    /// delisting and provider outages, which are not privacy failures.
    static func isProviderRoutingPolicyMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("data policy")
            || lower.contains("data collection")
            || lower.contains("zero data retention")
            || lower.contains("zdr")
            // require_parameters is the third enforced routing preference;
            // its rejections are worded around unsupported parameters.
            || lower.contains("requested parameters")
    }

    /// OpenRouter reports an exhausted key/credit limit as plain message text
    /// without a typed code; detect it so eval runs count it as
    /// budget-unavailable rather than permission denied.
    static func isKeyOrCreditLimitMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("key limit exceeded")
            || lower.contains("credit limit")
            || lower.contains("insufficient credits")
            || lower.contains("spend limit")
    }
}

private extension JSONEncoder {
    static var widenOpenRouter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var widenOpenRouter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
