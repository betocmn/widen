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

    @Test func redactsParticleKeyTokens() {
        let redacted = EvalReportRedaction.redactedProviderMessage(
            "Key pai-Ab3dEf9h_IjKl-MnOpQrStUv rejected; quoted \"pai-0123456789abcdef\" too"
        )
        #expect(!redacted.contains("pai-"))
        #expect(redacted == "Key [redacted-key] rejected; quoted \"[redacted-key]\" too")
    }

    @Test func redactsBearerCredentials() {
        let redacted = EvalReportRedaction.redactedProviderMessage(
            "Sent Authorization: Bearer pai-Ab3dEf9hIjKlMnOp and bearer sk-short"
        )
        #expect(!redacted.contains("pai-"))
        #expect(!redacted.contains("sk-short"))
        #expect(redacted == "Sent Authorization: [redacted-key] and [redacted-key]")
    }

    @Test func redactsParticleURLsWithAndWithoutScheme() {
        let schemeless = EvalReportRedaction.redactedProviderMessage(
            "Add credits at platform.particle.ai/settings/keys before retrying"
        )
        #expect(schemeless == "Add credits at [redacted-url] before retrying")
        let bareDomain = EvalReportRedaction.redactedProviderMessage(
            "See PARTICLE.AI/docs/errors"
        )
        #expect(bareDomain == "See [redacted-url]")
        let withScheme = EvalReportRedaction.redactedProviderMessage(
            "POST https://api.particle.ai/v1/chat/completions failed"
        )
        #expect(withScheme == "POST [redacted-url] failed")
    }

    @Test func leavesParticleModelIDsAndBareHostUntouched() {
        let message =
            "Model particle-ai/particle-1 (requested particle-1) answered from api.particle.ai."
        #expect(EvalReportRedaction.redactedProviderMessage(message) == message)
        let errorCode = "invalid_bearer_credential: insufficient_credits"
        #expect(EvalReportRedaction.redactedProviderMessage(errorCode) == errorCode)
    }

    @Test func evalReporterRedactsDiagnosticErrorMessages() throws {
        let reporter = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WidenEval/EvalReporter.swift")
        let source = try String(contentsOf: reporter, encoding: .utf8)
        let start = try #require(
            source.range(of: "private static func diagnosticsSummary(")
        )
        let body = String(source[start.lowerBound...])

        #expect(body.contains("if let error = result.diagnostics.errorMessage {"))
        #expect(body.contains("parts.append(EvalReportRedaction.redactedProviderMessage(error))"))
        #expect(!body.contains("parts.append(error)"))
    }
}
