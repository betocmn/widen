import AppKit
import Combine
import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

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
            ToolbarItem(placement: .navigation) {
                connectionChip
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleAppearance()
                } label: {
                    Label(
                        colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode",
                        systemImage: colorScheme == .dark ? "sun.max" : "moon"
                    )
                }
                .help(
                    colorScheme == .dark
                        ? "Switch to light mode (reset to System in Settings › General)"
                        : "Switch to dark mode (reset to System in Settings › General)")
            }
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

    /// Status dot + name of the selected session's database.
    @ViewBuilder
    private var connectionChip: some View {
        if let id = appState.activeConnectionID,
            let config = appState.connection(for: id)
        {
            let status = appState.connectionState(id)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                Text(config.name)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .help("\(config.database) @ \(config.host) — \(status.label)")
        }
    }

    private func statusColor(_ status: AppState.ConnectionStatus) -> Color {
        switch status {
        case .notConnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    /// Flips to the opposite of the effective scheme. The "follow System"
    /// reset lives in Settings › General.
    private func toggleAppearance() {
        let next: AppearancePreference = colorScheme == .dark ? .light : .dark
        appearanceRaw = next.rawValue
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
