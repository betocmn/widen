import AppKit
import Combine
import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if let message = appState.errorBanner {
                    ErrorBannerView(message: message) {
                        appState.errorBanner = nil
                    }
                }
                detailContent
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $appState.showSettings) {
            ConnectionSettingsView()
        }
        .task {
            await appState.onLaunch()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            appState.flushSessions()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let controller = appState.selectedController {
            SessionDetailView(controller: controller)
        } else {
            ContentUnavailableView {
                Label("Select a session", systemImage: "text.bubble")
            } description: {
                Text("Pick a session in the sidebar, or press + on a database to start one.")
            }
        }
    }
}
