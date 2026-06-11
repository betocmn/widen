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
            // Cap the detail pane's ideal width: if the split view's total
            // ideal exceeds the screen, macOS 26 keeps the content laid out
            // wider than the clamped window and the panes clip their edges.
            .frame(minWidth: 420, idealWidth: 560)
            .inspector(isPresented: $appState.showSchemaInspector) {
                SchemaInspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                breadcrumb
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
        // The explicit ideal size caps the window's preferred content width.
        // Without it the split view's ideal (sidebar + detail + inspector)
        // can exceed the screen; macOS 26 then keeps the content laid out
        // wider than the clamped window and the panes clip their leading
        // and trailing edges.
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 700)
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

    /// Cursor-style breadcrumb: status dot · database › open schema. Plain
    /// toolbar content on purpose — the macOS 26 toolbar already wraps items
    /// in glass, so any custom capsule renders as a double rounded container.
    @ViewBuilder
    private var breadcrumb: some View {
        if let id = appState.activeConnectionID,
            let config = appState.connection(for: id)
        {
            let status = appState.connectionState(id)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                Text(config.database)
                    .font(.callout)
                if let schemaName = appState.currentSchemaName(for: id) {
                    Text("›")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Menu {
                        Picker("Schema", selection: schemaBinding(for: id)) {
                            ForEach(appState.schemas[id]?.schemas ?? []) { schema in
                                Text(schema.name).tag(schema.name)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(schemaName)
                            .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Switch the open schema")
                }
            }
            .help("\(config.name) · \(config.host):\(String(config.port)) — \(status.label)")
        }
    }

    private func schemaBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { appState.currentSchemaName(for: id) ?? "" },
            set: { appState.selectSchema($0, for: id) }
        )
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
        } else if let databaseID = appState.selectedDatabaseID,
            let config = appState.connection(for: databaseID)
        {
            DatabaseOverviewView(connection: config)
        } else {
            ContentUnavailableView {
                Label("Select a session", systemImage: "terminal")
            } description: {
                Text("Pick a session in the sidebar, or press + on a database to start one.")
            }
        }
    }
}
