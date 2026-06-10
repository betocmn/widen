import SwiftUI

/// Archived sessions: hidden from the sidebar, restorable or permanently
/// deletable from here.
struct ArchivedSessionsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingDeleteID: UUID?

    var body: some View {
        Group {
            if appState.archivedSessions.isEmpty {
                ContentUnavailableView {
                    Label("No Archived Sessions", systemImage: "archivebox")
                } description: {
                    Text("Sessions you archive from the sidebar appear here.")
                }
            } else {
                List(appState.archivedSessions) { session in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                            Text(subtitle(for: session))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Restore") {
                            appState.restoreSession(session.id)
                        }
                        Button("Delete Forever", role: .destructive) {
                            pendingDeleteID = session.id
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeleteTitle)” forever?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                if let id = pendingDeleteID {
                    appState.deleteSessionForever(id)
                }
                pendingDeleteID = nil
            }
        } message: {
            Text("The session's transcript and SQL are permanently deleted. This cannot be undone.")
        }
    }

    private func subtitle(for session: QuerySession) -> String {
        let connectionName =
            appState.connection(for: session.connectionID)?.name ?? "Deleted database"
        let date = session.updatedAt.formatted(.relative(presentation: .named))
        return "\(connectionName) · \(date)"
    }

    private var pendingDeleteTitle: String {
        pendingDeleteID.flatMap { appState.session(for: $0)?.title } ?? "session"
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }
}
