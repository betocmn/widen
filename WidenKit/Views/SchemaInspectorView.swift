import SwiftUI

/// Right-hand inspector with the active connection's schema: searchable
/// table list plus the selected table's columns.
public struct SchemaInspectorView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var schemaVM = appState.schemaVM

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Schema")
                    .font(.headline)
                Spacer()
                Button {
                    if let id = appState.activeConnectionID {
                        Task { await appState.refreshSchema(for: id) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Schema")
                .disabled(activeStatus != .connected)
            }
            .padding(10)

            Divider()

            TextField("Search tables", text: $schemaVM.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            tableList

            if let table = appState.schemaVM.selectedTable(in: activeSchema) {
                Divider()
                SchemaBrowserView(table: table)
                    .frame(maxHeight: 260)
            }
        }
    }

    private var activeConnectionID: UUID? {
        appState.activeConnectionID
    }

    private var activeSchema: DatabaseSchema? {
        activeConnectionID.flatMap { appState.schemas[$0] }
    }

    private var activeStatus: AppState.ConnectionStatus {
        activeConnectionID.map { appState.connectionState($0) } ?? .notConnected
    }

    private var isLoadingSchema: Bool {
        activeConnectionID.map { appState.loadingSchemas.contains($0) } ?? false
    }

    @ViewBuilder
    private var tableList: some View {
        @Bindable var schemaVM = appState.schemaVM
        let groups = appState.schemaVM.groupedTables(in: activeSchema)

        if activeConnectionID == nil {
            VStack(spacing: 8) {
                Text("Select a session to browse its database schema.")
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
                } else {
                    Text(
                        activeStatus == .connected
                            ? "No schema loaded yet."
                            : "Connect to the database to browse its tables."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            Text("No tables match the search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $schemaVM.selectedTableID) {
                ForEach(groups) { group in
                    Section(group.schema) {
                        ForEach(group.tables) { table in
                            HStack(spacing: 6) {
                                Image(systemName: table.type == .view ? "eye" : "tablecells")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)
                                Text(table.name)
                            }
                            .tag(table.id)
                        }
                    }
                }
            }
        }
    }
}
