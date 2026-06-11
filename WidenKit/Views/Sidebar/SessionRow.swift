import SwiftUI

/// One session in the sidebar: title indented under its database row,
/// inline rename, and a context menu with Rename / Archive.
struct SessionRow: View {
    @Environment(AppState.self) private var appState
    let session: QuerySession
    @Binding var renamingSessionID: UUID?

    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        Group {
            if renamingSessionID == session.id {
                TextField("Session name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingSessionID = nil }
                    .onAppear {
                        draftTitle = session.displayTitle
                        renameFieldFocused = true
                    }
            } else if session.title == QuerySession.placeholderTitle {
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
        // Aligns session titles under the database name (icon + spacing).
        .padding(.leading, 29)
        .padding(.vertical, 1)
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
