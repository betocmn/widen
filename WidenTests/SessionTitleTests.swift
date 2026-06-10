import Foundation
import Testing

@testable import WidenKit

@Suite("SessionTitleFallback")
struct SessionTitleFallbackTests {
    @Test func shortQuestionIsUsedVerbatim() {
        #expect(SessionTitleFallback.title(from: "Show me all users") == "Show me all users")
    }

    @Test func whitespaceIsCollapsed() {
        #expect(
            SessionTitleFallback.title(from: "  Show   me\nall\tusers  ")
                == "Show me all users")
    }

    @Test func longQuestionTruncatesAtWordBoundary() {
        let title = SessionTitleFallback.title(
            from: "Which customers placed the most orders in the last twelve months by region")
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 41)  // 40 characters + ellipsis
        // Never cuts a word in half: dropping the ellipsis leaves whole words.
        #expect(title == "Which customers placed the most orders…")
    }

    @Test func longSingleWordStillTruncates() {
        let title = SessionTitleFallback.title(from: String(repeating: "a", count: 80))
        #expect(title.count == 41)
        #expect(title.hasSuffix("…"))
    }

    @Test func sanitizeStripsQuotesAndPeriods() {
        #expect(SessionTitleFallback.sanitize("\"Top Spenders.\"") == "Top Spenders")
        #expect(SessionTitleFallback.sanitize("“Orders by Status”") == "Orders by Status")
        #expect(SessionTitleFallback.sanitize("'Recent Signups...'") == "Recent Signups")
    }

    @Test func sanitizeCollapsesWhitespace() {
        #expect(SessionTitleFallback.sanitize("  Top \n Spenders  ") == "Top Spenders")
    }

    @Test func sanitizeCapsLengthAtSixtyCharacters() {
        let long = String(repeating: "word ", count: 30)
        let sanitized = SessionTitleFallback.sanitize(long)
        #expect((sanitized?.count ?? 0) <= 60)
    }

    @Test func sanitizeReturnsNilForEmptyResults() {
        #expect(SessionTitleFallback.sanitize("") == nil)
        #expect(SessionTitleFallback.sanitize("   ") == nil)
        #expect(SessionTitleFallback.sanitize("\"...\"") == nil)
    }
}

@Suite("MockTitleGenerator")
struct MockTitleGeneratorTests {
    @Test func titlesAreDeterministic() async throws {
        let generator = MockTitleGenerator()
        let question = "Which users have spent the most?"

        let first = try await generator.generateTitle(for: question)
        let second = try await generator.generateTitle(for: question)

        #expect(first == second)
        #expect(first == "Which users have spent the most?")
    }
}
