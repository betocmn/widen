import SwiftUI

/// Toolbar switch between the on-device model and the configured cloud pro
/// model, drawn as a two-segment capsule with icon + label per side. Custom
/// control on purpose: a segmented `Picker` in the macOS 26 toolbar collapses
/// to cramped icon-only segments. Plain content + a flat selection highlight
/// keeps the system glass pill as the only rounded container.
///
/// When no cloud backend is usable, choosing Cloud opens Settings › LLM
/// instead of silently failing; a cloud mode that broke after being enabled
/// shows a warning icon and can still be returned to Local.
struct AIBackendToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            // Muted prefix so the toggle reads as "which LLM generates the
            // SQL", not "is the database local or cloud". Hidden from
            // VoiceOver — the container already carries the "LLM backend" label.
            Text("LLM:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                CapsuleSegmentButton(
                    icon: "shield.lefthalf.filled",
                    title: "Local",
                    isSelected: appState.aiBackendMode == .local,
                    help: localHelp
                ) {
                    select(.local)
                }
                CapsuleSegmentButton(
                    icon: isCloudBroken ? "exclamationmark.icloud.fill" : "cloud.fill",
                    title: "Cloud",
                    isSelected: appState.aiBackendMode == .cloud,
                    isWarning: isCloudBroken,
                    help: cloudHelp
                ) {
                    select(.cloud)
                }
            }
        }
        // Asymmetric: the bare "LLM:" text needs breathing room from the glass
        // pill's leading edge (matching the breadcrumb's 10pt), while the
        // trailing side ends in a capsule button that already carries its own
        // internal padding.
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("LLM backend")
    }

    private var isCloudBroken: Bool {
        appState.aiBackendMode == .cloud && appState.cloudBackendStatus != .ready
    }

    private func select(_ mode: AIBackendMode) {
        switch mode {
        case .local:
            appState.aiBackendMode = .local
        case .cloud:
            if case .ready = appState.cloudBackendStatus {
                appState.aiBackendMode = .cloud
            } else {
                appState.openSettings(tab: .llm)
            }
        }
    }

    private var localHelp: String {
        "Generate SQL with Apple's on-device model — your questions and schema stay on this Mac. This switch only picks the LLM that turns questions into SQL; nothing else moves to the cloud."
    }

    private var cloudHelp: String {
        switch appState.cloudBackendStatus {
        case .ready:
            "Generate SQL with \(appState.cloudProvider == .applePCC ? CloudAIProvider.applePCC.displayName : "\(OpenRouterCatalog.displayName(for: appState.openRouterModelID)) via OpenRouter"). Only your question and the relevant schema are sent to that provider — your database connection and query results never leave this Mac."
        case .notConfigured(let message), .unavailable(let message):
            "\(message) Click to open Settings › LLM. This switch only picks the LLM used for SQL generation."
        }
    }
}
