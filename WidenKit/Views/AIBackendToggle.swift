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
                if appState.isLocalBackendVisible {
                    CapsuleSegmentButton(
                        icon: "shield.lefthalf.filled",
                        title: "On-Device — Experimental",
                        isSelected: appState.aiBackendMode == .local,
                        help: localHelp
                    ) {
                        select(.local)
                    }
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
        _ = appState.requestAIBackendMode(mode)
    }

    private var localHelp: String {
        if let message = appState.localModelAvailabilityMessage {
            return message
        }
        return "Generate SQL with Apple's on-device experimental model. It is limited to SELECT queries over narrow schema context; complex requests may require Cloud."
    }

    private var cloudHelp: String {
        switch appState.cloudBackendStatus {
        case .ready:
            if appState.cloudProvider == .openRouter {
                return "Generate SQL with \(OpenRouterCatalog.displayName(for: appState.openRouterModelID)) via OpenRouter. Widen requires endpoints that do not retain or collect the submitted question and schema context; inspected data values are sent only when this connection enables cloud data inspection."
            }
            return "Generate SQL with \(CloudAIProvider.applePCC.displayName). Cloud sends your question and allowed schema metadata; inspected data values are sent only when this connection enables cloud data inspection."
        case .notConfigured(let message), .unavailable(let message):
            return "\(message) Click to open Settings › LLM. This switch only picks the LLM used for SQL generation."
        }
    }
}
