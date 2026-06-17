import AppKit
import Combine
import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    /// Tracked so exactly one sidebar toggle renders: in the sidebar's
    /// header while open, in the detail toolbar while collapsed (a collapsed
    /// column's toolbar items don't survive relaunch).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    public var body: some View {
        @Bindable var appState = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Replace the system sidebar toggle with our own at the
                // sidebar's trailing corner (the side facing the content),
                // mirroring the inspector toggle — and without the glass
                // container, so neither panel toggle merges into the
                // neighbouring toolbar pills.
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if columnVisibility != .detailOnly {
                        // The flexible spacer pushes the toggle to the
                        // sidebar's trailing corner, against the divider.
                        ToolbarSpacer(.flexible)
                        ToolbarItem {
                            SidebarToggle(columnVisibility: $columnVisibility)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
                .navigationSplitViewColumnWidth(min: 340, ideal: 340, max: 480)
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
            // Both panel toggles sit container-less in the one toolbar row:
            // the sidebar's at its trailing corner (or here, leading, while
            // collapsed) and the inspector's at the window's trailing
            // corner. The appearance toggle lives in the sidebar footer.
            .toolbar {
                if columnVisibility == .detailOnly {
                    ToolbarItem(placement: .navigation) {
                        SidebarToggle(columnVisibility: $columnVisibility)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .navigation) {
                    breadcrumb
                }
                ToolbarItem(placement: .navigation) {
                    AIBackendToggle()
                }
                ToolbarItem(placement: .primaryAction) {
                    SchemaInspectorToggle()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // Attached to the split view (not the detail content) so the detail
        // column's trailing toolbar items stay left of the inspector divider.
        .inspector(isPresented: $appState.showSchemaInspector) {
            SchemaInspectorView()
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        // An empty title (instead of `.toolbar(removing: .title)`) keeps the
        // flexible title region between the leading and trailing toolbar
        // sections — removing it entirely collapses the primary-action
        // buttons next to the breadcrumb.
        .navigationTitle("")
        // The explicit ideal size caps the window's preferred content width.
        // Without it the split view's ideal (sidebar + detail + inspector)
        // can exceed the screen; macOS 26 then keeps the content laid out
        // wider than the clamped window and the panes clip their leading
        // and trailing edges.
        .frame(minWidth: 1040, idealWidth: 1200, minHeight: 560, idealHeight: 700)
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
            // Breathing room inside the system-provided glass pill — without
            // it the text touches the rounded container's edges.
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
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

    @ViewBuilder
    private var detailContent: some View {
        if let controller = appState.selectedController {
            SessionDetailView(controller: controller)
        } else if let databaseID = appState.selectedDatabaseID,
            let config = appState.connection(for: databaseID)
        {
            DatabaseOverviewView(connection: config)
        } else {
            WelcomeDetailView(
                hasConnections: !appState.connections.isEmpty,
                addDatabase: appState.openNewDatabaseSettings
            )
        }
    }
}

private struct WelcomeDetailView: View {
    let hasConnections: Bool
    let addDatabase: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            Text(hasConnections ? "Choose a database on the left" : "Add your first database")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if !hasConnections {
                Button(action: addDatabase) {
                    Label("Add Database", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Shows or hides the sidebar. Replaces the system toggle so its placement
/// and (lack of) background match the inspector's toggle.
struct SidebarToggle: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Button {
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Label("Sidebar", systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
        }
        .help("Show or hide the sidebar")
    }
}

/// Shows or hides the schema inspector. Sits at the leading edge of the
/// inspector's header while it is open (against the divider, mirroring the
/// system sidebar toggle) and in the detail toolbar while it is hidden.
struct SchemaInspectorToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.showSchemaInspector.toggle()
        } label: {
            Label("Schema", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .help("Show or hide the schema inspector")
    }
}
