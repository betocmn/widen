import Foundation

/// Loads tables, columns, and foreign keys from `information_schema`,
/// excluding system schemas.
public struct SchemaIntrospectionService: Sendable {
    public init() {}

    public func loadSchema(using postgres: PostgresService) async throws -> DatabaseSchema {
        do {
            let tableRows = try await postgres.query(Self.tablesSQL) { row in
                TableRow(
                    schema: try row["table_schema"].decode(String.self),
                    name: try row["table_name"].decode(String.self),
                    type: try row["table_type"].decode(String.self),
                    comment: try? row["table_comment"].decode(String.self)
                )
            }

            let enumRows = try await postgres.query(Self.enumValuesSQL) { row in
                EnumValueRow(
                    typeSchema: try row["type_schema"].decode(String.self),
                    typeName: try row["type_name"].decode(String.self),
                    value: try row["enum_value"].decode(String.self)
                )
            }

            let checkRows = try await postgres.query(Self.columnCheckConstraintsSQL) { row in
                ColumnCheckConstraintRow(
                    tableSchema: try row["table_schema"].decode(String.self),
                    tableName: try row["table_name"].decode(String.self),
                    columnName: try row["column_name"].decode(String.self),
                    constraintName: try row["constraint_name"].decode(String.self),
                    expression: try row["check_expression"].decode(String.self)
                )
            }

            let keyRows = try await postgres.query(Self.keyConstraintsSQL) { row in
                KeyConstraintRow(
                    tableSchema: try row["table_schema"].decode(String.self),
                    tableName: try row["table_name"].decode(String.self),
                    constraintName: try row["constraint_name"].decode(String.self),
                    kind: SchemaKeyConstraintKind(
                        rawValue: try row["constraint_kind"].decode(String.self)
                    ) ?? .unique,
                    columnName: try row["column_name"].decode(String.self),
                    ordinalPosition: Int(try row["ordinal_position"].decode(Int64.self))
                )
            }

            let enumValuesByType = Dictionary(grouping: enumRows) {
                "\($0.typeSchema).\($0.typeName)"
            }
            .mapValues { $0.map(\.value) }
            let checksByColumn = Dictionary(grouping: checkRows) {
                "\($0.tableSchema).\($0.tableName).\($0.columnName)"
            }

            let columns = try await postgres.query(Self.columnsSQL) { row in
                let tableSchema = try row["table_schema"].decode(String.self)
                let tableName = try row["table_name"].decode(String.self)
                let name = try row["column_name"].decode(String.self)
                let udtSchema = try? row["udt_schema"].decode(String.self)
                let udtName = try? row["udt_name"].decode(String.self)
                let valueConstraints = Self.valueConstraints(
                    tableSchema: tableSchema,
                    tableName: tableName,
                    columnName: name,
                    udtSchema: udtSchema,
                    udtName: udtName,
                    enumValuesByType: enumValuesByType,
                    checksByColumn: checksByColumn
                )
                return ColumnInfo(
                    tableSchema: tableSchema,
                    tableName: tableName,
                    name: name,
                    comment: try? row["column_comment"].decode(String.self),
                    dataType: try row["data_type"].decode(String.self),
                    udtSchema: udtSchema,
                    udtName: udtName,
                    isNullable: try row["is_nullable"].decode(String.self) == "YES",
                    ordinalPosition: Int(try row["ordinal_position"].decode(Int32.self)),
                    valueConstraints: valueConstraints
                )
            }

            let foreignKeys = try await postgres.query(Self.foreignKeysSQL) { row in
                ForeignKeyInfo(
                    constraintName: try row["constraint_name"].decode(String.self),
                    sourceSchema: try row["table_schema"].decode(String.self),
                    sourceTable: try row["table_name"].decode(String.self),
                    sourceColumn: try row["column_name"].decode(String.self),
                    targetSchema: try row["foreign_table_schema"].decode(String.self),
                    targetTable: try row["foreign_table_name"].decode(String.self),
                    targetColumn: try row["foreign_column_name"].decode(String.self),
                    ordinalPosition: Int(try row["ordinal_position"].decode(Int32.self))
                )
            }

            var columnsByTable: [String: [ColumnInfo]] = [:]
            for column in columns {
                columnsByTable["\(column.tableSchema).\(column.tableName)", default: []].append(column)
            }
            let keyConstraintsByTable = Self.groupKeyConstraints(keyRows)

            let tables = tableRows.map { row in
                let tableKey = "\(row.schema).\(row.name)"
                return TableInfo(
                    schema: row.schema,
                    name: row.name,
                    type: TableType(rawValue: row.type) ?? .baseTable,
                    comment: row.comment,
                    columns: (columnsByTable[tableKey] ?? [])
                        .sorted { $0.ordinalPosition < $1.ordinalPosition },
                    keyConstraints: keyConstraintsByTable[tableKey] ?? []
                )
            }

            let schemaNames = Set(tables.map(\.schema))
            return DatabaseSchema(
                schemas: schemaNames.sorted().map(SchemaInfo.init(name:)),
                tables: tables,
                foreignKeys: foreignKeys,
                foreignKeyConstraints: DatabaseSchema.groupForeignKeys(foreignKeys),
                loadedAt: Date()
            )
        } catch let error as AppError {
            if case .notConnected = error { throw error }
            throw AppError.introspectionFailed(error.localizedDescription)
        } catch {
            throw AppError.introspectionFailed(error.localizedDescription)
        }
    }

