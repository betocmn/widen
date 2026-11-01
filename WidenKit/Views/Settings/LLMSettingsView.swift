import SwiftUI

/// What Settings › LLM shows for one Test Connection run: one row per check,
/// in the order `CloudConnectivityCheck` runs them. Kept out of the view so
/// the wording is testable.
struct ParticleConnectionTestPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        var title: String
        var value: String
        /// Hover text with the raw diagnostics; only the error row has one.
        var help: String?
        /// The check failed at this step.
        var isWarning = false

        var id: String { title }
    }

    var rows: [Row]
    /// True when Particle accepted the key and Particle-1 answered the tiny
    /// request.
    var succeeded: Bool
    /// What the run says about the Particle account, for
    /// `AppState.noteTextToSQLOutcome`.
    var outcome: TextToSQLRunOutcome

    init(
        _ result: CloudConnectivityCheck.Result,
        profile: CloudModelProfile = CloudModelCatalog.productionProfile
    ) {
        let error = result.error
        // The check stops at the first failure, so later steps never ran.
        let listChecked = result.keyAccepted || result.modelListed
        let completionAttempted = result.modelListed && result.toolCallingAdvertised != false
        var rows: [Row] = []

        if result.keyAccepted {
            rows.append(Row(title: "Key", value: "accepted"))
        } else if error?.category == .authentication {
            rows.append(Row(title: "Key", value: "rejected", isWarning: true))
        } else {
            rows.append(Row(title: "Key", value: "not checked"))
        }

        if result.modelListed {
            rows.append(Row(title: profile.displayName, value: "listed"))
            rows.append(
                Row(
                    title: "Context",
                    value: result.contextWindowTokens.map { "\($0.formatted()) tokens" }
                        ?? "not reported"
                )
            )
            switch result.toolCallingAdvertised {
            case true?:
                rows.append(Row(title: "Tools", value: "supported"))
            case false?:
                rows.append(Row(title: "Tools", value: "not advertised", isWarning: true))
            case nil:
                rows.append(Row(title: "Tools", value: "not reported"))
            }
        } else if listChecked {
            rows.append(Row(title: profile.displayName, value: "not listed", isWarning: true))
        } else {
            rows.append(Row(title: profile.displayName, value: "not checked"))
        }

        if result.completionVerified {
            rows.append(Row(title: "Inference", value: "ok"))
        } else if completionAttempted, let error {
            rows.append(
                Row(
                    title: "Inference",
                    value: SQLGenerationErrorCopy.testModelLabel(for: error.category),
                    isWarning: true
                )
            )
        } else {
            rows.append(Row(title: "Inference", value: "not run"))
        }

        if let returnedModelID = result.returnedModelID {
            let expected = profile.expectedReturnedModelID ?? profile.requestedModelID
            rows.append(
                returnedModelID == expected
                    ? Row(title: "Returned model", value: "\(returnedModelID) ✓")
                    : Row(title: "Returned model", value: "\(returnedModelID) — mismatch", isWarning: true)
            )
        }

        rows.append(Row(title: "Latency", value: "\(result.latencyMs) ms"))

        if let error {
            rows.append(
                Row(
                    title: "Error",
                    value: SQLGenerationErrorCopy.testModelLabel(for: error.category),
                    help: Self.diagnostics(for: error),
                    isWarning: true
                )
            )
        }

        self.rows = rows
        succeeded = error == nil && result.completionVerified
        outcome = succeeded ? .answered : .failed(error?.category)
    }

    /// The fixed description of the model, shown whether or not a key is
    /// saved.
    static func modelRows(
        for profile: CloudModelProfile = CloudModelCatalog.productionProfile
    ) -> [Row] {
        var rows = [
            Row(title: "Model", value: profile.displayName),
            Row(title: "Model ID", value: profile.requestedModelID),
        ]
        if let expected = profile.expectedReturnedModelID {
            rows.append(Row(title: "Verified response model", value: expected))
        }
        if case .staticCapabilities(let capabilities) = profile.capabilityResolution,
            let contextLength = capabilities.contextLength
        {
            rows.append(Row(title: "Context", value: "\(contextLength.formatted()) tokens"))
        }
        return rows
    }

    /// A non-blocking warning for an API key draft that does not look like a
    /// Particle key, or nil when it does (or the field is empty).
    static func apiKeyHint(
        for draft: String,
        profile: CloudModelProfile = CloudModelCatalog.productionProfile
    ) -> String? {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !key.hasPrefix(particleKeyPrefix) else { return nil }
        if isForeignAPIKey(key, profile: profile) {
            return "This is an OpenRouter key (sk-or-…), and Widen never sends it to Particle. Paste a Particle API key (pai-…) from platform.particle.ai."
        }
        return "Particle API keys start with pai-. Check that you copied the whole key."
    }

    /// True for a key that belongs to another provider. Saving refuses it,
    /// so the Save button is disabled for it.
    static func isForeignAPIKey(
        _ draft: String,
        profile: CloudModelProfile = CloudModelCatalog.productionProfile
    ) -> Bool {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profile.foreignAPIKeyPrefixes.contains { key.hasPrefix($0.lowercased()) }
    }

    static let particleKeyPrefix = "pai-"

    /// The raw category, provider code and HTTP status, for diagnostics.
    private static func diagnostics(for error: CloudRequestFailure) -> String {
        var parts = [error.category.rawValue]
        if let code = error.diagnostic.providerCode {
            parts.append(code)
        }
        if let status = error.diagnostic.httpStatus {
            parts.append("HTTP \(status)")
        }
        return parts.joined(separator: " · ") + "\n\(error.message)"
    }
}

