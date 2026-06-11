import SwiftUI

/// Master/detail database management: the connection list on the left, the
/// editor form on the right. Deleting a connection cascade-deletes its
/// sessions after an explicit warning.
struct DatabasesSettingsView: View {
    private enum SidebarSelection: Hashable {
        case draft
        case connection(UUID)
    }

    private enum PendingNavigation {
        case startNew
        case selectConnection(UUID)
        case cancelDraft
        case deleteSelected
    }

    @Environment(AppState.self) private var appState
    @State private var selection: SidebarSelection?
    @State private var editor = ConnectionSettingsViewModel()
    @State private var isAddingNew = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var didInitialize = false
    @State private var pendingNavigation: PendingNavigation?

    var body: some View {
        HSplitView {
            connectionList
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)

            editorPane
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            initializeSelectionIfNeeded()
        }
        .confirmationDialog(
            "Delete “\(selectedConnectionName)”?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Database and Its Sessions", role: .destructive) {
                deleteSelectedConnection()
            }
        } message: {
            Text(
                "This removes the connection and permanently deletes all of its query sessions, including archived ones. This cannot be undone."
            )
        }
        .alert("Discard Unsaved Changes?", isPresented: $confirmDiscard) {
            Button("Keep Editing", role: .cancel) {
                pendingNavigation = nil
            }
            Button("Discard Changes", role: .destructive) {
                let action = pendingNavigation
                pendingNavigation = nil
                discardCurrentEdits()
                if let action {
                    perform(action)
                }
            }
        } message: {
            Text("Your database settings have changes that have not been saved.")
        }
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            List {
                if isAddingNew {
                    ConnectionSidebarRow(
                        title: "New Database",
                        subtitle: "Not saved yet",
                        systemImage: "plus.circle",
                        isSelected: selection == .draft
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection != .draft {
                            request(.startNew)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                }

                ForEach(appState.connections) { connection in
                    ConnectionSidebarRow(
                        title: connection.name,
                        subtitle: subtitle(for: connection),
                        systemImage: "cylinder.split.1x2",
                        isSelected: selection == .connection(connection.id)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection != .connection(connection.id) {
                            request(.selectConnection(connection.id))
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 6) {
                footerButton(systemImage: "plus", help: "Add Database") {
                    request(.startNew)
                }

                footerButton(
                    systemImage: "minus",
                    help: removeButtonHelp,
                    isDisabled: selection == nil
                ) {
                    if selection == .draft {
                        request(.cancelDraft)
                    } else {
                        request(.deleteSelected)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if selection != nil {
            ConnectionEditorForm(viewModel: editor) { saved in
                isAddingNew = false
                selection = .connection(saved.id)
            }
        } else {
            ContentUnavailableView {
                Label("No Database Selected", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Select a database on the left, or press + to add one.")
            }
        }
    }

    private var selectedConnectionName: String {
        selectedConnectionID
            .flatMap { appState.connection(for: $0)?.name } ?? "database"
    }

    private var selectedConnectionID: UUID? {
        if case .connection(let id) = selection {
            return id
        }
        return nil
    }

    private var removeButtonHelp: String {
        if selection == .draft {
            return "Cancel New Database"
        }
        return "Remove Database"
    }

    private func subtitle(for connection: DatabaseConnectionConfig) -> String {
        "\(connection.database) @ \(connection.host)"
    }

    private func initializeSelectionIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        if let first = appState.connections.first {
            loadConnection(first.id)
        } else {
            startNew()
        }
    }

    private func request(_ action: PendingNavigation) {
        if editor.hasUnsavedChanges {
            pendingNavigation = action
            confirmDiscard = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingNavigation) {
        switch action {
        case .startNew:
            startNew()
        case .selectConnection(let id):
            loadConnection(id)
        case .cancelDraft:
            cancelDraft()
        case .deleteSelected:
            if selection == .draft {
                cancelDraft()
            } else {
                confirmDelete = selectedConnectionID != nil
            }
        }
    }

    private func discardCurrentEdits() {
        switch selection {
        case .draft:
            editor.startNew()
        case .connection(let id):
            if let config = appState.connection(for: id) {
                editor.load(from: config)
            }
        case nil:
            break
        }
    }

    private func startNew() {
        selection = .draft
        isAddingNew = true
        editor.startNew()
    }

    private func loadConnection(_ id: UUID) {
        guard let config = appState.connection(for: id) else { return }
        isAddingNew = false
        selection = .connection(id)
        editor.load(from: config)
    }

    private func cancelDraft() {
        isAddingNew = false
        if let first = appState.connections.first {
            loadConnection(first.id)
        } else {
            selection = nil
            editor.startNew()
        }
    }

    private func deleteSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        appState.deleteConnection(id)
        if let first = appState.connections.first {
            loadConnection(first.id)
        } else {
            startNew()
        }
    }

    private func footerButton(
        systemImage: String,
        help: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .tertiary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isDisabled ? 0.03 : 0.08))
        }
        .disabled(isDisabled)
        .help(help)
    }
}

private struct ConnectionSidebarRow: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
    }
}