    private struct TableRow: Sendable {
        var schema: String
        var name: String
        var type: String
        var comment: String?
    }

    private struct EnumValueRow: Sendable {
        var typeSchema: String
        var typeName: String
        var value: String
    }

    private struct ColumnCheckConstraintRow: Sendable {
        var tableSchema: String
        var tableName: String
        var columnName: String
        var constraintName: String
        var expression: String
    }

    private struct KeyConstraintRow: Sendable {
        var tableSchema: String
        var tableName: String
        var constraintName: String
        var kind: SchemaKeyConstraintKind
        var columnName: String
        var ordinalPosition: Int
    }

    private static func groupKeyConstraints(
        _ rows: [KeyConstraintRow]
    ) -> [String: [SchemaKeyConstraintInfo]] {
        struct GroupKey: Hashable {
            var tableSchema: String
            var tableName: String
            var constraintName: String
            var kind: SchemaKeyConstraintKind
        }

        let grouped = Dictionary(grouping: rows) {
            GroupKey(
                tableSchema: $0.tableSchema,
                tableName: $0.tableName,
                constraintName: $0.constraintName,
                kind: $0.kind
            )
        }

        let constraintsByTable = grouped.reduce(
            into: [String: [SchemaKeyConstraintInfo]]()
        ) { result, entry in
            let key = entry.key
            let columns = entry.value
                .sorted {
                    if $0.ordinalPosition == $1.ordinalPosition {
                        return $0.columnName < $1.columnName
                    }
                    return $0.ordinalPosition < $1.ordinalPosition
                }
                .map(\.columnName)
            result["\(key.tableSchema).\(key.tableName)", default: []].append(
                SchemaKeyConstraintInfo(
                    constraintName: key.constraintName,
                    schema: key.tableSchema,
                    table: key.tableName,
                    kind: key.kind,
                    columns: columns
                )
            )
        }

        return constraintsByTable.mapValues {
            $0.sorted {
                if $0.kind == $1.kind {
                    return $0.constraintName < $1.constraintName
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    private static func valueConstraints(
        tableSchema: String,
        tableName: String,
        columnName: String,
        udtSchema: String?,
        udtName: String?,
        enumValuesByType: [String: [String]],
        checksByColumn: [String: [ColumnCheckConstraintRow]]
    ) -> [ColumnValueConstraint]? {
        var constraints: [ColumnValueConstraint] = []
        if let udtSchema, let udtName,
            let values = enumValuesByType["\(udtSchema).\(udtName)"],
            !values.isEmpty
        {
            constraints.append(ColumnValueConstraint(kind: .enumValues, values: values))
        }

        let columnKey = "\(tableSchema).\(tableName).\(columnName)"
        for check in checksByColumn[columnKey] ?? [] {
            constraints.append(
                ColumnValueConstraint(
                    kind: .check,
                    values: checkValueLiterals(in: check.expression),
                    expression: check.expression,
                    constraintName: check.constraintName
                ))
        }
        return constraints.isEmpty ? nil : constraints
    }

    static func checkValueLiterals(in expression: String) -> [String] {
        guard isPositiveValueCheckExpression(expression) else { return [] }
        return stringLiterals(in: expression)
    }

    private static func isPositiveValueCheckExpression(_ expression: String) -> Bool {
        let lowered = expression.lowercased()
        let operatorText = expressionWithoutStringLiterals(expression).lowercased()
        if operatorText.contains("<>")
            || operatorText.contains("!=")
            || operatorText.contains(">=")
            || operatorText.contains("<=")
            || operatorText.contains(">")
            || operatorText.contains("<")
            || operatorText.range(of: #"\bnot\b"#, options: .regularExpression) != nil
            || operatorText.contains("!~")
        {
            return false
        }
        return lowered.range(of: #"\bin\s*\("#, options: .regularExpression) != nil
            || lowered.range(
                of: #"=\s*any\s*\(\s*array\s*\["#,
                options: .regularExpression
            ) != nil
            || lowered.range(of: #"=\s*'"#, options: .regularExpression) != nil
    }

    private static func expressionWithoutStringLiterals(_ expression: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"'(?:''|[^'])*'"#) else {
            return expression
        }
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        return regex.stringByReplacingMatches(
            in: expression,
            range: range,
            withTemplate: "''"
        )
    }

    private static func stringLiterals(in expression: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"'((?:''|[^'])*)'"#) else {
            return []
        }
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        var seen = Set<String>()
        return regex.matches(in: expression, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: expression) else { return nil }
            let value = String(expression[matchRange])
                .replacingOccurrences(of: "''", with: "'")
            return seen.insert(value).inserted ? value : nil
        }
    }

    static let tablesSQL = """
        SELECT
          t.table_schema,
          t.table_name,
          t.table_type,
          pg_catalog.obj_description(cls.oid, 'pg_class') AS table_comment
        FROM information_schema.tables AS t
        JOIN pg_catalog.pg_namespace AS ns
          ON ns.nspname = t.table_schema
        JOIN pg_catalog.pg_class AS cls
          ON cls.relnamespace = ns.oid
         AND cls.relname = t.table_name
        WHERE t.table_schema <> 'information_schema'
          AND t.table_schema NOT LIKE 'pg\\_%' ESCAPE '\\'
          AND t.table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY t.table_schema, t.table_name
        """

    static let columnsSQL = """
        SELECT
          c.table_schema,
          c.table_name,
          c.column_name,
          c.data_type,
          c.udt_schema,
          c.udt_name,
          c.is_nullable,
          c.ordinal_position,
          pg_catalog.col_description(cls.oid, att.attnum) AS column_comment
        FROM information_schema.columns AS c
        JOIN pg_catalog.pg_namespace AS ns
          ON ns.nspname = c.table_schema
        JOIN pg_catalog.pg_class AS cls
          ON cls.relnamespace = ns.oid
         AND cls.relname = c.table_name
        JOIN pg_catalog.pg_attribute AS att
          ON att.attrelid = cls.oid
         AND att.attname = c.column_name
        WHERE c.table_schema <> 'information_schema'
          AND c.table_schema NOT LIKE 'pg\\_%' ESCAPE '\\'
        ORDER BY c.table_schema, c.table_name, c.ordinal_position
        """

    static let enumValuesSQL = """
        SELECT
          ns.nspname AS type_schema,
          typ.typname AS type_name,
          enum.enumlabel AS enum_value
        FROM pg_catalog.pg_type AS typ
        JOIN pg_catalog.pg_namespace AS ns
          ON ns.oid = typ.typnamespace
        JOIN pg_catalog.pg_enum AS enum
          ON enum.enumtypid = typ.oid
        WHERE ns.nspname <> 'information_schema'
          AND ns.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
        ORDER BY ns.nspname, typ.typname, enum.enumsortorder
        """

    static let columnCheckConstraintsSQL = """
        SELECT
          ns.nspname AS table_schema,
          cls.relname AS table_name,
          att.attname AS column_name,
          con.conname AS constraint_name,
          pg_catalog.pg_get_constraintdef(con.oid, true) AS check_expression
        FROM pg_catalog.pg_constraint AS con
        JOIN pg_catalog.pg_class AS cls
          ON cls.oid = con.conrelid
        JOIN pg_catalog.pg_namespace AS ns
          ON ns.oid = cls.relnamespace
        JOIN pg_catalog.pg_attribute AS att
          ON att.attrelid = con.conrelid
         AND att.attnum = con.conkey[1]
        WHERE con.contype = 'c'
          AND con.conkey IS NOT NULL
          AND array_length(con.conkey, 1) = 1
          AND ns.nspname <> 'information_schema'
          AND ns.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
        ORDER BY ns.nspname, cls.relname, con.conname
        """

    static let keyConstraintsSQL = """
        SELECT
          ns.nspname AS table_schema,
          cls.relname AS table_name,
          con.conname AS constraint_name,
          CASE con.contype
            WHEN 'p' THEN 'primary_key'
            ELSE 'unique'
          END AS constraint_kind,
          att.attname AS column_name,
          key_column.ordinality AS ordinal_position
        FROM pg_catalog.pg_constraint AS con
        JOIN pg_catalog.pg_class AS cls
          ON cls.oid = con.conrelid
        JOIN pg_catalog.pg_namespace AS ns
          ON ns.oid = cls.relnamespace
        JOIN unnest(con.conkey) WITH ORDINALITY AS key_column(attnum, ordinality)
          ON true
        JOIN pg_catalog.pg_attribute AS att
          ON att.attrelid = con.conrelid
         AND att.attnum = key_column.attnum
        WHERE con.contype IN ('p', 'u')
          AND ns.nspname <> 'information_schema'
          AND ns.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
        ORDER BY ns.nspname, cls.relname, con.conname, key_column.ordinality
        """

    static let foreignKeysSQL = """
        SELECT
          tc.table_schema,
          tc.table_name,
          kcu.column_name,
          ccu.table_schema AS foreign_table_schema,
          ccu.table_name AS foreign_table_name,
          ccu.column_name AS foreign_column_name,
          tc.constraint_name,
          kcu.ordinal_position
        FROM information_schema.table_constraints AS tc
        JOIN information_schema.key_column_usage AS kcu
          ON kcu.constraint_catalog = tc.constraint_catalog
         AND kcu.constraint_schema = tc.constraint_schema
         AND kcu.constraint_name = tc.constraint_name
        JOIN information_schema.referential_constraints AS rc
          ON rc.constraint_catalog = tc.constraint_catalog
         AND rc.constraint_schema = tc.constraint_schema
         AND rc.constraint_name = tc.constraint_name
        JOIN information_schema.key_column_usage AS ccu
          ON ccu.constraint_catalog = rc.unique_constraint_catalog
         AND ccu.constraint_schema = rc.unique_constraint_schema
         AND ccu.constraint_name = rc.unique_constraint_name
         AND ccu.ordinal_position = kcu.position_in_unique_constraint
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema <> 'information_schema'
          AND tc.table_schema NOT LIKE 'pg\\_%' ESCAPE '\\'
          AND ccu.table_schema <> 'information_schema'
          AND ccu.table_schema NOT LIKE 'pg\\_%' ESCAPE '\\'
        ORDER BY tc.table_schema, tc.table_name, tc.constraint_name, kcu.ordinal_position
        """
}
