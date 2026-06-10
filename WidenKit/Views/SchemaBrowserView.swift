import SwiftUI

/// Columns of the selected table, shown at the bottom of the sidebar.
public struct SchemaBrowserView: View {
    let table: TableInfo

    public init(table: TableInfo) {
        self.table = table
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(table.qualifiedName)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            List(table.columns) { column in
                HStack(alignment: .firstTextBaseline) {
                    Text(column.name)
                        .font(.caption.monospaced())
                    Spacer(minLength: 8)
                    Text(column.dataType + (column.isNullable ? "" : " · not null"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .listStyle(.plain)
        }
    }
}
