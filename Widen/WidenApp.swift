import AppKit
import SwiftUI
import WidenKit

@main
struct WidenApp: App {
    @State private var appState = AppState()

    init() {
        // Make sure the app fronts properly even when launched from a bare
        // binary (e.g. during development without a full bundle).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Database") {
                Button("Refresh Schema") {
                    Task { await appState.refreshSchema() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.connectionStatus != .connected)

                Divider()

                Button("Connect") {
                    if let config = appState.config {
                        Task { await appState.connect(config) }
                    }
                }
                .disabled(appState.config == nil || appState.connectionStatus == .connected)

                Button("Disconnect") {
                    Task { await appState.disconnect() }
                }
                .disabled(appState.connectionStatus != .connected)
            }
        }
    }
}
