import SwiftUI

/// Configuration for the two LLM backends — the on-device model and the
/// cloud pro provider — plus the developer mock toggle. Switching between
/// Local and Cloud happens with the toolbar toggle, not here.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var isCustomModel = false

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Local LLM") {
                LabeledContent("Model", value: Self.localModelName)
                Text(
                    "Free and included with your Mac. Generation runs entirely on this device — your questions and schema never leave it, and it works offline."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let message = appState.localModelAvailabilityMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Label("The on-device model is ready.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cloud LLM") {
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
                    "Switch between Local and Cloud with the toggle in the toolbar. Cloud models are used for SQL generation only; session titles always use the on-device model."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    /// e.g. "Apple Foundation Model · macOS 26.5" — the on-device model is
    /// versioned by the OS that ships it.
    private static var localModelName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Apple Foundation Model · macOS \(version.majorVersion).\(version.minorVersion)"
    }

    @ViewBuilder
    private var pccConfiguration: some View {
        switch appState.cloudBackendStatus {
        case .ready:
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
        case .notConfigured(let message), .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
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

        switch appState.cloudBackendStatus {
        case .ready:
            Label(
                "OpenRouter is ready — \(OpenRouterCatalog.displayName(for: appState.openRouterModelID)).",
                systemImage: "checkmark.circle"
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
        if appState.setOpenRouterAPIKey(key) {
            hasStoredKey = !key.isEmpty
        }
    }

    private func removeKey() {
        if appState.setOpenRouterAPIKey("") {
            apiKeyDraft = ""
            hasStoredKey = false
        }
    }
}
