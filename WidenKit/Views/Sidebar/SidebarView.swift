import SwiftUI

/// Conductor-style sidebar: one section per configured database, each
/// listing its persistent query sessions.
public struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var renamingSessionID: UUID?

    public init() {}

    public var body: some View {
        if appState.connections.isEmpty {
            ContentUnavailableView {
                Label("No Databases", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Add a PostgreSQL connection to get started.")
            } actions: {
                Button("Add Database…") {
                    appState.openSettings(tab: .databases)
                }
            }
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        List(selection: selectionBinding) {
            ForEach(appState.connections) { connection in
                Section {
                    let sessions = appState.sessions(for: connection.id)
                    if sessions.isEmpty {
                        Text("No sessions — press + to start")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    }
                    ForEach(sessions) { session in
                        SessionRow(session: session, renamingSessionID: $renamingSessionID)
                            .tag(session.id)
                    }
                } header: {
                    DatabaseGroupRow(connection: connection)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Routes sidebar selection through `selectSession` so controllers are
    /// snapshotted/created and the database connects lazily.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { appState.selectedSessionID },
            set: { appState.selectSession($0) }
        )
    }
}
