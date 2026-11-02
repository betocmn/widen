import SwiftUI

/// Toolbar status for text-to-SQL: which model answers, and a warning when
/// the key is missing or Particle refused it. Not a toggle — Particle-1 is
/// the only model — so clicking it opens Settings › LLM.
struct ParticleStatusChip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let status = appState.textToSQLStatus
        Button {
            appState.openSettings(tab: .llm)
        } label: {
            HStack(spacing: 6) {
                // Muted prefix so the chip reads as "which LLM generates the
                // SQL", not "is the database local or cloud". Hidden from
                // VoiceOver — the button already carries the full label.
                Text("LLM:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                icon(for: status)
                Text(status.chipTitle)
                    .font(.callout)
            }
            .lineLimit(1)
        }
        .help(help(for: status))
        .accessibilityLabel("Text-to-SQL model: \(CloudModelCatalog.productionProfile.displayName)")
        .accessibilityValue(accessibilityValue(for: status))
        .accessibilityHint("Opens Settings › LLM")
    }

    @ViewBuilder
    private func icon(for status: TextToSQLStatus) -> some View {
        switch status {
        case .ready:
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
        case .mock:
            Image(systemName: "hammer")
                .foregroundStyle(.secondary)
        case .notConfigured, .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func help(for status: TextToSQLStatus) -> String {
        switch status {
        case .ready:
            "Text-to-SQL uses Particle-1 (beta). Your question and allowed schema metadata go to Particle; inspected values only when this connection allows it. Click to open Settings › LLM."
        case .mock:
            "Mock AI is on: a developer generator returns a constant test query and nothing is sent to Particle. Click to open Settings › LLM."
        case .notConfigured(let message), .unavailable(let message):
            "\(message) Click to open Settings › LLM."
        }
    }

    private func accessibilityValue(for status: TextToSQLStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .mock: "Mock AI is on"
        case .notConfigured(let message), .unavailable(let message): message
        }
    }
}
