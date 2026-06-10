import SwiftUI

/// Master/detail database management: the connection list on the left, the
/// editor form on the right. Deleting a connection cascade-deletes its
/// sessions after an explicit warning.
struct DatabasesSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedConnectionID: UUID?
    @State private var editor = ConnectionSettingsViewModel()
    @State private var isAddingNew = false
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            connectionList
                .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)

            editorPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if let first = appState.connections.first {
                selectedConnectionID = first.id
                editor.load(from: first)
            } else {
                startNew()
            }
        }
        .onChange(of: selectedConnectionID) {
            if let id = selectedConnectionID,
                let config = appState.connection(for: id)
            {
                isAddingNew = false
                editor.load(from: config)
            }
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
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedConnectionID) {
                ForEach(appState.connections) { connection in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.name)
                        Text("\(connection.database) @ \(connection.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(connection.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button {
                    startNew()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Database")

                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedConnectionID == nil)
                .help("Remove Database")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if selectedConnectionID != nil || isAddingNew {
            ConnectionEditorForm(viewModel: editor) { saved in
                isAddingNew = false
                selectedConnectionID = saved.id
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

    private func startNew() {
        selectedConnectionID = nil
        isAddingNew = true
        editor.startNew()
    }

    private func deleteSelectedConnection() {
        guard let id = selectedConnectionID else { return }
        appState.deleteConnection(id)
        if let first = appState.connections.first {
            selectedConnectionID = first.id
            editor.load(from: first)
        } else {
            startNew()
        }
    }
}
