import SwiftUI

public struct ConnectionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ConnectionSettingsViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $viewModel.name)
                    TextField("Host", text: $viewModel.host)
                    TextField("Port", text: $viewModel.portText)
                    TextField("Database", text: $viewModel.database)
                    TextField("Username", text: $viewModel.username)
                    SecureField("Password", text: $viewModel.password)
                    Picker("SSL mode", selection: $viewModel.sslMode) {
                        ForEach(SSLMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Query defaults") {
                    TextField("Default row limit", text: $viewModel.rowLimitText)
                    TextField("Statement timeout (seconds)", text: $viewModel.timeoutText)
                }

                Section("AI") {
                    @Bindable var appState = appState
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

                if !viewModel.validationErrors.isEmpty {
                    Section {
                        ForEach(viewModel.validationErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let saveError = viewModel.saveError {
                    Section {
                        Label(saveError, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    testStatusView
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Test Connection") {
                    Task { await viewModel.testConnection() }
                }
                .disabled(viewModel.testState == .testing)

                Spacer()

                Button("Cancel") {
                    appState.showSettings = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save and Connect") {
                    Task {
                        if await viewModel.saveAndConnect(appState: appState) {
                            appState.showSettings = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSaving)
            }
            .padding()
        }
        .frame(width: 480, height: 600)
        .onAppear {
            if let config = appState.config {
                viewModel.load(from: config)
            }
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch viewModel.testState {
        case .idle:
            Text("Connection has not been tested yet.")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing connection…")
            }
        case .success:
            Label("Connection succeeded.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
