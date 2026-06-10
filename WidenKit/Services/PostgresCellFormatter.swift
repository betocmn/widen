import Foundation
import NIOCore
import PostgresNIO

/// Converts result cells into display strings. The MVP renders everything as
/// text; `nil` means SQL NULL.
enum PostgresCellFormatter {
    static func string(for cell: PostgresCell) -> String? {
        guard let bytes = cell.bytes else { return nil }
        do {
            switch cell.dataType {
            case .bool:
                return try cell.decode(Bool.self) ? "true" : "false"
            case .int2:
                return String(try cell.decode(Int16.self))
            case .int4:
                return String(try cell.decode(Int32.self))
            case .int8:
                return String(try cell.decode(Int64.self))
            case .float4:
                return String(try cell.decode(Float.self))
            case .float8:
                return String(try cell.decode(Double.self))
            case .numeric:
                return String(describing: try cell.decode(Decimal.self))
            case .uuid:
                return try cell.decode(UUID.self).uuidString.lowercased()
            case .date:
                return dateOnlyFormatter.string(from: try cell.decode(Date.self))
            case .timestamp, .timestamptz:
                return timestampFormatter.string(from: try cell.decode(Date.self))
            case .bytea:
                return hexString(bytes)
            default:
                // PostgresNIO's String decoding is deliberately permissive:
                // it reads any UTF-8 payload (text, varchar, name, char,
                // json/jsonb, enums, citext, ltree, …).
                return try cell.decode(String.self)
            }
        } catch {
            return "<\(cell.dataType) · \(bytes.readableBytes) bytes>"
        }
    }

    // DateFormatter/ISO8601DateFormatter are documented thread-safe and these
    // are never mutated after creation.
    nonisolated(unsafe) private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func hexString(_ buffer: ByteBuffer) -> String {
        let limit = 256
        var copy = buffer
        let bytes = copy.readBytes(length: min(copy.readableBytes, limit)) ?? []
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\\x" + hex + (buffer.readableBytes > limit ? "…" : "")
    }
}
