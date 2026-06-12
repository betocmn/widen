import SwiftUI

/// Conductor-style sidebar: one group per configured database — the
/// database itself is a selectable row for schema browsing, with its
/// persistent query sessions indented beneath it.
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
                    appState.openNewDatabaseSettings()
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
                    DatabaseGroupRow(connection: connection)
                        .tag(SidebarItem.database(connection.id))
                    ForEach(appState.sessions(for: connection.id)) { session in
                        SessionRow(session: session, renamingSessionID: $renamingSessionID)
                            .tag(SidebarItem.session(session.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        appState.openNewDatabaseSettings()
                    } label: {
                        Label("Add Database", systemImage: "plus.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    Spacer()
                    AppearanceToggle()
                }
                // Leading padding keeps the icon clear of the window's
                // rounded bottom corner and aligned with the list rows.
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    /// Routes sidebar selection through AppState so controllers are
    /// snapshotted/created and the database connects lazily. A nil set
    /// (clicks on empty space) keeps the current selection.
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { appState.sidebarSelection },
            set: { item in
                switch item {
                case .database(let id): appState.selectDatabase(id)
                case .session(let id): appState.selectSession(id)
                case nil: break
                }
            }
        )
    }
}
