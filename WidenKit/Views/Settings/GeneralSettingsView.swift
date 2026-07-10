import SwiftUI

/// Appearance and privacy settings. AI configuration lives in the AI tab.
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
            }
        }
        .formStyle(.grouped)
    }

    private var privacyCopy: String {
        if appState.aiBackendMode == .cloud {
            if appState.cloudProvider == .openRouter {
                return "With OpenRouter Cloud selected, Widen sends your question and allowed schema metadata through endpoints that are required not to retain or collect that submitted context. Inspected data values are sent only when cloud data inspection is enabled for that connection. Query results never leave your Mac unless you explicitly inspect and allow those values. Widen has no backend of its own."
            }
            return "With Cloud selected, Widen sends your question and allowed schema metadata to the provider selected in Settings › LLM. Inspected data values are sent only when cloud data inspection is enabled for that connection. Query results never leave your Mac unless you explicitly inspect and allow those values. Widen has no backend of its own."
        } else {
            return "With Local selected, Widen sends prompts to Apple's local Foundation Model through macOS. It does not send your database schema, questions, or query results to our servers. Widen has no backend of its own."
        }
    }
}
