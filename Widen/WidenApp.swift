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
    }
}
