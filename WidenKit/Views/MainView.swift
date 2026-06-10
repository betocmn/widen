import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 12) {
            Text("Widen")
                .font(.largeTitle.bold())
            Text("Ask your PostgreSQL database questions in plain English.")
                .foregroundStyle(.secondary)

            if let config = appState.config {
                Text("\(config.name) — \(config.database) on \(config.host):\(String(config.port))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(appState.connectionStatus.label)
                .font(.callout)

            Button("Settings…") {
                appState.showSettings = true
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .sheet(isPresented: $appState.showSettings) {
            ConnectionSettingsView()
        }
        .task {
            await appState.onLaunch()
        }
    }
}
