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
                    type: try row["table_type"].decode(String.self)
                )
            }

            let columns = try await postgres.query(Self.columnsSQL) { row in
                ColumnInfo(
                    tableSchema: try row["table_schema"].decode(String.self),
                    tableName: try row["table_name"].decode(String.self),
                    name: try row["column_name"].decode(String.self),
                    dataType: try row["data_type"].decode(String.self),
                    udtName: try? row["udt_name"].decode(String.self),
                    isNullable: try row["is_nullable"].decode(String.self) == "YES",
                    ordinalPosition: Int(try row["ordinal_position"].decode(Int32.self))
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
                    targetColumn: try row["foreign_column_name"].decode(String.self)
                )
            }

            var columnsByTable: [String: [ColumnInfo]] = [:]
            for column in columns {
                columnsByTable["\(column.tableSchema).\(column.tableName)", default: []].append(column)
            }

            let tables = tableRows.map { row in
                TableInfo(
                    schema: row.schema,
                    name: row.name,
                    type: TableType(rawValue: row.type) ?? .baseTable,
                    columns: (columnsByTable["\(row.schema).\(row.name)"] ?? [])
                        .sorted { $0.ordinalPosition < $1.ordinalPosition }
                )
            }

            let schemaNames = Set(tables.map(\.schema))
            return DatabaseSchema(
                schemas: schemaNames.sorted().map(SchemaInfo.init(name:)),
                tables: tables,
                foreignKeys: foreignKeys,
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
    }

    static let tablesSQL = """
        SELECT
          table_schema,
          table_name,
          table_type
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
          AND table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY table_schema, table_name
        """

    static let columnsSQL = """
        SELECT
          table_schema,
          table_name,
          column_name,
          data_type,
          udt_name,
          is_nullable,
          ordinal_position
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name, ordinal_position
        """

    static let foreignKeysSQL = """
        SELECT
          tc.table_schema,
          tc.table_name,
          kcu.column_name,
          ccu.table_schema AS foreign_table_schema,
          ccu.table_name AS foreign_table_name,
          ccu.column_name AS foreign_column_name,
          tc.constraint_name
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
          AND tc.table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY tc.table_schema, tc.table_name, tc.constraint_name, kcu.ordinal_position
        """
}
