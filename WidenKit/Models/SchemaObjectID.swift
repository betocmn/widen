import Foundation

public enum SchemaObjectKind: String, Codable, Equatable, Hashable, Sendable {
    case schema
    case table
    case column
    case keyConstraint = "key_constraint"
    case foreignKeyConstraint = "foreign_key_constraint"
}

public struct SchemaObjectID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var kind: SchemaObjectKind
    public var schema: String
    public var table: String?
    public var column: String?
    public var constraintName: String?

    public var description: String {
        switch kind {
        case .schema:
            schema
        case .table:
            [schema, table].compactMap { $0 }.joined(separator: ".")
        case .column:
            [schema, table, column].compactMap { $0 }.joined(separator: ".")
        case .keyConstraint, .foreignKeyConstraint:
            [
                kind.rawValue,
                [schema, table, constraintName].compactMap { $0 }.joined(separator: "."),
            ]
            .joined(separator: ":")
        }
    }

    public var stableString: String {
        [
            kind.rawValue,
            schema,
            table ?? "",
            column ?? "",
            constraintName ?? "",
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
    }

    public init(
        kind: SchemaObjectKind,
        schema: String,
        table: String? = nil,
        column: String? = nil,
        constraintName: String? = nil
    ) {
        self.kind = kind
        self.schema = schema
        self.table = table
        self.column = column
        self.constraintName = constraintName
    }

    public static func schema(_ name: String) -> SchemaObjectID {
        SchemaObjectID(kind: .schema, schema: name)
    }

    public static func table(schema: String, name: String) -> SchemaObjectID {
        SchemaObjectID(kind: .table, schema: schema, table: name)
    }

    public static func column(schema: String, table: String, name: String) -> SchemaObjectID {
        SchemaObjectID(kind: .column, schema: schema, table: table, column: name)
    }

    public static func keyConstraint(
        schema: String,
        table: String,
        name: String
    ) -> SchemaObjectID {
        SchemaObjectID(kind: .keyConstraint, schema: schema, table: table, constraintName: name)
    }

    public static func foreignKeyConstraint(
        schema: String,
        table: String,
        name: String
    ) -> SchemaObjectID {
        SchemaObjectID(
            kind: .foreignKeyConstraint,
            schema: schema,
            table: table,
            constraintName: name
        )
    }

    public static func tableFromQualifiedName(_ qualifiedName: String) -> SchemaObjectID? {
        let parts = qualifiedName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return .table(schema: String(parts[0]), name: String(parts[1]))
    }
}
