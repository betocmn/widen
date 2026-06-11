import AppKit
import SwiftUI

/// Bordered table of one materialized result's stringified values, sized to
/// its content so it can sit inline in the chat thread. Scrolls horizontally
/// for wide results; `maxRows` caps how many rows render (for the collapsed
/// "View more" state).
struct ResultsGridView: View {
    let result: QueryResult
    var maxRows: Int?

    private static let lineColor = Color.primary.opacity(0.12)

    private var displayRows: [[String?]] {
        guard let maxRows else { return result.rows }
        return Array(result.rows.prefix(maxRows))
    }

    var body: some View {
        let widths = columnWidths(for: result)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                rowView(
                    cells: result.columns,
                    widths: widths,
                    background: Color.primary.opacity(0.08),
                    isHeader: true
                )
                ForEach(displayRows.indices, id: \.self) { rowIndex in
                    rowView(
                        cells: displayRows[rowIndex],
                        widths: widths,
                        background: rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : Color.primary.opacity(0.04),
                        showTopSeparator: true
                    )
                }
            }
            // Opaque content background: any highlight tint on the card
            // around the table must not bleed through the data cells.
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Self.lineColor)
            }
            .padding(1)
        }
    }

    private func rowView(
        cells: [String?],
        widths: [CGFloat],
        background: Color,
        isHeader: Bool = false,
        showTopSeparator: Bool = false
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
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Self.lineColor.frame(width: 1)
                        }
                    }
            }
        }
        .background(background)
        .overlay(alignment: .top) {
            if showTopSeparator {
                Self.lineColor.frame(height: 1)
            }
        }
    }

    private func rowView(
        cells: [String],
        widths: [CGFloat],
        background: Color,
        isHeader: Bool = false,
        showTopSeparator: Bool = false
    ) -> some View {
        rowView(
            cells: cells.map(Optional.some),
            widths: widths,
            background: background,
            isHeader: isHeader,
            showTopSeparator: showTopSeparator
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
