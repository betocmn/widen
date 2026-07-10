import Foundation
import Testing

@testable import WidenKit

@Suite("Eval report redaction")
struct EvalReportRedactionTests {
    @Test func redactsKeyManagementURLsAndIdentifiers() {
        let message =
            "Key limit exceeded (total limit). Manage it using https://openrouter.ai/workspaces/default/keys/3e83378ab4246c098146472a3fbaedba9c3f5a23e8678c241a0ddf28a828684f"
        let redacted = EvalReportRedaction.redactedProviderMessage(message)
        #expect(!redacted.contains("https://"))
        #expect(!redacted.contains("3e83378a"))
        #expect(redacted.contains("Key limit exceeded (total limit)."))
        #expect(redacted.contains("[redacted-url]"))
    }

    @Test func redactsUppercaseAndSchemelessURLs() {
        let uppercase = EvalReportRedaction.redactedProviderMessage(
            "See HTTPS://openrouter.ai/settings for details"
        )
        #expect(!uppercase.contains("openrouter.ai"))
        let schemeless = EvalReportRedaction.redactedProviderMessage(
            "Manage your key at openrouter.ai/settings/keys before retrying"
        )
        #expect(!schemeless.contains("openrouter.ai/settings"))
        #expect(schemeless.contains("[redacted-url]"))
    }

    @Test func redactsOpenRouterKeyTokens() {
        let redacted = EvalReportRedaction.redactedProviderMessage(
            "Key sk-or-v1-Ab3dEf9hIjKlMnOpQrStUvWxYz0123456789 limit exceeded"
        )
        #expect(!redacted.contains("sk-or-"))
        #expect(redacted.contains("[redacted-key]"))
        #expect(redacted.contains("limit exceeded"))
    }

    @Test func redactsLongHexIdentifiers() {
        let redacted = EvalReportRedaction.redactedProviderMessage(
            "request 0123456789abcdef0123456789ABCDEF failed"
        )
        #expect(redacted == "request [redacted-id] failed")
    }

    @Test func leavesOrdinaryMessagesUntouched() {
        let message = "No endpoints found matching your data policy (Zero data retention)."
        #expect(EvalReportRedaction.redactedProviderMessage(message) == message)
    }
}
