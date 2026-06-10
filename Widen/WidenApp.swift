import AppKit
import SwiftUI
import WidenKit

@main
struct WidenApp: App {
    @State private var appState = AppState()
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

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
                .preferredColorScheme(appearance.colorScheme)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    if let connectionID = appState.activeConnectionID
                        ?? appState.connections.first?.id
                    {
                        appState.createSession(connectionID: connectionID)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.connections.isEmpty)
            }
            CommandMenu("Database") {
                Button("Refresh Schema") {
                    if let id = appState.activeConnectionID {
                        Task { await appState.refreshSchema(for: id) }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(activeConnectionState != .connected)

                Divider()

                Button("Connect") {
                    if let id = appState.activeConnectionID {
                        Task { await appState.connectIfNeeded(id) }
                    }
                }
                .disabled(
                    appState.activeConnectionID == nil
                        || activeConnectionState == .connected
                        || activeConnectionState == .connecting
                )

                Button("Disconnect") {
                    if let id = appState.activeConnectionID {
                        Task { await appState.disconnect(id) }
                    }
                }
                .disabled(activeConnectionState != .connected)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    private var activeConnectionState: AppState.ConnectionStatus {
        appState.activeConnectionID.map { appState.connectionState($0) } ?? .notConnected
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }
}
