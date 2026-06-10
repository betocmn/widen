import AppKit
import Combine
import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

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
            .inspector(isPresented: $appState.showSchemaInspector) {
                SchemaInspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSchemaInspector.toggle()
                } label: {
                    Label("Schema", systemImage: "sidebar.right")
                }
                .help("Show or hide the schema inspector")
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            await appState.onLaunch()
        }
        .onChange(of: appState.openSettingsRequest) {
            openSettings()
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
