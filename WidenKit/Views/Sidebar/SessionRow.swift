import SwiftUI

/// One session in the sidebar: title indented under its database row,
/// inline rename, and archive affordances.
struct SessionRow: View {
    @Environment(AppState.self) private var appState
    let session: QuerySession
    @Binding var renamingSessionID: UUID?

    @State private var draftTitle = ""
    @State private var isHovering = false
    @State private var confirmArchive = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            titleContent
            Spacer(minLength: 4)

            if isHovering && renamingSessionID != session.id {
                Button {
                    confirmArchive = true
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Archive Session")
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
            }
        }
        // Aligns session titles under the database name (icon + spacing).
        .padding(.leading, 29)
        .padding(.vertical, 1)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename") {
                renamingSessionID = session.id
            }
            Button("Archive") {
                confirmArchive = true
            }
        }
        .confirmationDialog(
            "Archive \"\(session.displayTitle)\"?",
            isPresented: $confirmArchive,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                appState.archiveSession(session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived sessions are hidden from the sidebar and can be restored from Settings.")
        }
    }

    @ViewBuilder
    private var titleContent: some View {
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
                .lineLimit(1)
        } else {
            Text(session.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }

    private func commitRename() {
        appState.renameSession(session.id, to: draftTitle)
        renamingSessionID = nil
    }
}
