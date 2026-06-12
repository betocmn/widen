import SwiftUI

/// Toolbar switch between the on-device model and the configured cloud pro
/// model. When no cloud backend is usable, clicking guides the user to
/// Settings › AI instead of silently failing; a cloud mode that broke after
/// being enabled shows a warning icon and clicking returns to local.
struct AIBackendToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let isCloud = appState.aiBackendMode == .cloud
        let isBroken = isCloud && appState.cloudBackendStatus != .ready

        Button {
            toggle()
        } label: {
            if isBroken {
                label(isCloud: isCloud, isBroken: isBroken)
                    .foregroundStyle(.orange)
            } else {
                label(isCloud: isCloud, isBroken: isBroken)
            }
        }
        .help(helpText)
    }

    private func label(isCloud: Bool, isBroken: Bool) -> some View {
        Label(
            isCloud ? "Switch to Local Model" : "Switch to Cloud Pro Model",
            systemImage: isBroken
                ? "exclamationmark.icloud"
                : (isCloud ? "cloud.fill" : "desktopcomputer")
        )
    }

    private func toggle() {
        switch appState.aiBackendMode {
        case .cloud:
            appState.aiBackendMode = .local
        case .local:
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
            "Using \(appState.activeBackendDisplayName). Click to switch to the local model."
        case (.cloud, _):
            "\(appState.cloudBackendStatus.message ?? "The cloud model is unavailable.") Click to switch back to the local model."
        case (.local, .ready):
            "Using the local model. Click to switch to \(appState.cloudProvider.displayName)."
        case (.local, _):
            "Using the local model. The cloud pro model needs setup — click to open Settings › AI."
        }
    }
}
