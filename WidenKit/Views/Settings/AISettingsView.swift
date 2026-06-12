import SwiftUI

/// Model selection (local vs cloud pro), cloud provider configuration, and
/// the developer mock toggle.
struct AISettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var isCustomModel = false

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Model") {
                Picker("Model", selection: $appState.aiBackendMode) {
                    Text("Local").tag(AIBackendMode.local)
                    Text("Cloud Pro").tag(AIBackendMode.cloud)
                }
                .pickerStyle(.segmented)
                statusLine
            }

            Section("Cloud Provider") {
                Picker("Provider", selection: $appState.cloudProvider) {
                    ForEach(CloudAIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                switch appState.cloudProvider {
                case .applePCC:
                    pccConfiguration
                case .openRouter:
                    openRouterConfiguration
                }
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
                    "Cloud models are used for SQL generation only. Session titles always use the on-device model."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = appState.modelAvailabilityMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            Label(
                "Ready — generating SQL with \(appState.activeBackendDisplayName).",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pccConfiguration: some View {
        if let message = PCCSupport.availabilityMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            Label(
                "Private Cloud Compute is ready. Generations are private and free, with a daily limit.",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let warning = PCCSupport.quotaWarning {
                HStack {
                    Label(warning, systemImage: "gauge.with.needle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if PCCSupport.hasLimitIncreaseSuggestion {
                        Button("Request More") {
                            PCCSupport.showLimitIncreaseSuggestion()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        Text(
            "Apple's server-side foundation model, announced at WWDC 2026. Requires macOS 27, Apple Intelligence, and a build signed with Apple's Private Cloud Compute entitlement."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var openRouterConfiguration: some View {
        @Bindable var appState = appState

        SecureField("API Key", text: $apiKeyDraft, prompt: Text("sk-or-…"))
            .onSubmit(saveKey)
        HStack {
            Button("Save Key", action: saveKey)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasStoredKey {
                Button("Remove Key", role: .destructive, action: removeKey)
            }
            Spacer()
            Link("Get an API key", destination: URL(string: "https://openrouter.ai/keys")!)
                .font(.callout)
        }

        Picker(
            "Model",
            selection: Binding(
                get: { isCustomModel ? Self.customTag : appState.openRouterModelID },
                set: { newValue in
                    if newValue == Self.customTag {
                        isCustomModel = true
                    } else {
                        isCustomModel = false
                        appState.openRouterModelID = newValue
                    }
                }
            )
        ) {
            ForEach(OpenRouterCatalog.curated) { option in
                Text(option.displayName).tag(option.id)
            }
            Divider()
            Text("Custom…").tag(Self.customTag)
        }
        if isCustomModel {
            TextField(
                "Model ID", text: $appState.openRouterModelID,
                prompt: Text("provider/model-id")
            )
            .autocorrectionDisabled()
        }
    }

    private static let customTag = "custom"

    private func load() {
        let stored = appState.loadOpenRouterAPIKey() ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
        isCustomModel = !OpenRouterCatalog.curated.contains { $0.id == appState.openRouterModelID }
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDraft = key
        appState.setOpenRouterAPIKey(key)
        hasStoredKey = !key.isEmpty
    }

    private func removeKey() {
        apiKeyDraft = ""
        appState.setOpenRouterAPIKey("")
        hasStoredKey = false
    }
}
