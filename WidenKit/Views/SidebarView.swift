import SwiftUI

/// Conductor-style sidebar: one section per configured database, each
/// listing its persistent query sessions.
public struct SidebarView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        List(selection: selectionBinding) {
            ForEach(appState.connections) { connection in
                Section {
                    ForEach(appState.sessions(for: connection.id)) { session in
                        Text(session.title)
                            .tag(session.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(connection.name)
                        Spacer()
                        Button {
                            appState.createSession(connectionID: connection.id)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("New Session")
                    }
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
