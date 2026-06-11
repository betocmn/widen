import AppKit
import SwiftUI

/// Results-first face of a session, shown after the user approves a query:
/// the conversation collapses to a strip, the executed SQL stays visible as
/// a compact snippet, and the result grid takes the space. Submitting from
/// the composer returns to chat mode.
struct ResultsModeView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController

    var body: some View {
        @Bindable var chatVM = controller.chatVM

        VStack(spacing: 0) {
            CollapsedChatStrip(controller: controller)
            Divider()
            SQLSnippetView(controller: controller)
            Divider()
            resultsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ComposerView(text: $chatVM.input, isBusy: controller.chatVM.isGenerating) {
                Task { await controller.submit(appState: appState) }
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
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
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        } else if let result = queryVM.result {
            if result.columns.isEmpty {
                Text("The query returned no rows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header(for: result)
                    ResultsGridView(result: result)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            Text("Run a query to see results here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for result: QueryResult) -> some View {
        HStack(spacing: 8) {
            Text(summary(for: result))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy CSV") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.csv(), forType: .string)
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
}
