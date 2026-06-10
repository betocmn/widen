import SwiftUI

/// Detail pane shown when a database row is selected in the sidebar:
/// the connection at a glance plus a call to action to start a session.
/// The schema itself lives in the right-hand inspector.
public struct DatabaseOverviewView: View {
    @Environment(AppState.self) private var appState
    let connection: DatabaseConnectionConfig

    public init(connection: DatabaseConnectionConfig) {
        self.connection = connection
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)

            Text(connection.database)
                .font(.title2.weight(.semibold))

            Text("\(connection.name) · \(connection.host):\(String(connection.port))")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Button {
                appState.createSession(connectionID: connection.id)
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 16)

            Text("Ask questions in plain English and run the SQL they generate.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: AppState.ConnectionStatus {
        appState.connectionState(connection.id)
    }

    private var statusText: String {
        if case .connected = status, let schema = appState.schemas[connection.id] {
            let count = schema.tables.count
            return "Connected · \(count) \(count == 1 ? "table" : "tables")"
        }
        return status.label
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
