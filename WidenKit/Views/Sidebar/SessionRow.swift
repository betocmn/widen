import SwiftUI

/// One session in the sidebar: icon + title, inline rename, and a context
/// menu with Rename / Archive.
struct SessionRow: View {
    @Environment(AppState.self) private var appState
    let session: QuerySession
    @Binding var renamingSessionID: UUID?

    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
                .imageScale(.small)

            if renamingSessionID == session.id {
                TextField("Session name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingSessionID = nil }
                    .onAppear {
                        draftTitle = session.title
                        renameFieldFocused = true
                    }
            } else if session.title == QuerySession.placeholderTitle {
                Text(session.title)
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(session.title)
            }
        }
        .contextMenu {
            Button("Rename") {
                renamingSessionID = session.id
            }
            Button("Archive") {
                appState.archiveSession(session.id)
            }
        }
    }

    private func commitRename() {
        appState.renameSession(session.id, to: draftTitle)
        renamingSessionID = nil
    }
}
