import SwiftUI

/// Section header for one configured database: status dot, name, endpoint
/// caption, and a hover "+" button that starts a new session.
struct DatabaseGroupRow: View {
    @Environment(AppState.self) private var appState
    let connection: DatabaseConnectionConfig
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                Text("\(connection.database) @ \(connection.host)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if status == .connecting || appState.loadingSchemas.contains(connection.id) {
                ProgressView()
                    .controlSize(.mini)
            }

            Button {
                appState.createSession(connectionID: connection.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Session")
            .opacity(isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("New Session") {
                appState.createSession(connectionID: connection.id)
            }

            Divider()

            Button("Connect") {
                Task { await appState.connectIfNeeded(connection.id) }
            }
            .disabled(status == .connected || status == .connecting)

            Button("Disconnect") {
                Task { await appState.disconnect(connection.id) }
            }
            .disabled(status != .connected)

            Button("Refresh Schema") {
                Task { await appState.refreshSchema(for: connection.id) }
            }
            .disabled(status != .connected)

            Divider()

            Button("Edit in Settings…") {
                appState.openSettings(tab: .databases)
            }
        }
    }

    private var status: AppState.ConnectionStatus {
        appState.connectionState(connection.id)
    }

    private var statusColor: Color {
        switch status {
        case .notConnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }
}
