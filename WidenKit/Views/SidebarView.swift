import SwiftUI

public struct SidebarView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var schemaVM = appState.schemaVM

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            TextField("Search tables", text: $schemaVM.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            tableList

            if let table = appState.schemaVM.selectedTable(in: appState.schema) {
                Divider()
                SchemaBrowserView(table: table)
                    .frame(maxHeight: 260)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Widen")
                .font(.title3.bold())

            if let config = appState.config {
                Text(config.name)
                    .font(.callout)
                Text("\(config.database) @ \(config.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.connectionStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.connectionStatus == .connecting || appState.isLoadingSchema {
                    ProgressView().controlSize(.mini)
                }
            }

            HStack(spacing: 8) {
                Button("Settings") {
                    appState.showSettings = true
                }
                Button("Refresh Schema") {
                    Task { await appState.refreshSchema() }
                }
                .disabled(appState.connectionStatus != .connected)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .notConnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    @ViewBuilder
    private var tableList: some View {
        @Bindable var schemaVM = appState.schemaVM
        let groups = appState.schemaVM.groupedTables(in: appState.schema)

        if appState.schema == nil {
            VStack(spacing: 8) {
                if appState.isLoadingSchema {
                    LoadingView(label: "Loading schema…")
                } else {
                    Text(
                        appState.connectionStatus == .connected
                            ? "No schema loaded yet."
                            : "Connect to a database to browse its tables."
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
            .listStyle(.sidebar)
        }
    }
}
