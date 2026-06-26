import Foundation

/// One selectable OpenRouter model.
public struct OpenRouterModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Curated, known-good OpenRouter models for SQL generation. The Settings
/// picker offers these plus a free-text custom ID, so newly released models
/// never require an app update.
public enum OpenRouterCatalog {
    public static let curated: [OpenRouterModelOption] = [
        OpenRouterModelOption(id: "anthropic/claude-sonnet-4.6", displayName: "Claude Sonnet 4.6"),
        OpenRouterModelOption(id: "anthropic/claude-fable-5", displayName: "Claude Fable 5"),
        OpenRouterModelOption(id: "openai/gpt-5.5", displayName: "GPT-5.5"),
        OpenRouterModelOption(id: "google/gemini-3.5-flash", displayName: "Gemini 3.5 Flash"),
        OpenRouterModelOption(id: "deepseek/deepseek-v4-pro", displayName: "DeepSeek V4 Pro"),
    ]

    public static let defaultModelID = "openai/gpt-5.5"

    /// Display name for a model ID, falling back to the raw ID for custom
    /// models.
    public static func displayName(for id: String) -> String {
        curated.first { $0.id == id }?.displayName ?? id
    }
}
