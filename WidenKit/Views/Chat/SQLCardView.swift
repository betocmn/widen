import AppKit
import SwiftUI

/// The newest SQL, the only runnable one, rendered inline in the chat
/// transcript. Read-only by design — the user refines it by chatting or by
/// pasting new SQL into the composer. Validation issues and generation
/// details appear on hover; referenced tables sit in a single caption row.
///
/// Color system: the user owns blue, settled AI output is plain gray, and a
/// muted green marks the single item awaiting attention. This card carries
/// the highlight only until its run answers it; the dashed border stays as
/// the "runnable" marker.
struct SQLCardView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController
    var isAwaitingRun = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(controller.queryVM.sqlText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let generation = controller.queryVM.generation {
                footer(generation)
            }
        }
        .padding(10)
        .background(
            isAwaitingRun ? Color.green.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isAwaitingRun ? Color.green.opacity(0.45) : Color.primary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SQL")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            statusIcon
            Spacer()
            CopySQLButton(text: controller.queryVM.sqlText)
            Button("Run") {
                controller.runQuery(appState: appState)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(runDisabled)
            .help("Approve and execute this query")
        }
    }

    private var runDisabled: Bool {
        let queryVM = controller.queryVM
        return queryVM.isRunning
            || queryVM.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || queryVM.validation?.isValid == false
            || appState.connectionState(controller.connectionID) != .connected
    }

    /// Compact validation status. The messages themselves appear on hover.
    @ViewBuilder
    private var statusIcon: some View {
        if let validation = controller.queryVM.validation {
            let issueCount = validation.errors.count + validation.warnings.count
            HoverPopoverAnchor(isEnabled: issueCount > 0) {
                HStack(spacing: 3) {
                    Image(systemName: statusSymbol(validation))
                    if issueCount > 0 {
                        Text("\(issueCount)")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(statusColor(validation))
                .help(statusHelp(validation))
            } content: {
                issuesList(validation)
            }
        }
    }

    private func issuesList(_ validation: SQLValidationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(validation.errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(validation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func statusSymbol(_ validation: SQLValidationResult) -> String {
        if !validation.isValid { return "xmark.octagon.fill" }
        return validation.warnings.isEmpty
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ validation: SQLValidationResult) -> Color {
        if !validation.isValid { return .red }
        return validation.warnings.isEmpty ? .green : .orange
    }

    private func statusHelp(_ validation: SQLValidationResult) -> String {
        if !validation.isValid { return "Blocked — hover for details" }
        return validation.warnings.isEmpty ? "Valid" : "Valid with warnings — hover for details"
    }

    private func footer(_ generation: SQLGenerationResult) -> some View {
        HStack(spacing: 10) {
            if !generation.explanation.isEmpty || !generation.assumptions.isEmpty {
                HoverPopoverAnchor(isEnabled: true) {
                    Image(systemName: "info.circle")
                        .help("Explanation and assumptions")
                } content: {
                    detailsView(generation)
                }
            }
            if !generation.referencedTables.isEmpty {
                Label(
                    generation.referencedTables.joined(separator: ", "),
                    systemImage: "tablecells"
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func detailsView(_ generation: SQLGenerationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !generation.explanation.isEmpty {
                Text(generation.explanation)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            ForEach(generation.assumptions, id: \.self) { assumption in
                Label(assumption, systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A superseded SQL statement, kept in the transcript as a permanent record.
/// Settled AI gray, copy only — the newest SQL card is the only runnable one.
struct StaticSQLCardView: View {
    let sql: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SQL")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                CopySQLButton(text: sql)
            }
            Text(sql)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        }
    }
}

/// Shows a popover while the pointer is over the label or the popover itself.
private struct HoverPopoverAnchor<Label: View, Content: View>: View {
    let isEnabled: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    @State private var isPresented = false
    @State private var isHoveringLabel = false
    @State private var isHoveringPopover = false

    var body: some View {
        label()
            .onHover { isHoveringLabel = $0; syncPresentation() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                content()
                    .padding(12)
                    .frame(width: 320, alignment: .leading)
                    .onHover { isHoveringPopover = $0; syncPresentation() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isPresented = false }
            }
    }

    private func syncPresentation() {
        isPresented = isEnabled && (isHoveringLabel || isHoveringPopover)
    }
}

private struct CopySQLButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeInOut(duration: 0.2)) {
                didCopy = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeInOut(duration: 0.2)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .foregroundStyle(didCopy ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(didCopy ? "Copied" : "Copy SQL")
    }
}
