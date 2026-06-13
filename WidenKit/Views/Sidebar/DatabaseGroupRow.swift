import SwiftUI

/// Selectable database row: icon with a status badge, the custom name,
/// the host/database caption, and a "+" button that starts a new session.
/// Selecting the row opens the database's schema in the inspector.
struct DatabaseGroupRow: View {
    @Environment(AppState.self) private var appState
    let connection: DatabaseConnectionConfig
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(connection.host) · \(connection.database)")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .hoverHighlight(horizontalPadding: 3, verticalPadding: 3)
            .help("New Session")
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
        .listRowBackground(rowHoverBackground)
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
                appState.openDatabaseSettings(connectionID: connection.id)
            }
        }
    }

    /// Hover tint behind the row, shaped like the sidebar selection pill;
    /// suppressed while selected so the two highlights never stack.
    @ViewBuilder
    private var rowHoverBackground: some View {
        if isHovering, appState.sidebarSelection != .database(connection.id) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(0.06))
                .padding(.horizontal, 5)
        } else {
            Color.clear
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
