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
        HStack(spacing: 2) {
            segment(
                mode: .local,
                title: "Local",
                icon: "shield.lefthalf.filled",
                help: localHelp
            )
            segment(
                mode: .cloud,
                title: "Cloud",
                icon: isCloudBroken ? "exclamationmark.icloud.fill" : "cloud.fill",
                help: cloudHelp
            )
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("LLM backend")
    }

    private func segment(
        mode: AIBackendMode, title: String, icon: String, help: String
    ) -> some View {
        let isSelected = appState.aiBackendMode == mode
        let isWarning = mode == .cloud && isCloudBroken
        return Button {
            select(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.callout)
            }
            .foregroundStyle(
                isWarning
                    ? AnyShapeStyle(.orange)
                    : (isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule().fill(.primary.opacity(0.12))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
