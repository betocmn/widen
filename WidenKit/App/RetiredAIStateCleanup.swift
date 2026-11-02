import Foundation

/// Removes what the retired AI backends (Apple on-device, Private Cloud
/// Compute and OpenRouter) left on this Mac. Run by `AppState.onLaunch`.
///
/// Every launch it drops the retired preferences and the OpenRouter model
/// catalog cache, both cheap no-ops once gone. The OpenRouter API key is
/// deleted once: the flag is set before the attempt, so a failed delete or a
/// cancelled Keychain prompt is never retried and the prompt appears at most
/// once. The old key is only ever deleted, never read, so it can never end up
/// in the Particle slot.
struct RetiredAIStateCleanup {
    static let retiredPreferenceKeys = [
        "WidenOpenRouterModelID",
        "WidenOpenRouterSchemaToolAgentEnabled",
        "WidenExperimentalCloudSchemaAgentEnabled",
        "WidenAIBackendMode",
        "WidenCloudAIProvider",
    ]
    /// The on-device compatibility alert saved one flag per build, as
    /// `WidenDidShowInstallLLMCompatibilityAlert.<version>.<build>.v1`.
    static let retiredPreferenceKeyPrefix = "WidenDidShowInstallLLMCompatibilityAlert."
    static let openRouterCatalogCacheFileName = "openrouter-model-catalog-cache.json"
    static let didRemoveOpenRouterAPIKeyKey = "WidenDidRemoveRetiredOpenRouterState.v1"

    let defaults: UserDefaults
    /// The folder that holds `connections.json`: `~/Library/Application
    /// Support/Widen` in the app, a temporary directory in tests.
    let applicationSupportDirectory: URL
    /// Deletes the Keychain item `Widen`/`openrouter-api-key`.
    let deleteLegacyOpenRouterAPIKey: () throws -> Void

    func run() {
        for key in Self.retiredPreferenceKeys {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.retiredPreferenceKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        // Missing is the normal case after the first launch.
        try? FileManager.default.removeItem(
            at: applicationSupportDirectory.appendingPathComponent(
                Self.openRouterCatalogCacheFileName)
        )

        guard !defaults.bool(forKey: Self.didRemoveOpenRouterAPIKeyKey) else { return }
        defaults.set(true, forKey: Self.didRemoveOpenRouterAPIKeyKey)
        try? deleteLegacyOpenRouterAPIKey()
    }
}
