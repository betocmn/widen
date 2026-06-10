import AppKit
import SwiftUI

/// Simple scrollable grid of stringified result values.
public struct QueryResultsView: View {
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Results")
                .font(.headline)
            Spacer()
            if let result = controller.queryVM.result {
                Text(summary(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy CSV") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.csv(), forType: .string)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func summary(for result: QueryResult) -> String {
        var parts = [
            "\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")",
            "\(result.executionTimeMs) ms",
        ]
        if result.truncated {
            parts.append("truncated at row limit")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        let queryVM = controller.queryVM
        if queryVM.isRunning {
            VStack(spacing: 8) {
                LoadingView(label: "Running query…")
                Button("Stop waiting") {
                    queryVM.cancelRun()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = queryVM.runError {
            VStack {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        } else if let result = queryVM.result {
            if result.columns.isEmpty {
                Text("The query returned no rows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(for: result)
            }
        } else {
            Text("Run a query to see results here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func grid(for result: QueryResult) -> some View {
        let widths = columnWidths(for: result)
        return ScrollView([.horizontal, .vertical]) {
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

extension QueryResultsView {
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
}
