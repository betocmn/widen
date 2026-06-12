import Foundation

/// Compile- and runtime-gated facade over Apple's Private Cloud Compute
/// model. The rest of the app only touches PCC through this type, so the
/// project builds with both the macOS 26 SDK (Xcode 26, no PCC symbols) and
/// the macOS 27 SDK, and runs on macOS 26 with PCC reported as unavailable.
public enum PCCSupport {
    /// True when built with the macOS 27 SDK (Xcode 27, Swift 6.4+).
    public static var isCompiledIn: Bool {
        #if compiler(>=6.4) && canImport(FoundationModels)
            true
        #else
            false
        #endif
    }

    /// True when the running OS could offer Private Cloud Compute at all.
    public static var isRuntimeSupported: Bool {
        #if compiler(>=6.4) && canImport(FoundationModels)
            if #available(macOS 27.0, *) { return true }
            return false
        #else
            return false
        #endif
    }

    /// nil when Private Cloud Compute is ready to generate; otherwise a
    /// user-readable reason it can't right now.
    public static var availabilityMessage: String? {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *) else {
                return
                    "Apple Private Cloud Compute requires macOS 27. Use OpenRouter on this Mac instead."
            }
            return PrivateCloudComputeSQLGenerator.availabilityMessage
        #else
            return
                "This build was made with the macOS 26 SDK and does not include Private Cloud Compute. Use OpenRouter instead."
        #endif
    }

    /// A blocker when the user has exhausted the daily limit; nil otherwise
    /// (including whenever PCC itself is unavailable).
    public static var quotaLimitReachedMessage: String? {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *) else { return nil }
            return PrivateCloudComputeSQLGenerator.quotaLimitReachedMessage
        #else
            return nil
        #endif
    }

    /// A short warning when the user is near the daily limit; nil otherwise
    /// (including when the limit is already exhausted).
    public static var quotaWarning: String? {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *) else { return nil }
            return PrivateCloudComputeSQLGenerator.quotaWarning
        #else
            return nil
        #endif
    }

    /// True when the OS offers a way to raise the daily limit.
    public static var hasLimitIncreaseSuggestion: Bool {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *) else { return false }
            return PrivateCloudComputeSQLGenerator.hasLimitIncreaseSuggestion
        #else
            return false
        #endif
    }

    /// Opens Apple's limit-increase UI when the OS offers one.
    public static func showLimitIncreaseSuggestion() {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *) else { return }
            PrivateCloudComputeSQLGenerator.showLimitIncreaseSuggestion()
        #endif
    }

    /// The PCC generator, or nil when it isn't compiled in or can't serve
    /// requests right now.
    static func makeGenerator() -> (any SQLGenerator)? {
        #if compiler(>=6.4) && canImport(FoundationModels)
            guard #available(macOS 27.0, *), availabilityMessage == nil else { return nil }
            return PrivateCloudComputeSQLGenerator()
        #else
            return nil
        #endif
    }
}
