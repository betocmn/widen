import Foundation

public enum TextToSQLEvalDefaults {
    /// The model a text-to-SQL eval runs when `--model` is not passed.
    public static let requestedModelID = CloudModelProfile.particle.requestedModelID

    /// The per-case eval timeout. One case can run the first generation, the
    /// validation repairs that share its model-call budget, and a verification
    /// repair, each bounded by the agent wall clock. This stays well above
    /// their sum, so an eval timeout never cuts off an agent that is still
    /// within its own limits.
    public static let caseTimeoutSeconds: Double = 1_200
}

public enum TextToSQLEvalCloudSettingsError: LocalizedError, Equatable, Sendable {
    case unknownModel(String)
    case reasoningEffortUnsupported(model: String, provider: String)
    case unknownReasoningEffort(String)

    public var errorDescription: String? {
        let particle = CloudModelProfile.particle.requestedModelID
        switch self {
        case .unknownModel(let model):
            let example = CloudModelProfile.openRouterGPT55.requestedModelID
            return "Unknown eval model \"\(model)\": use \(particle) for Particle-1, or an OpenRouter vendor/model ID such as \(example) for a comparison run."
        case .reasoningEffortUnsupported(let model, let provider):
            return "--reasoning-effort is not supported for \(model): its \(provider) requests send no reasoning_effort. Use it with \(particle)."
        case .unknownReasoningEffort(let value):
            return "Previous run has unknown reasoning effort \(value)."
        }
    }
}

/// The cloud profile one text-to-SQL eval run sends its requests with. The
/// provider is inferred from the requested model, so there is no provider
/// flag, and the run reads only that provider's API key variable.
public struct TextToSQLEvalCloudSettings: Equatable, Sendable {
    /// The profile for the requested model, with any reasoning-effort
    /// override already applied.
    public let profile: CloudModelProfile
    /// The eval-only `--reasoning-effort`, if the run passed one.
    public let reasoningEffortOverride: ReasoningEffort?

    public init(
        requestedModelID: String,
        reasoningEffortOverride: ReasoningEffort? = nil
    ) throws {
        guard var profile = CloudModelCatalog.profile(forRequestedModelID: requestedModelID) else {
            throw TextToSQLEvalCloudSettingsError.unknownModel(requestedModelID)
        }
        if let reasoningEffortOverride {
            guard profile.supportsReasoningEffort else {
                throw TextToSQLEvalCloudSettingsError.reasoningEffortUnsupported(
                    model: requestedModelID,
                    provider: profile.provider.displayName
                )
            }
            profile = profile.overridingReasoningEffort(reasoningEffortOverride)
        }
        self.profile = profile
        self.reasoningEffortOverride = reasoningEffortOverride
    }

    /// The provider as the run manifest records it.
    public var provider: String {
        Self.manifestName(for: profile.provider)
    }

    public var endpointHost: String? {
        profile.baseURL.host
    }

    /// The `reasoning_effort` sent from `callSite`, or nil when none is sent.
    public func reasoningEffort(for callSite: CloudCallSite) -> String? {
        profile.policy(for: callSite).reasoningEffort?.rawValue
    }

    /// Reads only this profile's own variable.
    public func apiKey(in environment: [String: String]) -> String? {
        profile.evalAPIKey(in: environment)
    }

    public var missingAPIKeyMessage: String {
        "\(profile.evalAPIKeyEnvironmentVariable) is not set."
    }

    /// `"particle"` or `"openrouter"`.
    public static func manifestName(for provider: CloudModelProviderID) -> String {
        switch provider {
        case .particle: "particle"
        case .openRouter: "openrouter"
        }
    }

    /// The provider a manifest name stands for, or nil for an unknown name.
    public static func providerID(forManifestName name: String) -> CloudModelProviderID? {
        CloudModelProviderID.allCases.first { manifestName(for: $0) == name }
    }

    /// The provider of a run manifest. Manifests written before providers
    /// were recorded have none, and every cloud run then used OpenRouter.
    public static func resolvedManifestProvider(
        _ provider: String?,
        backendMode: String
    ) -> String? {
        if let provider { return provider }
        let includedCloud = backendMode == TextToSQLEvalBackend.cloud.rawValue
            || backendMode == "both"
        return includedCloud ? manifestName(for: .openRouter) : nil
    }

    /// The override a resumed run inherits from the reasoning effort its
    /// manifest recorded for `callSite`. The profile's own default is not an
    /// override, so resuming a default run never looks like one to the
    /// release gate. A profile that sends no effort inherits none, which
    /// leaves the mismatch to the resume compatibility check.
    public static func resumedReasoningEffortOverride(
        previousReasoningEffort: String?,
        requestedModelID: String,
        callSite: CloudCallSite
    ) throws -> ReasoningEffort? {
        guard let previousReasoningEffort else { return nil }
        guard let effort = ReasoningEffort(rawValue: previousReasoningEffort) else {
            throw TextToSQLEvalCloudSettingsError.unknownReasoningEffort(previousReasoningEffort)
        }
        guard let profile = CloudModelCatalog.profile(forRequestedModelID: requestedModelID),
            profile.supportsReasoningEffort,
            profile.policy(for: callSite).reasoningEffort != effort
        else { return nil }
        return effort
    }
}
