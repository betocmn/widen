import SwiftUI

/// Scrollable, pinned-header grid of one materialized result's stringified
/// values.
struct ResultsGridView: View {
    let result: QueryResult

    var body: some View {
        let widths = columnWidths(for: result)
        // A two-axis ScrollView centers content smaller than the viewport;
        // the GeometryReader-sized frame pins small results to the top
        // leading corner instead.
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(result.rows.indices, id: \.self) { rowIndex in
                            rowView(
                                cells: result.rows[rowIndex],
                                widths: widths,
                                background: rowIndex.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color.primary.opacity(0.04)
                            )
                        }
                    } header: {
                        rowView(
                            cells: result.columns,
                            widths: widths,
                            background: Color.primary.opacity(0.08),
                            isHeader: true
                        )
                    }
                }
                .frame(
                    minWidth: geometry.size.width,
                    minHeight: geometry.size.height,
                    alignment: .topLeading)
            }
        }
    }

    private func rowView(
        cells: [String?],
        widths: [CGFloat],
        background: Color,
        isHeader: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                Text(cells[index] ?? "NULL")
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .foregroundStyle(cells[index] == nil && !isHeader ? .secondary : .primary)
                    .italic(cells[index] == nil && !isHeader)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: widths[index], alignment: .leading)
            }
        }
        .background(background)
    }

    private func rowView(
        cells: [String],
        widths: [CGFloat],
        background: Color,
        isHeader: Bool = false
    ) -> some View {
        rowView(
            cells: cells.map(Optional.some),
            widths: widths,
            background: background,
            isHeader: isHeader
        )
    }

    private func columnWidths(for result: QueryResult) -> [CGFloat] {
        result.columns.indices.map { columnIndex in
            var maxLength = result.columns[columnIndex].count
            for row in result.rows.prefix(100) {
                maxLength = max(maxLength, (row[columnIndex] ?? "NULL").count)
            }
            return min(max(CGFloat(maxLength) * 8 + 18, 70), 380)
        }
    }
}
