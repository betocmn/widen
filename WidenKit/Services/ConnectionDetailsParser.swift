import Foundation

/// Extracts connection details from text the user pasted. Implementations
/// must be local-only: the pasted text can contain credentials and must
/// never leave the machine.
public protocol ConnectionDetailsParsing: Sendable {
    func parse(_ text: String) async throws -> ParsedConnectionDetails
}
