import AppKit
import Combine
import SwiftUI

private enum MainLayout {
    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 280
    static let sidebarMaxWidth: CGFloat = 340

    static let detailMinWidth: CGFloat = 320

    static let inspectorWidth: CGFloat = 320

    static let windowMinWidth: CGFloat = 700
    static let windowMinWidthWithInspector: CGFloat = 1_000
    static let windowMinHeight: CGFloat = 560
}

public struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: MainLayout.sidebarMinWidth,
                    ideal: MainLayout.sidebarIdealWidth,
                    max: MainLayout.sidebarMaxWidth
                )
        } detail: {
            // A regular content column avoids nesting an inspector's native
            // split controller around NavigationSplitView. That combination
            // can loop through AppKit constraint updates during resizing.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let message = appState.errorBanner {
                        ErrorBannerView(message: message) {
                            appState.errorBanner = nil
                        }
                    }
                    detailContent
                }
                .frame(minWidth: MainLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                if appState.showSchemaInspector {
                    Divider()
                    SchemaInspectorView()
                        .frame(width: MainLayout.inspectorWidth)
                        .background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    breadcrumb
                }
                ToolbarItem(placement: .navigation) {
                    ParticleStatusChip()
                }
                ToolbarItem(placement: .primaryAction) {
                    SchemaInspectorToggle()
                }
            }
        }
        .navigationTitle("Widen")
        .frame(
            minWidth: appState.showSchemaInspector
                ? MainLayout.windowMinWidthWithInspector : MainLayout.windowMinWidth,
            minHeight: MainLayout.windowMinHeight
        )
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

    /// Database status and schema selection using the system toolbar style.
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
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
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 140)
                    .help("Switch the open schema")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
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
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Shows or hides the schema inspector using the system toolbar style.
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
