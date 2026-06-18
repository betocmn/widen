import Foundation

/// Runtime eligibility for Apple's on-device Foundation Model. The app can
/// run without this being ready, but Local mode cannot.
public enum LocalLLMEligibility: Equatable, Sendable {
    case ready
    case deviceNotEligible(String)
    case appleIntelligenceDisabled
    case modelNotReady(String)
    case sdkUnavailable(String)
    case unavailable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .ready:
            return "The on-device model is ready."
        case .deviceNotEligible(let detail):
            return "This Mac does not support Apple Intelligence. You can still use Widen with a cloud model by setting up an API key in Settings › LLM. \(detail)"
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is turned off. To use Widen's local model, enable Apple Intelligence in System Settings › Apple Intelligence & Siri, then reopen Widen or try Local again."
        case .modelNotReady(let detail):
            return "The local Apple model is not ready yet. \(detail)"
        case .sdkUnavailable(let detail):
            return "This build does not include Apple's Foundation Models framework. Use a cloud model or rebuild with Xcode/macOS SDK support for Foundation Models. \(detail)"
        case .unavailable(let detail):
            return "The local Apple model is unavailable. \(detail)"
        }
    }
}

public enum LocalLLMEligibilityChecker {
    public static func status() -> LocalLLMEligibility {
        #if canImport(FoundationModels)
            return FoundationModelsAvailability.status()
        #else
            return .sdkUnavailable(
                "The FoundationModels framework is not available to this build.")
        #endif
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    enum FoundationModelsAvailability {
        static func status() -> LocalLLMEligibility {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .deviceNotEligible("This device is not eligible for Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .appleIntelligenceDisabled
                case .modelNotReady:
                    return .modelNotReady(
                        "The model may still be downloading or preparing. Check Apple Intelligence in System Settings and try again."
                    )
                @unknown default:
                    return .unavailable("The local model is unavailable for an unknown reason.")
                }
            }
        }
    }
#endif
