import SwiftUI

/// Configuration for the two LLM backends — the on-device model and the
/// cloud pro provider — plus the developer mock toggle. Switching between
/// Local and Cloud happens with the toolbar toggle, not here.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var modelMetadata: OpenRouterModelMetadata?
    @State private var catalogMessage: String?
    @State private var catalogMessageIsWarning = false
    @State private var catalogRefreshID = UUID()
    @State private var isLoadingCatalog = false
    @State private var isTestingModel = false
    @State private var modelTestResult: OpenRouterModelTestResult?

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Cloud LLM") {
                Picker("Provider", selection: $appState.cloudProvider) {
                    ForEach(CloudAIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                            .disabled(provider == .applePCC && !PCCSupport.isRuntimeSupported)
                    }
                }
                switch appState.cloudProvider {
                case .applePCC:
                    pccConfiguration
                case .openRouter:
                    openRouterConfiguration
                }
                Text(cloudPrivacyDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if appState.isLocalBackendVisible {
                Section("On-Device — Experimental") {
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
                    appState.isLocalBackendVisible
                        ? "Switch between Cloud and Local with the toggle in the toolbar. Cloud is the default for text-to-SQL; session titles use the on-device model when available, otherwise a local deterministic fallback."
                        : "Cloud is the text-to-SQL backend on this Mac. You can still browse schemas and run SQL manually without configuring a cloud model."
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

    private var localModelDescription: String {
        switch appState.localLLMEligibility {
        case .ready:
            return "Free and included with your Mac. Generation runs entirely on this device and works offline. This experimental mode is constrained to narrow SELECT requests; complex questions may require Cloud."
        case .appleIntelligenceDisabled:
            return "Local generation runs entirely on this device after Apple Intelligence is enabled in System Settings › Apple Intelligence & Siri."
        default:
            return "On-device generation runs entirely on this Mac when Apple's local model is available."
        }
    }

    private var cloudPrivacyDescription: String {
        if appState.cloudProvider == .openRouter {
            return "Cloud SQL generation sends the question and allowed schema metadata to OpenRouter. Widen requires endpoints that neither retain nor collect the submitted question and schema context. Inspected data values are sent only for connections where cloud data inspection is explicitly enabled."
        }
        return "Cloud SQL generation sends the question and allowed schema metadata to the selected provider. Inspected data values are sent only for connections where cloud data inspection is explicitly enabled."
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
            "Apple cloud model support is planned when Apple's required OS and SDK support is available. This option remains unavailable unless the app is compiled with that support and the current Mac can run it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var openRouterConfiguration: some View {
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

        let profile = OpenRouterCatalog.productionProfile
        LabeledContent("Model", value: profile.displayName)
        LabeledContent("Requested ID", value: profile.requestedModelID)
        LabeledContent("Evaluated version", value: profile.expectedCanonicalModelID)
        HStack {
            Spacer()
            Button {
                refreshOpenRouterCatalog(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!hasStoredKey || isLoadingCatalog)
            .help("Refresh OpenRouter model capabilities")
        }
        if isLoadingCatalog {
            ProgressView("Refreshing OpenRouter model…")
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
                "OpenRouter is ready — \(profile.displayName).",
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

    @ViewBuilder
    private var selectedModelCapabilities: some View {
        if let metadata = modelMetadata {
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
                .disabled(!hasStoredKey || isTestingModel)

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

    private func catalogRefreshStillCurrent(apiKey key: String, refreshID: UUID) -> Bool {
        guard catalogRefreshID == refreshID else { return false }
        guard requestStillMatches(apiKey: key) else {
            isLoadingCatalog = false
            return false
        }
        return true
    }

    private func load() {
        let stored = appState.loadOpenRouterAPIKey() ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
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
            catalogRefreshID = UUID()
            modelMetadata = nil
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
            catalogRefreshID = UUID()
            modelMetadata = nil
            catalogMessage = nil
            isLoadingCatalog = false
            return
        }
        let refreshID = UUID()
        catalogRefreshID = refreshID
        isLoadingCatalog = true
        let selectedModel = OpenRouterCatalog.productionProfile.requestedModelID
        Task {
            if let metadata = await OpenRouterModelCatalogService.shared.metadata(
                apiKey: key,
                modelID: selectedModel,
                forceRefresh: force
            ) {
                await MainActor.run {
                    guard catalogRefreshStillCurrent(apiKey: key, refreshID: refreshID) else { return }
                    modelMetadata = metadata
                    catalogMessage = metadata.isAvailableToAPIKey
                        ? "Authenticated model metadata loaded."
                        : "The fixed model was not visible to the saved OpenRouter key."
                    catalogMessageIsWarning = !metadata.isAvailableToAPIKey
                        || metadata.capabilitySource == .staleCache
                    isLoadingCatalog = false
                }
            } else {
                await MainActor.run {
                    guard catalogRefreshStillCurrent(apiKey: key, refreshID: refreshID) else { return }
                    modelMetadata = nil
                    catalogMessage = "Could not load the fixed OpenRouter model metadata."
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
        let profile = OpenRouterCatalog.productionProfile
        let model = profile.requestedModelID
        Task {
            await OpenRouterModelCatalogService.shared.invalidate(apiKey: key, modelID: model)
            let result = await OpenRouterConnectivityCheck(
                apiKey: key,
                model: model,
                expectedCanonicalModelID: profile.expectedCanonicalModelID
            ).run()
            await MainActor.run {
                guard requestStillMatches(apiKey: key) else {
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