/// Configuration for Particle-1, Widen's only text-to-SQL model, plus the
/// developer mock toggle.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var isTestingConnection = false
    @State private var connectionTestID = UUID()
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var connectionTest: ParticleConnectionTestPresentation?

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Particle-1 — Beta") {
                particleConfiguration
                Text(
                    "Text-to-SQL sends your question and the schema metadata each connection allows directly to Particle (api.particle.ai) with your key. Particle states it keeps no inference data by default — that is Particle's policy, not something Widen enforces. Inspected data values are sent only for connections that turn on cloud data inspection. Your first question in a session is also used to name it."
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
        .onDisappear(perform: cancelConnectionTest)
    }

    @ViewBuilder
    private var particleConfiguration: some View {
        SecureField("API Key", text: $apiKeyDraft, prompt: Text("pai-…"))
            .onSubmit(saveKey)
        if let hint = ParticleConnectionTestPresentation.apiKeyHint(for: apiKeyDraft) {
            Label(hint, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        HStack {
            Button("Save Key", action: saveKey)
                .disabled(
                    apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                        || ParticleConnectionTestPresentation.isForeignAPIKey(apiKeyDraft)
                )
            if hasStoredKey {
                Button("Remove Key", role: .destructive, action: removeKey)
            }
            Spacer()
            Link("Get an API key", destination: URL(string: "https://platform.particle.ai/")!)
                .font(.callout)
        }

        ForEach(ParticleConnectionTestPresentation.modelRows()) { row in
            LabeledContent(row.title, value: row.value)
        }

        connectionTestControls

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

    @ViewBuilder
    private var connectionTestControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    testConnection()
                } label: {
                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing Connection")
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(!hasStoredKey || isTestingConnection)

                Text("Checks your key and sends one tiny request; may incur a tiny charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let connectionTest {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(connectionTest.rows) { row in
                        resultRow(row)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func resultRow(_ row: ParticleConnectionTestPresentation.Row) -> some View {
        GridRow {
            Text(row.title)
                .foregroundStyle(.secondary)
            // Human label on the surface; the raw category and provider code
            // stay hoverable for diagnostics.
            if let help = row.help {
                resultValue(row)
                    .help(help)
            } else {
                resultValue(row)
            }
        }
    }

    private func resultValue(_ row: ParticleConnectionTestPresentation.Row) -> some View {
        Text(row.value)
            .foregroundStyle(row.isWarning ? .orange : .primary)
    }

    /// A result is shown only while the field still holds the key it tested;
    /// otherwise it would describe a key that is no longer there.
    private func requestStillMatches(apiKey key: String) -> Bool {
        let currentKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasStoredKey && !currentKey.isEmpty && currentKey == key
    }

    private func load() {
        cancelConnectionTest()
        let stored = appState.loadParticleAPIKey() ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDraft = key
        if appState.setParticleAPIKey(key) {
            hasStoredKey = !key.isEmpty
            cancelConnectionTest()
        }
    }

    private func removeKey() {
        if appState.setParticleAPIKey("") {
            apiKeyDraft = ""
            hasStoredKey = false
            cancelConnectionTest()
        }
    }

    /// Stops any run in flight and clears its result. A new ID makes a run
    /// that already finished drop its result too.
    private func cancelConnectionTest() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        connectionTestID = UUID()
        isTestingConnection = false
        connectionTest = nil
    }

    private func testConnection() {
        guard let key = appState.loadParticleAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            return
        }
        cancelConnectionTest()
        let testID = connectionTestID
        isTestingConnection = true
        let check = CloudConnectivityCheck(
            apiKey: key,
            profile: CloudModelCatalog.productionProfile,
            transport: appState.cloudTransportOverride
        )
        connectionTestTask = Task {
            let result = await check.run()
            await MainActor.run {
                // A cancelled or superseded run reports nothing: its result
                // may be a cancellation, or describe a key since replaced.
                guard !Task.isCancelled, connectionTestID == testID else { return }
                isTestingConnection = false
                connectionTestTask = nil
                guard requestStillMatches(apiKey: key) else { return }
                let presentation = ParticleConnectionTestPresentation(result)
                connectionTest = presentation
                appState.noteTextToSQLOutcome(presentation.outcome)
            }
        }
    }
}
