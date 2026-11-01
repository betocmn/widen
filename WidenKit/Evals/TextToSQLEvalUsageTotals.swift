import Foundation

/// Token and cost totals over eval results, rendered the same way in the eval
/// summary's provider section and the release gate's reported-only section.
/// Each total is nil when no result recorded that count.
public struct TextToSQLEvalUsageTotals: Equatable, Sendable {
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    /// A `CloudCostSource` raw value; an estimate when any result's cost was.
    public var costSource: String?

    /// Shown next to a cost that was estimated from token prices.
    public static let estimatedCostLabel = "token estimate at peak pricing; upper bound"
    /// Shown next to a cost the provider reported in `usage.cost`.
    public static let reportedCostLabel = "provider-reported"

    public init(results: [TextToSQLEvalResult]) {
        let metrics = results.map(\.metrics)
        promptTokens = Self.sum(metrics.compactMap(\.promptTokens))
        cachedPromptTokens = Self.sum(metrics.compactMap(\.cachedPromptTokens))
        completionTokens = Self.sum(metrics.compactMap(\.completionTokens))
        reasoningTokens = Self.sum(metrics.compactMap(\.reasoningTokens))
        totalTokens = Self.sum(metrics.compactMap(\.tokenUsage))
        let costs = metrics.compactMap(\.estimatedCloudCostUSD)
        costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
        costSource = metrics.compactMap(\.estimatedCloudCostSource)
            .reduce(String?.none) { CloudCostSource.combined($0, $1) }
    }

    /// The share of prompt tokens served from the prompt cache, or nil when
    /// no prompt tokens were recorded.
    public var cacheHitRate: Double? {
        guard let promptTokens, promptTokens > 0 else { return nil }
        return Double(cachedPromptTokens ?? 0) / Double(promptTokens)
    }

    /// `| Metric | Value |` rows for the token counts, cost and cost source.
    public var markdownRows: [String] {
        [
            "| Prompt tokens | \(Self.value(promptTokens)) |",
            "| Cached prompt tokens | \(cachedPromptCell) |",
            "| Completion tokens | \(Self.value(completionTokens)) |",
            "| Reasoning tokens | \(Self.value(reasoningTokens)) |",
            "| Token usage | \(Self.value(totalTokens)) |",
            "| Estimated cloud cost | \(Self.formattedCost(costUSD, source: costSource)) |",
            "| Cost source | \(costSource.map(Self.tableCell) ?? "-") |",
        ]
    }

    /// A cost in dollars, labelled with how it was obtained.
    public static func formattedCost(_ costUSD: Double?, source: String?) -> String {
        guard let costUSD else { return "-" }
        let cost = String(format: "$%.6f", costUSD)
        switch source.flatMap(CloudCostSource.init(rawValue:)) {
        case .estimatedPeakList: return "\(cost) (\(estimatedCostLabel))"
        case .reported: return "\(cost) (\(reportedCostLabel))"
        case nil: return cost
        }
    }

    private var cachedPromptCell: String {
        guard let cachedPromptTokens else { return "-" }
        guard let cacheHitRate else { return String(cachedPromptTokens) }
        return "\(cachedPromptTokens) (\(String(format: "%.1f%%", cacheHitRate * 100)) hit rate)"
    }

    private static func tableCell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func sum(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +)
    }

    private static func value(_ count: Int?) -> String {
        count.map(String.init) ?? "-"
    }
}
