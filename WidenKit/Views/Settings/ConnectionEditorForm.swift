import SwiftUI

/// Connection editor form: the connection fields, query defaults, validation
/// feedback, and Test Connection / Save actions.
struct ConnectionEditorForm: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewModel: ConnectionSettingsViewModel
    var onCancel: () -> Void
    var onSaved: (DatabaseConnectionConfig) -> Void
    @State private var showAutofillSheet = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSectionPanel(
                        title: "Connection", systemImage: "cylinder.split.1x2"
                    ) {
                        autofillButton
                    } content: {
                        textRow("Nickname", text: $viewModel.name)
                        Divider()
                        textRow("Host", text: $viewModel.host)
                        Divider()
                        textRow("Port", text: $viewModel.portText, width: 120)
                        Divider()
                        textRow("Database", text: $viewModel.database)
                        Divider()
                        textRow("Username", text: $viewModel.username)
                        Divider()
                        textRow("Password", text: $viewModel.password, isSecure: true)
                        Divider()
                        EditorRow("SSL mode") {
                            Picker("SSL mode", selection: $viewModel.sslMode) {
                                ForEach(SSLMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                    }

                    SettingsSectionPanel(title: "Query Defaults", systemImage: "slider.horizontal.3") {
                        textRow("Default row limit", text: $viewModel.rowLimitText, width: 120)
                        Divider()
                        textRow("Statement timeout (seconds)", text: $viewModel.timeoutText, width: 120)
                    }

                    privacySection

                    SettingsSectionPanel(title: "Query Context", systemImage: "text.book.closed") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Widen already sends the loaded database schema, including tables, columns, and foreign keys, with each natural-language question. Add optional notes here only when extra business logic, relationships, or data meaning would help the model.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $viewModel.databaseContext)
                                    .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)

                                if viewModel.databaseContext.isEmpty {
                                    Text("Optional additional context")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 14)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(minHeight: 120)
                            .background(
                                Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            }
                            .help("Included in the local model prompt before each text-to-SQL generation.")

                            Text("\(viewModel.databaseContext.count) / \(SQLPromptBuilder.maxDatabaseContextCharacters.formatted()) characters")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(
                                    viewModel.databaseContext.count
                                        > SQLPromptBuilder.maxDatabaseContextCharacters
                                        ? Color.red : Color.secondary.opacity(0.7)
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    rememberedDefinitionsSection

                    if !viewModel.validationErrors.isEmpty {
                        MessagePanel(systemImage: "exclamationmark.triangle.fill", color: .red) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Check these fields")
                                    .font(.callout.weight(.semibold))
                                ForEach(viewModel.validationErrors, id: \.self) { error in
                                    Text(error)
                                        .font(.callout)
                                }
                            }
                        }
                    }

                    if let saveError = viewModel.saveError {
                        MessagePanel(systemImage: "xmark.octagon.fill", color: .red) {
                            Text(saveError)
                                .font(.callout)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            actionBar
        }
        .sheet(isPresented: $showAutofillSheet) {
            if let parser = appState.connectionDetailsParser {
                ConnectionAutofillSheet(viewModel: viewModel, parser: parser) {
                    showAutofillSheet = false
                }
            }
        }
    }

    private var privacySection: some View {
        SettingsSectionPanel(title: "Advanced Privacy", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Schema metadata includes table/column names, comments, constraints, and enum values. Data inspection may include actual values from your database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Allow local data inspection for AI assistance", isOn: $viewModel.allowLocalDataInspection)
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.allowLocalDataInspection) { _, enabled in
                        if !enabled {
                            viewModel.allowCloudDataInspection = false
                        }
                    }

                Toggle("Allow sending inspected data values to cloud models", isOn: $viewModel.allowCloudDataInspection)
                    .toggleStyle(.checkbox)
                    .disabled(!viewModel.allowLocalDataInspection)

                Text("Sample rows remain off until separately confirmed for this connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rememberedDefinitionsSection: some View {
        if let connectionID = viewModel.connectionID {
            let bindings = appState.semanticBindings
                .filter { $0.connectionID == connectionID }
                .sorted { $0.createdAt > $1.createdAt }
            SettingsSectionPanel(title: "Remembered Definitions", systemImage: "bookmark") {
                if bindings.isEmpty {
                    Text("No remembered definitions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(bindings) { binding in
                            rememberedDefinitionRow(binding)
                            if binding.id != bindings.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func rememberedDefinitionRow(_ binding: DatabaseSemanticBinding) -> some View {
        let schema = appState.schemas[binding.connectionID]
        let scopedSchema = schema.map { loaded in
            binding.schemaNames.count == 1
                ? loaded.filtered(toSchema: binding.schemaNames[0])
                : loaded
        }
        let isStale = scopedSchema.map { !binding.isCurrent(for: $0) } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(binding.concept)
                        .font(.callout.weight(.semibold))
                    if isStale {
                        Text("Stale")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(binding.definition)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                appState.deleteSemanticBinding(binding.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete remembered definition")
        }
        .padding(.vertical, 7)
    }

    /// Opens the paste-autofill sheet. Parsing stays local: structured URLs
    /// and key-value entries are deterministic, and free-form text uses the
    /// on-device model when available.
    private var autofillButton: some View {
        Button {
            showAutofillSheet = true
        } label: {
            Label("Paste Details…", systemImage: "doc.on.clipboard")
                .font(.callout)
        }
        .disabled(appState.connectionAutofillUnavailableMessage != nil)
        .help(
            appState.connectionAutofillUnavailableMessage
                ?? "Paste a connection URL or .env details to fill this form locally. Nothing leaves this Mac."
        )
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                Label(
                    viewModel.testState == .testing ? "Testing..." : "Test Connection",
                    systemImage: "checkmark.seal"
                )
            }
            .disabled(viewModel.testState == .testing)

            testStatusBadge

            Spacer()

            if viewModel.hasUnsavedChanges {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isSaving)
            }

            Button {
                if let saved = viewModel.save(appState: appState) {
                    onSaved(saved)
                }
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.hasUnsavedChanges || viewModel.isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(height: 58)
        .background(.bar)
    }

    @ViewBuilder
    private var testStatusBadge: some View {
        switch viewModel.testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .success:
            Label("Success", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .help("Connection succeeded.")
        case .failure(let message):
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func textRow(
        _ title: String,
        text: Binding<String>,
        width: CGFloat = 220,
        isSecure: Bool = false
    ) -> some View {
        EditorRow(title) {
            if isSecure {
                SecureField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
            } else {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
            }
        }
    }
}

private struct SettingsSectionPanel<Accessory: View, Content: View>: View {
    var title: String
    var systemImage: String
    let accessory: Accessory
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Spacer(minLength: 0)

                accessory
            }

            VStack(spacing: 0) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

extension SettingsSectionPanel where Accessory == EmptyView {
    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            accessory: { EmptyView() },
            content: content
        )
    }
}

private struct EditorRow<Content: View>: View {
    var title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 145, alignment: .leading)
                .lineLimit(2)

            Spacer(minLength: 8)

            content
        }
        .padding(.vertical, 7)
    }
}

private struct MessagePanel<Content: View>: View {
    var systemImage: String
    var color: Color
    let content: Content

    init(
        systemImage: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.systemImage = systemImage
        self.color = color
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            content

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.08))
        }
    }
}
