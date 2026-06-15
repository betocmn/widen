import SwiftUI

/// Right-hand inspector scoped to the open schema: a schema picker, a
/// searchable table list, and the selected table's columns.
public struct SchemaInspectorView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var schemaVM = appState.schemaVM

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    if let id = appState.activeConnectionID {
                        Task { await appState.refreshSchema(for: id) }
                    }
                } label: {
                    if isLoadingSchema {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .hoverHighlight()
                .help(isLoadingSchema ? "Loading schema" : "Refresh Schema")
                .disabled(activeStatus != .connected || isLoadingSchema)
            }
            .padding(10)

            Divider()

            if let id = activeConnectionID, appState.currentSchemaName(for: id) != nil {
                Picker("Schema", selection: schemaBinding(for: id)) {
                    ForEach(activeSchema?.schemas ?? []) { schema in
                        Text(schema.name).tag(schema.name)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .help("The open schema — the table list and AI context are scoped to it")
            }

            if activeSchema != nil {
                TextField("Search tables", text: $schemaVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }

            tableList

            if let table = appState.schemaVM.selectedTable(in: activeSchema) {
                Divider()
                SchemaBrowserView(table: table)
                    .frame(maxHeight: 260)
            }
        }
        // A table selected under another schema would keep stale columns on
        // screen after switching — drop it.
        .onChange(of: selectedSchemaName) {
            if let table = appState.schemaVM.selectedTable(in: activeSchema),
                table.schema != selectedSchemaName
            {
                appState.schemaVM.selectedTableID = nil
            }
        }
        // The inspector pane lays its content out slightly wider than its
        // visible width, so compensate to keep a trailing margin.
        .padding(.trailing, 10)
    }

    /// The database name; the schema picker on the next line says the rest.
    private var title: String {
        if let id = activeConnectionID, let config = appState.connection(for: id) {
            return config.database
        }
        return "Schema"
    }

    private var activeConnectionID: UUID? {
        appState.activeConnectionID
    }

    private var activeSchema: DatabaseSchema? {
        activeConnectionID.flatMap { appState.schemas[$0] }
    }

    private var selectedSchemaName: String? {
        activeConnectionID.flatMap { appState.currentSchemaName(for: $0) }
    }

    private var activeStatus: AppState.ConnectionStatus {
        activeConnectionID.map { appState.connectionState($0) } ?? .notConnected
    }

    private var isLoadingSchema: Bool {
        activeConnectionID.map { appState.loadingSchemas.contains($0) } ?? false
    }

    private func schemaBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { appState.currentSchemaName(for: id) ?? "" },
            set: { appState.selectSchema($0, for: id) }
        )
    }

    @ViewBuilder
    private var tableList: some View {
        @Bindable var schemaVM = appState.schemaVM
        let tables = appState.schemaVM.tables(in: activeSchema, schemaName: selectedSchemaName)

        if activeConnectionID == nil {
            VStack(spacing: 8) {
                Text("Select a database to browse its schema.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if activeSchema == nil {
            VStack(spacing: 8) {
                if isLoadingSchema {
                    LoadingView(label: "Loading schema…")
                    Text("Tables and columns will appear here when introspection finishes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    VStack(spacing: 10) {
                        Image(
                            systemName: activeStatus == .connected
                                ? "exclamationmark.triangle" : "cable.connector"
                        )
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(activeStatus == .connected ? Color.orange : Color.secondary)

                        Text(
                            activeStatus == .connected
                                ? "Schema Not Loaded"
                                : "Connect to browse tables"
                        )
                        .font(.callout.weight(.semibold))

                        Text(
                            activeStatus == .connected
                                ? "Refresh the schema to load tables and columns for browsing and AI context."
                                : "The table list appears after the database connects and the schema loads."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)

                        if activeStatus == .connected {
                            Button("Refresh Schema") {
                                if let id = activeConnectionID {
                                    Task { await appState.refreshSchema(for: id) }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tables.isEmpty {
            Text(
                appState.schemaVM.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "No tables in this schema."
                    : "No tables match the search."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $schemaVM.selectedTableID) {
                ForEach(tables) { table in
                    HStack(spacing: 6) {
                        Image(systemName: table.type == .view ? "eye" : "tablecells")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        Text(table.name)
                    }
                    .contentShape(Rectangle())
                    .tag(table.id)
                    .listRowSeparator(.hidden)
                    .onTapGesture {
                        schemaVM.selectedTableID = table.id
                    }
                    .onTapGesture(count: 2) {
                        schemaVM.selectedTableID = table.id
                        openViewData(for: table)
                    }
                    .contextMenu {
                        Button("View Data") {
                            schemaVM.selectedTableID = table.id
                            openViewData(for: table)
                        }
                    }
                }
            }
        }
    }

    private func openViewData(for table: TableInfo) {
        guard let activeConnectionID else { return }
        Task { await appState.viewData(for: table, connectionID: activeConnectionID) }
    }
}
