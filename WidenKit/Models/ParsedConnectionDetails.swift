import Foundation

/// Connection fields extracted from text the user pasted. Every field is
/// optional: nil means the text did not specify it, so the form keeps its
/// current value for that field.
public struct ParsedConnectionDetails: Equatable, Sendable {
    public var name: String?
    public var host: String?
    public var port: Int?
    public var database: String?
    public var username: String?
    public var password: String?
    public var sslMode: SSLMode?

    public init(
        name: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        database: String? = nil,
        username: String? = nil,
        password: String? = nil,
        sslMode: SSLMode? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.sslMode = sslMode
    }

    public var isEmpty: Bool {
        name == nil && host == nil && port == nil && database == nil
            && username == nil && password == nil && sslMode == nil
    }

    /// Returns a copy where every non-nil field of `override` replaces this
    /// one. Used to let a deterministically parsed connection URL win over the
    /// model's guess while keeping the fields the URL did not specify.
    public func overridden(by override: ParsedConnectionDetails) -> ParsedConnectionDetails {
        ParsedConnectionDetails(
            name: override.name ?? name,
            host: override.host ?? host,
            port: override.port ?? port,
            database: override.database ?? database,
            username: override.username ?? username,
            password: override.password ?? password,
            sslMode: override.sslMode ?? sslMode
        )
    }

    /// Builds details from raw extracted values: trims whitespace, drops
    /// empty strings, validates the port range, strips a leading slash from
    /// the database (URL paths), and maps libpq sslmode spellings onto the
    /// app's three modes. Empty passwords are normally treated as missing
    /// model output, but deterministic parsers can preserve them when the
    /// source explicitly specified an empty password.
    public static func sanitized(
        name: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        database: String? = nil,
        username: String? = nil,
        password: String? = nil,
        sslModeText: String? = nil,
        preservesEmptyPassword: Bool = false
    ) -> ParsedConnectionDetails {
        let cleanedDatabase = normalized(database).flatMap { value -> String? in
            let stripped = value.hasPrefix("/") ? String(value.dropFirst()) : value
            return stripped.isEmpty ? nil : stripped
        }
        return ParsedConnectionDetails(
            name: normalized(name),
            host: normalized(host),
            port: port.flatMap { (1...65535).contains($0) ? $0 : nil },
            database: cleanedDatabase,
            username: normalized(username),
            password: normalized(password, preservesEmpty: preservesEmptyPassword),
            sslMode: sslMode(from: sslModeText)
        )
    }

    /// Maps libpq sslmode spellings (and common boolean spellings) onto the
    /// app's three modes. Unknown or missing values map to nil so the form
    /// keeps its current selection.
    public static func sslMode(from text: String?) -> SSLMode? {
        switch text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "disable", "disabled", "off", "false":
            .disable
        case "allow", "prefer", "preferred", "on", "true":
            .prefer
        case "require", "required", "verify-ca", "verify-full", "verify_ca", "verify_full":
            .require
        default:
            nil
        }
    }

    private static func normalized(_ value: String?, preservesEmpty: Bool = false) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            preservesEmpty || !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
