import Foundation

/// Extracts connection details from text the user pasted. Implementations
/// must be local-only: the pasted text can contain credentials and must
/// never leave the machine.
public protocol ConnectionDetailsParsing: Sendable {
    func parse(_ text: String) async throws -> ParsedConnectionDetails
}

/// Builds the instructions and prompt for paste-autofill extraction.
public enum ConnectionAutofillPromptBuilder {
    /// Pasted text beyond this is dropped from the prompt — connection
    /// details virtually always appear early, and the local model's context
    /// window is small.
    public static let maxPastedCharacters = 6_000

    public static var instructions: String {
        """
        You extract PostgreSQL connection details from text pasted into a local Mac database GUI.
        The text may be a connection URL (postgres://user:password@host:port/database?sslmode=require), \
        a .env file, shell exports, JSON, YAML, prose from a teammate, or a mix of formats.

        Rules:
        - Extract only values that are actually present in the text. Never invent or guess a value.
        - Leave a field empty when the text does not specify it.
        - Decode percent-encoded URL values, e.g. p%40ss becomes p@ss.
        - The database is the name only, without a leading slash.
        - For sslMode answer exactly one of: disable, prefer, require, unknown. \
        Map allow to prefer, and verify-ca or verify-full to require. \
        Answer unknown when SSL is not mentioned.
        - Suggest a nickname only when the text clearly names the database or app; otherwise leave it empty.
        """
    }

    public static func prompt(for text: String) -> String {
        "Extract the PostgreSQL connection details from this text:\n\n\(truncated(text))"
    }

    static func truncated(_ text: String, to maxCharacters: Int = maxPastedCharacters) -> String {
        text.count <= maxCharacters ? text : String(text.prefix(maxCharacters)) + "…"
    }
}
