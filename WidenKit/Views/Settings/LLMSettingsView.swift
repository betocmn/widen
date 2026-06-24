import SwiftUI

/// Configuration for the two LLM backends — the on-device model and the
/// cloud pro provider — plus the developer mock toggle. Switching between
/// Local and Cloud happens with the toolbar toggle, not here.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var isCustomModel = false
    @State private var catalogModels: [OpenRouterModelMetadata] = []
    @State private var catalogMessage: String?
    @State private var catalogMessageIsWarning = false
    @State private var isLoadingCatalog = false
    @State private var isTestingModel = false
    @State private var modelTestResult: OpenRouterModelTestResult?

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Local LLM") {
                LabeledContent("Model", value: Self.localModelName)
                Text(localModelDescription)
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
                    "Switch between Local and Cloud with the toggle in the toolbar. Cloud models are used for SQL generation only; session titles use the on-device model when available, otherwise a local deterministic fallback."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: appState.openRouterModelID) { _, _ in
            modelTestResult = nil
            if isKnownModelID(appState.openRouterModelID) {
                isCustomModel = false
                refreshOpenRouterCatalog(force: true)
            } else {
                isCustomModel = true
            }
        }
    }

    /// e.g. "Apple Foundation Model · macOS 26.5" — the on-device model is
    /// versioned by the OS that ships it.
    private static var localModelName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Apple Foundation Model · macOS \(version.majorVersion).\(version.minorVersion)"
    }

    private var localModelDescription: String {
        switch appState.localLLMEligibility {
        case .ready:
            return "Free and included with your Mac. Generation runs entirely on this device — your questions and schema never leave it, and it works offline."
        case .appleIntelligenceDisabled:
            return "Local generation runs entirely on this device after Apple Intelligence is enabled in System Settings › Apple Intelligence & Siri."
        default:
            return "Local generation runs entirely on this device when Apple's local model is available."
        }
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
            ForEach(modelPickerRows) { option in
                Text(option.title).tag(option.id)
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
        if isLoadingCatalog {
            ProgressView("Refreshing OpenRouter models…")
        }
        if let catalogMessage {
            Label(
                catalogMessage,
                systemImage: catalogMessageIsWarning ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(catalogMessageIsWarning ? .orange : .secondary)
        }

        selectedModelCapabilities
        testModelControls

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

    private func isKnownModelID(
        _ id: String,
        in catalog: [OpenRouterModelMetadata]? = nil
    ) -> Bool {
        OpenRouterCatalog.curated.contains { $0.id == id }
            || (catalog ?? catalogModels).contains {
                ($0.id == id || $0.requestedID == id) && $0.isAvailableToAPIKey
            }
    }

    private var modelPickerRows: [OpenRouterModelPickerRow] {
        var rowsByID: [String: OpenRouterModelPickerRow] = [:]
        for option in OpenRouterCatalog.curated {
            let metadata = catalogModels.first { $0.id == option.id || $0.requestedID == option.id }
            rowsByID[option.id] = OpenRouterModelPickerRow(
                id: option.id,
                displayName: option.displayName,
                capabilities: metadata?.capabilities,
                isUnavailable: metadata?.isAvailableToAPIKey == false,
                isStale: metadata?.capabilitySource == .staleCache
            )
        }
        for metadata in catalogModels {
            let id = metadata.requestedID
            rowsByID[id] = OpenRouterModelPickerRow(
                id: id,
                displayName: metadata.displayName,
                capabilities: metadata.capabilities,
                isUnavailable: !metadata.isAvailableToAPIKey,
                isStale: metadata.capabilitySource == .staleCache
            )
        }
        if rowsByID[appState.openRouterModelID] == nil, !appState.openRouterModelID.isEmpty {
            rowsByID[appState.openRouterModelID] = OpenRouterModelPickerRow(
                id: appState.openRouterModelID,
                displayName: OpenRouterCatalog.displayName(for: appState.openRouterModelID),
                capabilities: nil,
                isUnavailable: hasStoredKey && !catalogModels.isEmpty,
                isStale: false
            )
        }
        return rowsByID.values.sorted { lhs, rhs in
            if lhs.isUnavailable != rhs.isUnavailable { return !lhs.isUnavailable }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    @ViewBuilder
    private var selectedModelCapabilities: some View {
        let metadata = catalogModels.first {
            $0.id == appState.openRouterModelID || $0.requestedID == appState.openRouterModelID
        }
        if let metadata {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    CapabilityBadge("Structured output", isEnabled: metadata.capabilities.supportsStructuredOutputs)
                    CapabilityBadge("Tools", isEnabled: metadata.capabilities.supportsTools)
                    if let contextLength = metadata.contextLength {
                        Text("\(contextLength.formatted()) context")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                if metadata.capabilitySource == .staleCache {
                    Text("Showing stale cached model metadata.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !metadata.isAvailableToAPIKey {
                    Text("This model was not visible to the saved OpenRouter key.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if hasStoredKey {
            Text("Model capabilities are unknown until the catalog refresh succeeds.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testModelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    testModel()
                } label: {
                    if isTestingModel {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing Model")
                    } else {
                        Text("Test Model")
                    }
                }
                .disabled(!hasStoredKey || isTestingModel || appState.openRouterModelID.isEmpty)

                Text("Sends one tiny completion and may incur a very small charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let modelTestResult {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    statusRow("Key", modelTestResult.keyAccepted ? "accepted" : "rejected")
                    statusRow(
                        "Selected model",
                        modelTestResult.selectedModelAvailable ? "available" : "not visible"
                    )
                    statusRow(
                        "Structured output",
                        modelTestResult.capabilities.supportsStructuredOutputs ? "supported" : "not advertised"
                    )
                    statusRow(
                        "Tools",
                        modelTestResult.capabilities.supportsTools ? "supported" : "not advertised"
                    )
                    statusRow(
                        "Context",
                        modelTestResult.capabilities.contextLength.map { "\($0.formatted()) tokens" } ?? "unknown"
                    )
                    statusRow("Returned model", modelTestResult.returnedModelID ?? "-")
                    statusRow("Provider", modelTestResult.providerName ?? "-")
                    statusRow("Latency", "\(modelTestResult.latencyMs) ms")
                    statusRow("Retries", "\(modelTestResult.retryCount)")
                    if let error = modelTestResult.error {
                        statusRow("Error", "\(error.category.rawValue): \(error.message)")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func requestStillMatches(apiKey key: String) -> Bool {
        let currentKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasStoredKey && !currentKey.isEmpty && currentKey == key
    }

    private func load() {
        let stored = appState.loadOpenRouterAPIKey() ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
        isCustomModel = !isKnownModelID(appState.openRouterModelID)
        refreshOpenRouterCatalog(force: false)
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDraft = key
        if appState.setOpenRouterAPIKey(key) {
            hasStoredKey = !key.isEmpty
            modelTestResult = nil
            Task {
                await OpenRouterModelCatalogService.shared.invalidate(apiKey: key)
                await MainActor.run {
                    refreshOpenRouterCatalog(force: true)
                }
            }
        }
    }

    private func removeKey() {
        if appState.setOpenRouterAPIKey("") {
            apiKeyDraft = ""
            hasStoredKey = false
            catalogModels = []
            catalogMessage = nil
            isLoadingCatalog = false
            isTestingModel = false
            modelTestResult = nil
            Task {
                await OpenRouterModelCatalogService.shared.invalidate()
            }
        }
    }

    private func refreshOpenRouterCatalog(force: Bool) {
        guard hasStoredKey,
            let key = appState.loadOpenRouterAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            catalogModels = []
            catalogMessage = nil
            return
        }
        isLoadingCatalog = true
        let selectedModel = appState.openRouterModelID
        Task {
            do {
                let models = try await OpenRouterModelCatalogService.shared.availableModels(
                    apiKey: key,
                    forceRefresh: force
                )
                if models.contains(where: { $0.id == selectedModel || $0.requestedID == selectedModel }) {
                    await MainActor.run {
                        guard requestStillMatches(apiKey: key) else { return }
                        catalogModels = models
                        isCustomModel = !isKnownModelID(appState.openRouterModelID, in: models)
                        catalogMessage = "Authenticated model catalog loaded."
                        catalogMessageIsWarning = models.contains { $0.capabilitySource == .staleCache }
                        isLoadingCatalog = false
                    }
                } else if let custom = await OpenRouterModelCatalogService.shared.metadata(
                    apiKey: key,
                    modelID: selectedModel,
                    forceRefresh: force
                ) {
                    await MainActor.run {
                        guard requestStillMatches(apiKey: key) else { return }
                        let currentModel = appState.openRouterModelID
                        if currentModel == selectedModel {
                            catalogModels = models + [custom]
                            isCustomModel = !isKnownModelID(currentModel, in: models + [custom])
                            catalogMessage = "Authenticated model catalog loaded; selected model came from single-model lookup."
                            catalogMessageIsWarning = custom.capabilitySource == .staleCache
                        } else {
                            catalogModels = models
                            isCustomModel = !isKnownModelID(currentModel, in: models)
                            catalogMessage = "Authenticated model catalog loaded."
                            catalogMessageIsWarning = models.contains { $0.capabilitySource == .staleCache }
                        }
                        isLoadingCatalog = false
                    }
                } else {
                    await MainActor.run {
                        guard requestStillMatches(apiKey: key) else { return }
                        catalogModels = models
                        let currentModel = appState.openRouterModelID
                        isCustomModel = !isKnownModelID(currentModel, in: models)
                        if currentModel == selectedModel {
                            catalogMessage = "Authenticated catalog loaded, but the selected model was not visible."
                            catalogMessageIsWarning = true
                        } else {
                            catalogMessage = "Authenticated model catalog loaded."
                            catalogMessageIsWarning = models.contains { $0.capabilitySource == .staleCache }
                        }
                        isLoadingCatalog = false
                    }
                }
            } catch {
                await MainActor.run {
                    guard requestStillMatches(apiKey: key) else { return }
                    catalogMessage = "Could not refresh OpenRouter model catalog: \(error.localizedDescription)"
                    catalogMessageIsWarning = true
                    isLoadingCatalog = false
                }
            }
        }
    }

    private func testModel() {
        guard let key = appState.loadOpenRouterAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            return
        }
        isTestingModel = true
        modelTestResult = nil
        let model = appState.openRouterModelID
        Task {
            await OpenRouterModelCatalogService.shared.invalidate(apiKey: key, modelID: model)
            let result = await OpenRouterConnectivityCheck(apiKey: key, model: model).run()
            await MainActor.run {
                guard requestStillMatches(apiKey: key), appState.openRouterModelID == model else {
                    isTestingModel = false
                    return
                }
                modelTestResult = OpenRouterModelTestResult(result)
                isTestingModel = false
                refreshOpenRouterCatalog(force: false)
            }
        }
    }
}

private struct OpenRouterModelPickerRow: Identifiable {
    var id: String
    var displayName: String
    var capabilities: OpenRouterModelCapabilities?
    var isUnavailable: Bool
    var isStale: Bool

    var title: String {
        var badges: [String] = []
        if capabilities?.supportsStructuredOutputs == true {
            badges.append("Structured output")
        }
        if capabilities?.supportsTools == true {
            badges.append("Tools")
        }
        if let contextLength = capabilities?.contextLength {
            badges.append("\(contextLength.formatted()) context")
        }
        if isStale {
            badges.append("Stale")
        }
        if isUnavailable {
            badges.append("Unavailable")
        }
        return badges.isEmpty ? displayName : "\(displayName) · \(badges.joined(separator: " · "))"
    }
}

private struct OpenRouterModelTestResult: Equatable {
    var keyAccepted: Bool
    var selectedModelAvailable: Bool
    var capabilities: OpenRouterModelCapabilities
    var returnedModelID: String?
    var providerName: String?
    var latencyMs: Int
    var retryCount: Int
    var error: OpenRouterFailure?

    init(_ result: OpenRouterConnectivityCheck.Result) {
        keyAccepted = result.keyAccepted
        selectedModelAvailable = result.selectedModelAvailable
        capabilities = result.capabilities
        returnedModelID = result.returnedModelID
        providerName = result.providerName
        latencyMs = result.latencyMs
        retryCount = result.retryCount
        error = result.error
    }
}

private struct CapabilityBadge: View {
    let title: String
    let isEnabled: Bool

    init(_ title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isEnabled ? .green.opacity(0.15) : .secondary.opacity(0.10), in: Capsule())
    }
}
