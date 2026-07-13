import Foundation

/// Strips account-specific URLs, key tokens, and identifiers from provider
/// error messages before they reach a sanitized committed report.
public enum EvalReportRedaction {
    public static func redactedProviderMessage(_ message: String) -> String {
        message
            .replacingOccurrences(
                of: #"(?i)\bhttps?://\S+"#,
                with: "[redacted-url]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bopenrouter\.ai/\S+"#,
                with: "[redacted-url]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\bsk-or-\S+"#,
                with: "[redacted-key]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b[a-fA-F0-9]{32,}\b"#,
                with: "[redacted-id]",
                options: .regularExpression
            )
    }
}
