import Foundation

/// The OpenRouter model/version pair evaluated for production SQL generation.
public struct OpenRouterProductionProfile: Equatable, Sendable {
    public let requestedModelID: String
    public let expectedCanonicalModelID: String
    public let displayName: String

    public init(
        requestedModelID: String,
        expectedCanonicalModelID: String,
        displayName: String
    ) {
        self.requestedModelID = requestedModelID
        self.expectedCanonicalModelID = expectedCanonicalModelID
        self.displayName = displayName
    }
}

/// The fixed OpenRouter production profile. Changing either model ID requires
/// a new release-gate evaluation and an app update.
public enum OpenRouterCatalog {
    public static let productionProfile = OpenRouterProductionProfile(
        requestedModelID: "openai/gpt-5.6-sol",
        expectedCanonicalModelID: "openai/gpt-5.6-sol-20260709",
        displayName: "GPT-5.6 Sol"
    )

    /// The canonical version to enforce for a requested model ID. Evals may
    /// run arbitrary models, but when they run the pinned production model
    /// they must enforce the same canonical-version contract as the app.
    public static func expectedCanonicalModelID(forRequestedModelID id: String) -> String? {
        id == productionProfile.requestedModelID
            ? productionProfile.expectedCanonicalModelID
            : nil
    }
}

/// One network observation of the production alias-to-canonical mapping.
public struct OpenRouterCanonicalVersionObservation: Equatable, Sendable {
    public let requestedModelID: String
    public let expectedCanonicalModelID: String
    public let observedCanonicalModelID: String

    public var hasDrift: Bool {
        observedCanonicalModelID != expectedCanonicalModelID
    }
}

/// Fail-closed reasons that are not evidence of a canonical-version rollover.
public enum OpenRouterProductionCanonicalWatchError: Error, Equatable, Sendable {
    case requestedModelNotFound(String)
    case unexpectedRequestedModel(String)
    case canonicalModelMissing(String)
    case canonicalModelInvalid(String)
    case catalogLookupFailed(String)
}

extension OpenRouterProductionCanonicalWatchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestedModelNotFound(let requestedModelID):
            "OpenRouter's catalog did not return the production alias \(requestedModelID)."
        case .unexpectedRequestedModel(let requestedModelID):
            "OpenRouter returned an unexpected model for the production alias \(requestedModelID)."
        case .canonicalModelMissing(let requestedModelID):
            "OpenRouter's catalog omitted canonical_slug for \(requestedModelID)."
        case .canonicalModelInvalid(let requestedModelID):
            "OpenRouter's catalog returned an invalid canonical_slug for \(requestedModelID)."
        case .catalogLookupFailed(let requestedModelID):
            "OpenRouter's catalog lookup failed for \(requestedModelID)."
        }
    }
}

/// Checks the public single-model catalog endpoint without a completion,
/// credential, Widen cache, or stale fallback. Only a fully validated
/// canonical ID mismatch is classified as drift; every other anomaly throws.
public enum OpenRouterProductionCanonicalWatch {
    public static func check() async throws -> OpenRouterCanonicalVersionObservation {
        let catalogService = OpenRouterModelCatalogService(
            transport: URLSessionTransport(timeout: 30)
        )
        return try await check(catalogService: catalogService)
    }

    static func check(
        catalogService: OpenRouterModelCatalogService
    ) async throws -> OpenRouterCanonicalVersionObservation {
        let profile = OpenRouterCatalog.productionProfile
        let metadata: OpenRouterModelMetadata?
        do {
            metadata = try await catalogService.freshPublicModel(
                modelID: profile.requestedModelID
            )
        } catch {
            throw OpenRouterProductionCanonicalWatchError.catalogLookupFailed(
                profile.requestedModelID
            )
        }
        guard let metadata else {
            throw OpenRouterProductionCanonicalWatchError.requestedModelNotFound(
                profile.requestedModelID
            )
        }
        guard metadata.id == profile.requestedModelID else {
            throw OpenRouterProductionCanonicalWatchError.unexpectedRequestedModel(
                profile.requestedModelID
            )
        }
        guard let observedCanonicalModelID = metadata.canonicalModelID else {
            throw OpenRouterProductionCanonicalWatchError.canonicalModelMissing(
                profile.requestedModelID
            )
        }
        guard isValidModelID(observedCanonicalModelID) else {
            throw OpenRouterProductionCanonicalWatchError.canonicalModelInvalid(
                profile.requestedModelID
            )
        }
        return OpenRouterCanonicalVersionObservation(
            requestedModelID: profile.requestedModelID,
            expectedCanonicalModelID: profile.expectedCanonicalModelID,
            observedCanonicalModelID: observedCanonicalModelID
        )
    }

    private static func isValidModelID(_ value: String) -> Bool {
        guard value.count <= 200 else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:"
        )
        return components.allSatisfy { component in
            component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}
