import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One run's results, rendered inline in the chat thread where its run
/// record sits — a permanent entry that scrolls up with the conversation.
/// Styled like the SQL card but in a lighter shade so the two read as
/// related, distinct steps. Long results collapse to the first rows with a
/// "View more" toggle; Export CSV saves the full result.
struct ResultsCardView: View {
    @Environment(AppState.self) private var appState
    let result: QueryResult
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
        // Same family as the SQL card's tint, one shade lighter, with a
        // solid border where the pending SQL is dashed.
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.35))
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
