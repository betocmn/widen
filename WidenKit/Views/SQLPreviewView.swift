import AppKit
import SwiftUI

/// Editable SQL area with validation status and run controls.
public struct SQLPreviewView: View {
    @Environment(AppState.self) private var appState
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var queryVM = controller.queryVM

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SQL")
                    .font(.headline)
                validationBadge
                Spacer()
                Button("Validate") {
                    queryVM.validate()
                }
                .buttonStyle(.glass)
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(queryVM.sqlText, forType: .string)
                }
                .buttonStyle(.glass)
                .disabled(queryVM.sqlText.isEmpty)
                Button("Clear") {
                    queryVM.clear()
                }
                .buttonStyle(.glass)
                .disabled(queryVM.sqlText.isEmpty)
                Button("Run") {
                    controller.runQuery(appState: appState)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    queryVM.isRunning
                        || queryVM.sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || appState.connectionState(controller.connectionID) != .connected
                )
            }

            TextEditor(text: $queryVM.sqlText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 70)

            if let validation = controller.queryVM.validation {
                VStack(alignment: .leading, spacing: 2) {
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

            if let generation = controller.queryVM.generation {
                generationDetails(generation)
            }
        }
        .padding(10)
    }

    private func generationDetails(_ generation: SQLGenerationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(
                    "Confidence \(Int((generation.confidence * 100).rounded()))%",
                    systemImage: "gauge.with.needle"
                )
                Label("Risk \(generation.riskLevel.rawValue)", systemImage: riskIcon(generation.riskLevel))
                    .foregroundStyle(riskColor(generation.riskLevel))
                if !generation.referencedTables.isEmpty {
                    Label(
                        generation.referencedTables.joined(separator: ", "),
                        systemImage: "tablecells"
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(generation.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ForEach(generation.assumptions, id: \.self) { assumption in
                Label(assumption, systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func riskIcon(_ risk: SQLRiskLevel) -> String {
        switch risk {
        case .low: "checkmark.shield"
        case .medium: "exclamationmark.shield"
        case .high: "xmark.shield"
        }
    }

    private func riskColor(_ risk: SQLRiskLevel) -> Color {
        switch risk {
        case .low: .secondary
        case .medium: Color.orange
        case .high: Color.red
        }
    }

    @ViewBuilder
    private var validationBadge: some View {
        if let validation = controller.queryVM.validation {
            if validation.isValid {
                Label(
                    validation.warnings.isEmpty ? "Valid" : "Valid with warnings",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption)
                .foregroundStyle(validation.warnings.isEmpty ? .green : .orange)
            } else {
                Label("Blocked", systemImage: "xmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
