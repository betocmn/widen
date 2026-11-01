import SwiftUI

/// Appearance, update and privacy settings. Particle-1 configuration lives in
/// the LLM tab.
struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let updater = appState.updaterControl, updater.isConfigured {
                Section("Updates") {
                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.automaticallyChecksForUpdates = $0 }
                        )
                    )
                    Button("Check for Updates Now…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }

            Section {
                Label(
                    "If you only want reads, connect with a read-only Postgres user for defense in depth.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(privacyCopy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link(
                    "Read the full privacy policy…",
                    destination: URL(
                        string: "https://github.com/betocmn/widen/blob/main/PRIVACY.md")!
                )
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private var privacyCopy: String {
        LLMSettingsView.privacyCopy
            + " Query results never leave your Mac unless you allow inspected values. Widen has no backend of its own."
    }
}
