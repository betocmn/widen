import SwiftUI

/// Connection editor form: the connection fields, query defaults, validation
/// feedback, and Test Connection / Save actions.
struct ConnectionEditorForm: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewModel: ConnectionSettingsViewModel
    var onSaved: (DatabaseConnectionConfig) -> Void

    var body: some View {
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

                Button("Save") {
                    if let saved = viewModel.save(appState: appState) {
                        onSaved(saved)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSaving)
            }
            .padding()
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
                Text("Testing connection...")
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
