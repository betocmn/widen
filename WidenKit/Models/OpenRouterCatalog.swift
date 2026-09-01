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
        requestedModelID: "openai/gpt-5.5",
        expectedCanonicalModelID: "openai/gpt-5.5-20260423",
        displayName: "GPT-5.5"
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
