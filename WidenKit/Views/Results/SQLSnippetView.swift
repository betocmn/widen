import AppKit
import SwiftUI

/// Compact read-only view of the executed SQL shown in results mode.
/// Collapsed to three lines; expandable, copyable, re-runnable.
struct SQLSnippetView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(controller.queryVM.sqlText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Collapse SQL" : "Expand SQL")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.queryVM.sqlText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy SQL")
            Button("Re-run") {
                controller.runQuery(appState: appState)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(runDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var runDisabled: Bool {
        let queryVM = controller.queryVM
        return queryVM.isRunning
            || queryVM.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || queryVM.validation?.isValid == false
            || appState.connectionState(controller.connectionID) != .connected
    }
}
