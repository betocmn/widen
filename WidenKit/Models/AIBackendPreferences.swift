import Foundation

/// Which family of model generates SQL. Persisted under "WidenAIBackendMode";
/// the toolbar toggle flips between the two.
public enum AIBackendMode: String, CaseIterable, Sendable {
    case local
    case cloud
}

/// Which cloud provider serves "pro" generations when the backend mode is
/// `.cloud`. Persisted under "WidenCloudAIProvider".
public enum CloudAIProvider: String, CaseIterable, Identifiable, Sendable {
    case applePCC
    case openRouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .applePCC: "Apple Private Cloud Compute"
        case .openRouter: "OpenRouter"
        }
    }
}

/// Whether the chosen cloud backend can actually serve requests right now.
public enum CloudBackendStatus: Equatable, Sendable {
    case ready
    /// The user can fix this in Settings (e.g. a missing API key).
    case notConfigured(String)
    /// Environmental: this build, OS, or machine can't offer the provider.
    case unavailable(String)

    /// nil for `.ready`.
    public var message: String? {
        switch self {
        case .ready: nil
        case .notConfigured(let message), .unavailable(let message): message
        }
    }
}
