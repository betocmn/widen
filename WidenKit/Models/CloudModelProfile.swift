/// The cloud model/version pair evaluated for production SQL generation.
public struct CloudModelProfile: Equatable, Sendable {
    public let requestedModelID: String
    public let expectedReturnedModelID: String
    public let displayName: String

    public init(
        requestedModelID: String,
        expectedReturnedModelID: String,
        displayName: String
    ) {
        self.requestedModelID = requestedModelID
        self.expectedReturnedModelID = expectedReturnedModelID
        self.displayName = displayName
    }
}

/// The fixed cloud production profile. Changing either model ID requires
/// a new release-gate evaluation and an app update.
public enum CloudModelCatalog {
    public static let productionProfile = CloudModelProfile(
        requestedModelID: "openai/gpt-5.5",
        expectedReturnedModelID: "openai/gpt-5.5-20260423",
        displayName: "GPT-5.5"
    )

    /// The returned model version to enforce for a requested model ID. Evals
    /// may run arbitrary models, but when they run the pinned production model
    /// they must enforce the same returned-version contract as the app.
    public static func expectedReturnedModelID(forRequestedModelID id: String) -> String? {
        id == productionProfile.requestedModelID
            ? productionProfile.expectedReturnedModelID
            : nil
    }
}
