import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One run's results, rendered inline in the chat thread where its run
/// record sits — a permanent entry that scrolls up with the conversation.
/// The just-returned result is the item to look at, so it carries the muted
/// green highlight (a lighter shade than the SQL card's) on the section
/// around the table — the table itself keeps a neutral background. Once the
/// conversation moves on it settles to the same gray as the rest of the AI
/// output. Long results collapse to the first rows with a "View more"
/// toggle; Export CSV saves the full result.
struct ResultsCardView: View {
    @Environment(AppState.self) private var appState
    let result: QueryResult
    var isLatest = false
    @State private var isExpanded = false

    private static let collapsedRowCount = 10

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
                    maxRows: isExpanded ? nil : Self.collapsedRowCount
                )
                if result.rows.count > Self.collapsedRowCount {
                    Button(isExpanded ? "View less" : "View more (\(result.rows.count - Self.collapsedRowCount) more rows)") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
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

    private func header(_ result: QueryResult) -> some View {
        HStack(spacing: 8) {
            Label(summary(for: result), systemImage: "tablecells")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.csv(), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy as CSV")
            Button("Export CSV") {
                exportCSV(result)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
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
        panel.nameFieldStringValue = "results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.errorBanner = "Could not export the CSV: \(error.localizedDescription)"
        }
    }
}
