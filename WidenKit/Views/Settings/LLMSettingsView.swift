import SwiftUI

/// Configuration for Particle-1, Widen's only text-to-SQL model, plus the
/// developer mock toggle.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Particle-1 — Beta") {
                particleConfiguration
                Text(
                    "Text-to-SQL sends your question and the schema metadata each connection allows to Particle (api.particle.ai) with your key. Inspected data values are sent only for connections that turn on cloud data inspection."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Developer") {
                Toggle("Use mock AI (developer)", isOn: $appState.useMockAI)
                if appState.useMockAI {
                    Text("Generation returns a constant test query while mock mode is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    "Particle-1 is Widen's only text-to-SQL model. Without a key you can still browse schemas and run SQL."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var particleConfiguration: some View {
        SecureField("API Key", text: $apiKeyDraft, prompt: Text("pai-…"))
            .onSubmit(saveKey)
        HStack {
            Button("Save Key", action: saveKey)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasStoredKey {
                Button("Remove Key", role: .destructive, action: removeKey)
            }
            Spacer()
            Link("Get an API key", destination: URL(string: "https://platform.particle.ai/")!)
                .font(.callout)
        }

        LabeledContent("Model", value: CloudModelCatalog.productionProfile.displayName)

        switch appState.textToSQLStatus {
        case .ready:
            Label(
                "\(CloudModelCatalog.productionProfile.displayName) is ready.",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .mock:
            Label(
                "Mock AI is on, so nothing is sent to Particle.",
                systemImage: "hammer"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .notConfigured(let message), .unavailable(let message):
            // The shared status text points at this pane; "above" reads
            // better when already here.
            Label(
                message.replacingOccurrences(of: " in Settings › LLM.", with: " above."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }

    private func load() {
        let stored = appState.loadParticleAPIKey() ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDraft = key
        if appState.setParticleAPIKey(key) {
            hasStoredKey = !key.isEmpty
        }
    }

    private func removeKey() {
        if appState.setParticleAPIKey("") {
            apiKeyDraft = ""
            hasStoredKey = false
        }
    }
}
