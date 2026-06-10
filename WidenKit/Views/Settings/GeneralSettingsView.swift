import SwiftUI

/// Appearance, AI, and privacy settings.
struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("AI") {
                Toggle("Use mock AI (developer)", isOn: $appState.useMockAI)
                if let message = appState.modelAvailabilityMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if appState.useMockAI {
                    Text("Generation returns a constant test query while mock mode is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Apple's on-device model is ready.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Label(
                    "For safety, connect with a read-only Postgres user when using AI-generated SQL.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(
                    "Widen runs locally. It sends prompts to Apple's local Foundation Model through macOS. It does not send your database schema or queries to our servers. This MVP has no backend."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
