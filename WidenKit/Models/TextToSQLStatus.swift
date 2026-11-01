import Foundation

/// Whether text-to-SQL can answer right now. The toolbar chip, the chat
/// empty state and Settings › LLM all read this one status.
public enum TextToSQLStatus: Equatable, Sendable {
    case ready
    /// The developer mock generator answers instead of the model.
    case mock
    /// The user can fix this in Settings, e.g. a missing API key.
    case notConfigured(String)
    /// The provider refused the saved key or account on a real request.
    case unavailable(String)

    /// True when text-to-SQL cannot answer until the user acts.
    public var needsAttention: Bool {
        switch self {
        case .ready, .mock: false
        case .notConfigured, .unavailable: true
        }
    }

    /// nil for `.ready` and `.mock`.
    public var message: String? {
        switch self {
        case .ready, .mock: nil
        case .notConfigured(let message), .unavailable(let message): message
        }
    }

    /// The toolbar chip's title.
    public var chipTitle: String {
        switch self {
        case .mock: "Mock AI"
        case .ready, .notConfigured, .unavailable:
            CloudModelCatalog.productionProfile.displayName
        }
    }
}

/// A failure on a real request that retrying will not fix: Particle rejected
/// the key, the account is out of credits, or the key may not run inference.
/// Kept in memory only, so a relaunch starts again from the saved key.
public enum ParticleRuntimeIssue: Equatable, Sendable {
    case keyRejected
    case outOfCredits
    case inferenceNotAllowed

    init?(category: CloudRequestFailure.Category) {
        switch category {
        case .authentication: self = .keyRejected
        case .paymentRequired: self = .outOfCredits
        case .permissionDenied: self = .inferenceNotAllowed
        default: return nil
        }
    }

    public var message: String {
        switch self {
        case .keyRejected:
            "Particle rejected the saved API key. Re-enter it in Settings › LLM."
        case .outOfCredits:
            "Your Particle account is out of credits. Add credits at platform.particle.ai, then try again."
        case .inferenceNotAllowed:
            "Your Particle API key isn't allowed to run inference. Save a key with inference access in Settings › LLM."
        }
    }
}

/// How one text-to-SQL run ended, as far as the Particle account is concerned.
enum TextToSQLRunOutcome: Equatable, Sendable {
    /// The model answered with SQL or a clarification.
    case answered
    /// The run failed; the category is the provider failure behind it, if any.
    case failed(CloudRequestFailure.Category?)
}
