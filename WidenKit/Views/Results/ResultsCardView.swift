import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One run's results, rendered inline in the chat thread where its run
/// record sits — a permanent entry that scrolls up with the conversation.
/// The just-returned result is the item to look at, so it carries the muted
/// green highlight (a lighter shade than the SQL card's) on the section
/// around the table — the table itself keeps a neutral background. Once the
/// conversation moves on it settles to the same gray as the rest of the AI
/// output. Long results page through the materialized rows; Export CSV saves
/// the full result.
struct ResultsCardView: View {
    @Environment(AppState.self) private var appState
    let result: QueryResult
    let sessionTitle: String
    var isLatest = false
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(result)
            if result.columns.isEmpty {
                Text("The query returned no rows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ResultsGridView(
                    result: result,
                    rows: QueryResultDisplayPolicy.rows(result.rows, page: currentPage)
                )
                if result.rows.count > QueryResultDisplayPolicy.maxRowsPerPage {
                    paginationBar
                }
            }
        }
        .padding(10)
        .background(
            isLatest ? Color.green.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isLatest ? Color.green.opacity(0.3) : Color.primary.opacity(0.12))
        }
    }

    private var currentPage: Int {
        QueryResultDisplayPolicy.clampedPage(page, rowCount: result.rows.count)
    }

    private var pageCount: Int {
        QueryResultDisplayPolicy.pageCount(forRowCount: result.rows.count)
    }

    private var pageRangeText: String {
        guard
            let range = QueryResultDisplayPolicy.visibleRange(
                forRowCount: result.rows.count,
                page: currentPage
            )
        else { return "No rows" }
        return "Rows \(range.lowerBound + 1)-\(range.upperBound) of \(result.rows.count)"
    }

    private func header(_ result: QueryResult) -> some View {
        HStack(spacing: 8) {
            Label(summary(for: result), systemImage: "tablecells")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            AnimatedCopyButton(text: result.csv(), help: "Copy all rows as CSV")
            Button("Export CSV") {
                exportCSV(result)
            }
            .buttonStyle(.glass)
            .hoverBrightness()
            .controlSize(.small)
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 8) {
            Text(pageRangeText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                page = max(currentPage - 1, 0)
            } label: {
                Label("Previous page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage == 0)
            .help("Previous page")

            Text("\(currentPage + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)

            Button {
                page = min(currentPage + 1, pageCount - 1)
            } label: {
                Label("Next page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage >= pageCount - 1)
            .help("Next page")
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

    private func exportCSV(_ result: QueryResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = QueryResultExport.csvFilename(for: sessionTitle)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.errorBanner = "Could not export the CSV: \(error.localizedDescription)"
        }
    }
}
