import SwiftUI

/// Toolbar switch between the on-device model and the configured cloud pro
/// model. When no cloud backend is usable, choosing Cloud guides the user to
/// Settings › AI instead of silently failing; a cloud mode that broke after
/// being enabled shows a warning icon and can still be returned to Local.
struct AIBackendToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Picker("LLM", selection: backendMode) {
            Label("Local", systemImage: "lock.shield")
                .tag(AIBackendMode.local)
            Label("Cloud", systemImage: cloudIcon)
                .tag(AIBackendMode.cloud)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("LLM backend")
    }

    private var backendMode: Binding<AIBackendMode> {
        Binding(
            get: { appState.aiBackendMode },
            set: { select($0) }
        )
    }

    private var cloudIcon: String {
        if appState.aiBackendMode == .cloud, appState.cloudBackendStatus != .ready {
            "exclamationmark.icloud"
        } else {
            "cloud"
        }
    }

    private func select(_ mode: AIBackendMode) {
        switch mode {
        case .local:
            appState.aiBackendMode = .local
        case .cloud:
            if case .ready = appState.cloudBackendStatus {
                appState.aiBackendMode = .cloud
            } else {
                appState.openSettings(tab: .ai)
            }
        }
    }

    private var helpText: String {
        switch (appState.aiBackendMode, appState.cloudBackendStatus) {
        case (.cloud, .ready):
            "Using \(appState.activeBackendDisplayName) for LLM SQL generation. Questions and relevant schema may go to the selected provider; database connections and query results do not."
        case (.cloud, _):
            "\(appState.cloudBackendStatus.message ?? "The cloud model is unavailable.") This setting only controls the LLM used for SQL generation; choose Local to keep generation on this Mac."
        case (.local, .ready):
            "Using the local model for LLM SQL generation. This does not send everything to the cloud; choose Cloud only to use \(appState.cloudProvider.displayName) for generation."
        case (.local, _):
            "Using the local model for LLM SQL generation. Cloud needs setup in Settings › AI; this toggle only affects the model that turns questions into SQL."
        }
    }
}
