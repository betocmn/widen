import Foundation
import Testing

@testable import WidenKit

@Suite("Text-to-SQL eval usage totals")
struct TextToSQLEvalUsageTotalsTests {
    @Test func totalsSumTheTokenBreakdownAndLabelATokenEstimate() {
        let estimated = CloudCostSource.estimatedPeakList.rawValue
        let totals = TextToSQLEvalUsageTotals(results: [
            Self.result(
                prompt: 1_000,
                cached: 200,
                completion: 300,
                reasoning: 120,
                total: 1_300,
                cost: 0.000_506,
                costSource: estimated
            ),
            Self.result(
                prompt: 600,
                cached: 200,
                completion: 100,
                reasoning: 40,
                total: 700,
                cost: 0.000_206,
                costSource: estimated
            ),
            // A skipped slot records no usage and changes no total.
            Self.result(),
        ])

        #expect(totals.promptTokens == 1_600)
        #expect(totals.cachedPromptTokens == 400)
        #expect(totals.completionTokens == 400)
        #expect(totals.reasoningTokens == 160)
        #expect(totals.totalTokens == 2_000)
        #expect(totals.costSource == estimated)
        #expect(totals.cacheHitRate == 0.25)
        #expect(totals.markdownRows == [
            "| Prompt tokens | 1600 |",
            "| Cached prompt tokens | 400 (25.0% hit rate) |",
            "| Completion tokens | 400 |",
            "| Reasoning tokens | 160 |",
            "| Token usage | 2000 |",
            "| Estimated cloud cost | $0.000712 (token estimate at peak pricing; upper bound) |",
            "| Cost source | estimatedPeakList |",
        ])
    }

    @Test func aTotalWithAnyEstimatedCostIsAnEstimate() {
        let reported = CloudCostSource.reported.rawValue
        let reportedOnly = TextToSQLEvalUsageTotals(results: [
            Self.result(total: 10, cost: 0.01, costSource: reported),
            Self.result(total: 20, cost: 0.02, costSource: reported),
        ])
        #expect(reportedOnly.costSource == reported)
        #expect(reportedOnly.markdownRows.contains("| Estimated cloud cost | $0.030000 (provider-reported) |"))
        #expect(reportedOnly.markdownRows.contains("| Cost source | reported |"))

        let mixed = TextToSQLEvalUsageTotals(results: [
            Self.result(total: 10, cost: 0.01, costSource: reported),
            Self.result(
                total: 20,
                cost: 0.02,
                costSource: CloudCostSource.estimatedPeakList.rawValue
            ),
        ])
        #expect(mixed.costSource == CloudCostSource.estimatedPeakList.rawValue)
        #expect(
            mixed.markdownRows.contains(
                "| Estimated cloud cost | $0.030000 (token estimate at peak pricing; upper bound) |"
            )
        )
    }

    @Test func resultsWithoutUsageReportDashes() {
        let totals = TextToSQLEvalUsageTotals(results: [Self.result(), Self.result()])

        #expect(totals.cacheHitRate == nil)
        #expect(totals.markdownRows == [
            "| Prompt tokens | - |",
            "| Cached prompt tokens | - |",
            "| Completion tokens | - |",
            "| Reasoning tokens | - |",
            "| Token usage | - |",
            "| Estimated cloud cost | - |",
            "| Cost source | - |",
        ])
    }

    @Test func cachedTokensWithoutPromptTokensHaveNoHitRate() {
        let totals = TextToSQLEvalUsageTotals(results: [Self.result(cached: 5, total: 5)])

        #expect(totals.cacheHitRate == nil)
        #expect(totals.markdownRows.contains("| Cached prompt tokens | 5 |"))
    }

    @Test func aCostFromResultsWrittenBeforeItsSourceIsUnlabelled() {
        // Results from before the cost source was recorded still decode, and
        // their cost is shown without a claim about where it came from.
        #expect(TextToSQLEvalUsageTotals.formattedCost(0.5, source: nil) == "$0.500000")
        #expect(TextToSQLEvalUsageTotals.formattedCost(0.5, source: "futureSource") == "$0.500000")
        #expect(TextToSQLEvalUsageTotals.formattedCost(nil, source: "reported") == "-")

        let totals = TextToSQLEvalUsageTotals(results: [Self.result(total: 3, cost: 0.5)])
        #expect(totals.markdownRows.contains("| Estimated cloud cost | $0.500000 |"))
        #expect(totals.markdownRows.contains("| Cost source | - |"))
    }

    @Test func evalReporterNamesTheProviderAndReportsTheTokenBreakdown() throws {
        let text = try Self.source("WidenEval/EvalReporter.swift")

        for heading in [
            "\"## Provider Transport (\\(tableCell($0)))\"",
            "\"### Output Modes\",",
            "\"### Agent Selection\",",
            "\"### Agent Terminal Outcomes\",",
            "\"### Provider Failures\",",
            "\"### Returned Models\",",
        ] {
            #expect(text.contains(heading), "\(heading)")
        }
        #expect(!text.contains("OpenRouter Transport"))
        #expect(!text.contains("openRouterSection"))
        #expect(!text.contains("### OpenRouter "))

        // The upstream-provider table appears only when a router named one.
        let upstreamGuard = try #require(text.range(of: "if !upstreamProviderCounts.isEmpty {"))
        let upstreamHeading = try #require(text.range(of: "\"### Upstream Providers\","))
        #expect(upstreamGuard.lowerBound < upstreamHeading.lowerBound)

        #expect(text.contains("lines += usage.markdownRows"))
        #expect(text.contains("TextToSQLEvalUsageTotals.formattedCost("))
        #expect(text.contains(#""| Provider | \(tableCell(run.manifest.resolvedProvider ?? "-")) |","#))
        #expect(text.contains(#""| Endpoint host | \(tableCell(run.manifest.providerEndpointHost ?? "-")) |","#))
        #expect(text.contains(#""| Reasoning effort | \(tableCell(run.manifest.reasoningEffort ?? "-")) |","#))
        #expect(text.contains("| Expected returned model |"))
        #expect(!text.contains("Expected canonical model"))
        #expect(text.contains(#"parts.append("provider failure: \(category)")"#))
        #expect(!text.contains(#""openrouter: "#))
    }

    @Test func releaseGateReportsTheProviderAndUngatedSpend() throws {
        let text = try Self.source("WidenEval/ReleaseGateReporter.swift")

        let markdownStart = try #require(text.range(of: "private static func markdown("))
        let markdownText = String(text[markdownStart.lowerBound...])
        for row in [
            #""| Provider | \(tableCell(run.manifest.resolvedProvider ?? "-")) |","#,
            #""| Endpoint | \(tableCell(run.manifest.providerEndpointHost ?? "-")) |","#,
            #""| Expected returned model | \(tableCell(run.manifest.expectedCanonicalModelID ?? "-")) |","#,
            #""| Reasoning effort | \(tableCell(run.manifest.reasoningEffort ?? "-")) |","#,
        ] {
            #expect(markdownText.contains(row), "\(row)")
        }
        #expect(markdownText.contains("lines += reportedUsageSection(results: releaseGateResults(for: run))"))

        let sectionStart = try #require(text.range(of: "private static func reportedUsageSection("))
        let sectionEnd = try #require(
            text.range(
                of: "private static func historicalRegressionSection(",
                range: sectionStart.upperBound..<text.endIndex
            )
        )
        let section = String(text[sectionStart.upperBound..<sectionEnd.lowerBound])
        #expect(section.contains("\"## Reported (not gated)\","))
        #expect(section.contains("TextToSQLEvalUsageTotals(results: results).markdownRows"))
        #expect(!text.contains("Expected canonical model"))
    }

    @Test func manifestProviderNamesMapBackToTheirProviders() {
        #expect(TextToSQLEvalCloudSettings.providerID(forManifestName: "particle") == .particle)
        #expect(TextToSQLEvalCloudSettings.providerID(forManifestName: "openrouter") == .openRouter)
        #expect(TextToSQLEvalCloudSettings.providerID(forManifestName: "openRouter") == nil)
        for provider in CloudModelProviderID.allCases {
            #expect(
                TextToSQLEvalCloudSettings.providerID(
                    forManifestName: TextToSQLEvalCloudSettings.manifestName(for: provider)
                ) == provider
            )
        }
    }

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private static func result(
        prompt: Int? = nil,
        cached: Int? = nil,
        completion: Int? = nil,
        reasoning: Int? = nil,
        total: Int? = nil,
        cost: Double? = nil,
        costSource: String? = nil
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: "case.\(UUID().uuidString)",
            backend: .cloud,
            model: "particle-1",
            repeatIndex: 1,
            status: total == nil ? .skippedBudgetLimit : .passed,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: total != nil,
                structuredResponseParsed: total != nil,
                decisionMatches: total != nil,
                latencyMs: 1,
                tokenUsage: total,
                promptTokens: prompt,
                cachedPromptTokens: cached,
                completionTokens: completion,
                reasoningTokens: reasoning,
                estimatedCloudCostUSD: cost,
                estimatedCloudCostSource: costSource
            )
        )
    }
}
