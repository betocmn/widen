import AppKit
import Combine
import SwiftUI

private enum MainLayout {
    // macOS 26's `NavigationSplitView` (+ `.inspector`) lays its backing
    // `NSSplitView` out at the panes' combined width and, when that exceeds the
    // window, OVERFLOWS instead of shrinking — sliding the whole split left and
    // clipping the sidebar's leading edge (icons, row inset, selection pill).
    //
    // Two rules keep the sidebar safe (both verified against live `NSSplitView`
    // frames via lldb):
    //  1. The combined IDEAL width must fit the narrowest all-panels window so
    //     the default layout never overflows: sidebarIdeal + detailIdeal +
    //     inspectorIdeal stays under `showAllPanelsAtOrAbove`. The detail is the
    //     flexible pane — a low ideal only bounds this budget; it still fills
    //     the whole pane at runtime.
    //  2. The inspector is FIXED (min == ideal == max). Dragging it wider does
    //     NOT shrink the detail on macOS 26 — the split just grows past the
    //     window and clips the sidebar. A non-resizable inspector is the only
    //     reliable way to guarantee the sidebar never breaks; the schema list
    //     reads fine at a fixed width.
    static let sidebarMinWidth: CGFloat = 300
    static let sidebarIdealWidth: CGFloat = 320
    static let sidebarMaxWidth: CGFloat = 380

    static let detailMinWidth: CGFloat = 300
    static let detailIdealWidth: CGFloat = 300

    static let inspectorMinWidth: CGFloat = 320
    static let inspectorIdealWidth: CGFloat = 320
    static let inspectorMaxWidth: CGFloat = 320

    static let showAllPanelsAtOrAbove: CGFloat = 1_280
    static let showSidebarAtOrAbove: CGFloat = 820

    static let windowMinWidth: CGFloat = 700
    static let windowIdealWidth: CGFloat = 1_280
    static let windowMinHeight: CGFloat = 560
    static let windowIdealHeight: CGFloat = 700
}

private enum AdaptivePanelMode: Equatable {
    case allPanels
    case noInspector
    case detailOnly
}

public struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    /// Tracked so exactly one sidebar toggle renders: in the sidebar's
    /// header while open, in the detail toolbar while collapsed (a collapsed
    /// column's toolbar items don't survive relaunch).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var adaptivePanelMode: AdaptivePanelMode = .detailOnly

    public init() {}

    public var body: some View {
        @Bindable var appState = appState

        let sidebarIsAvailable = adaptivePanelMode != .detailOnly
        let inspectorIsAvailable = adaptivePanelMode == .allPanels
        let effectiveColumnVisibility = Binding<NavigationSplitViewVisibility>(
            get: {
                sidebarIsAvailable ? columnVisibility : .detailOnly
            },
            set: { newValue in
                if sidebarIsAvailable {
                    columnVisibility = newValue
                }
            }
        )
        let effectiveInspectorPresentation = Binding<Bool>(
            get: {
                inspectorIsAvailable && appState.showSchemaInspector
            },
            set: { isPresented in
                if inspectorIsAvailable {
                    appState.showSchemaInspector = isPresented
                }
            }
        )

        NavigationSplitView(columnVisibility: effectiveColumnVisibility) {
            SidebarView()
                // Replace the system sidebar toggle with our own at the
                // sidebar's trailing corner (the side facing the content),
                // mirroring the inspector toggle — and without the glass
                // container, so neither panel toggle merges into the
                // neighbouring toolbar pills.
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if sidebarIsAvailable && columnVisibility != .detailOnly {
                        if #available(macOS 26.0, *) {
                            // The flexible spacer pushes the toggle to the
                            // sidebar's trailing corner, against the divider.
                            ToolbarSpacer(.flexible)
                        }
                        ToolbarItem {
                            SidebarToggle(columnVisibility: effectiveColumnVisibility)
                        }
                        .widenToolbarBackgroundHidden()
                    }
                }
                .navigationSplitViewColumnWidth(
                    min: MainLayout.sidebarMinWidth,
                    ideal: MainLayout.sidebarIdealWidth,
                    max: MainLayout.sidebarMaxWidth
                )
        } detail: {
            VStack(spacing: 0) {
                if let message = appState.errorBanner {
                    ErrorBannerView(message: message) {
                        appState.errorBanner = nil
                    }
                }
                detailContent
            }
            .frame(
                minWidth: MainLayout.detailMinWidth,
                idealWidth: MainLayout.detailIdealWidth
            )
            // Both panel toggles sit container-less in the one toolbar row:
            // the sidebar's at its trailing corner (or here, leading, while
            // collapsed) and the inspector's at the window's trailing
            // corner. The appearance toggle lives in the sidebar footer.
            .toolbar {
                if !sidebarIsAvailable || columnVisibility == .detailOnly {
                    ToolbarItem(placement: .navigation) {
                        SidebarToggle(
                            columnVisibility: effectiveColumnVisibility,
                            isAvailable: sidebarIsAvailable
                        )
                    }
                    .widenToolbarBackgroundHidden()
                }
                ToolbarItem(placement: .navigation) {
                    breadcrumb
                }
                ToolbarItem(placement: .navigation) {
                    AIBackendToggle()
                }
                ToolbarItem(placement: .primaryAction) {
                    SchemaInspectorToggle(isAvailable: inspectorIsAvailable)
                }
                .widenToolbarBackgroundHidden()
            }
        }
        // Attached to the split view (not the detail content) so the detail
        // column's trailing toolbar items stay left of the inspector divider.
        .inspector(isPresented: effectiveInspectorPresentation) {
            SchemaInspectorView()
                .inspectorColumnWidth(
                    min: MainLayout.inspectorMinWidth,
                    ideal: MainLayout.inspectorIdealWidth,
                    max: MainLayout.inspectorMaxWidth
                )
        }
        // An empty title (instead of `.toolbar(removing: .title)`) keeps the
        // flexible title region between the leading and trailing toolbar
        // sections — removing it entirely collapses the primary-action
        // buttons next to the breadcrumb.
        .navigationTitle("")
        .frame(
            minWidth: MainLayout.windowMinWidth,
            idealWidth: MainLayout.windowIdealWidth,
            minHeight: MainLayout.windowMinHeight,
            idealHeight: MainLayout.windowIdealHeight
        )
        .onGeometryChange(for: AdaptivePanelMode.self) { proxy in
            let width = proxy.size.width

            if width < MainLayout.showSidebarAtOrAbove {
                return .detailOnly
            }

            if width < MainLayout.showAllPanelsAtOrAbove {
                return .noInspector
            }

            return .allPanels
        } action: { newMode in
            var transaction = Transaction()
            transaction.disablesAnimations = true

            withTransaction(transaction) {
                adaptivePanelMode = newMode
            }
        }
        .task {
            await appState.onLaunch()
        }
        .onChange(of: appState.openSettingsRequest) {
            openSettings()
        }
        .alert(item: $appState.llmCompatibilityAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Open LLM Settings")) {
                    appState.openSettings(tab: .llm)
                },
                secondaryButton: .cancel(Text("Dismiss"))
            )
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
                .widenGlassButtonStyle(prominent: true)
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
    var isAvailable = true

    var body: some View {
        Button {
            guard isAvailable else { return }
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Label("Sidebar", systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
        }
        .disabled(!isAvailable)
        .help(isAvailable ? "Show or hide the sidebar" : "Widen the window to show the sidebar")
    }
}

/// Shows or hides the schema inspector. Sits at the leading edge of the
/// inspector's header while it is open (against the divider, mirroring the
/// system sidebar toggle) and in the detail toolbar while it is hidden.
struct SchemaInspectorToggle: View {
    @Environment(AppState.self) private var appState
    var isAvailable = true

    var body: some View {
        Button {
            guard isAvailable else { return }
            appState.showSchemaInspector.toggle()
        } label: {
            Label("Schema", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .disabled(!isAvailable)
        .help(
            isAvailable
                ? "Show or hide the schema inspector"
                : "Widen the window to show the schema inspector"
        )
    }
}
