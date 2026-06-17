# Prompt for external SwiftUI layout advice

I am working on a native SwiftUI macOS app named Widen. I need advice before making a code change.

Goal:
- Must: the left sidebar must have a minimum width at all times of about 7 cm or more. Users should not be able to drag it smaller than that.
- Optional: the app window itself should have a minimum width so the layout cannot collapse into unusable sizes.
- Optional: the right inspector panel should also have a minimum width, maybe about 5 cm or more.

Important context:
- This is a macOS 26+ SwiftUI app.
- Swift version is 6.0.
- The app uses `NavigationSplitView` for the left sidebar and detail content.
- The app uses SwiftUI `.inspector` for the right-hand schema inspector.
- The current code already has:
  - `.navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 400)` on the sidebar.
  - `.inspectorColumnWidth(min: 240, ideal: 300, max: 420)` on the inspector.
  - `.frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 700)` on the root `NavigationSplitView`.
- If converting literally, 7 cm is about 198 points at 72 points per inch, and 5 cm is about 142 points. I understand macOS points are logical units, so please sanity-check whether centimeter-based reasoning is appropriate here.
- Despite those values, I want to make sure users cannot resize the sidebar below the intended minimum in real app usage.

Questions:
1. In SwiftUI on macOS, is `navigationSplitViewColumnWidth(min:ideal:max:)` sufficient to enforce a hard minimum sidebar width, or can it be bypassed when the window is resized small enough?
2. Should the `WindowGroup` also use `.windowResizability(.contentMinSize)` so the root `.frame(minWidth:minHeight:)` becomes the actual NSWindow minimum size?
3. Is there a better or more reliable way to enforce hard min widths for `NavigationSplitView` columns on macOS 26?
4. Should I adjust the existing sidebar/inspector minimum values, or are the current point values already equivalent to the requested approximate centimeter widths?
5. Please give the exact code changes you recommend and explain any tradeoffs or SwiftUI limitations.

Relevant files and source code follow.

## `project.yml`

```yaml
name: Widen
options:
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true

packages:
  postgres-nio:
    url: https://github.com/vapor/postgres-nio.git
    from: 1.33.0
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle.git
    from: 2.6.0

settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_STYLE: Manual
    GENERATE_INFOPLIST_FILE: YES
    BUNDLE_ID_PREFIX: org.example.widen
    SPARKLE_PUBLIC_ED_KEY: ""
    MACOSX_DEPLOYMENT_TARGET: "26.0"
  configs:
    Debug:
      CODE_SIGN_IDENTITY: "-"
      DEVELOPMENT_TEAM: ""
    Release:
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
      CODE_SIGN_IDENTITY: "Developer ID Application"
      OTHER_CODE_SIGN_FLAGS: "--timestamp"

targets:
  WidenKit:
    type: framework
    platform: macOS
    sources: [WidenKit]
    dependencies:
      - package: postgres-nio
        product: PostgresNIO
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_ID_PREFIX).WidenKit"
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks @loader_path/Frameworks"

  Widen:
    type: application
    platform: macOS
    sources: [Widen]
    dependencies:
      - target: WidenKit
        embed: true
        codeSign: true
      # Xcode embeds Sparkle.framework from the Swift package automatically.
      # Setting embed/codeSign here makes XcodeGen emit an invalid copy path.
      - package: Sparkle
    info:
      path: Widen/Info.plist
      properties:
        CFBundleDisplayName: Widen
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSMinimumSystemVersion: "26.0"
        LSApplicationCategoryType: public.app-category.developer-tools
        NSPrincipalClass: NSApplication
        NSHumanReadableCopyright: "Widen — local-only MVP"
        NSLocalNetworkUsageDescription: "Widen connects to PostgreSQL databases you configure on your local network."
        # Sparkle auto-update. The feed and zipped builds are hosted as GitHub
        # Release assets (see docs/update-server-plan.md).
        SUFeedURL: "https://github.com/betocmn/widen/releases/latest/download/appcast.xml"
        SUPublicEDKey: "$(SPARKLE_PUBLIC_ED_KEY)"
        # Auto-check for updates on by default (opt-out in Settings ▸ General).
        # Setting this explicitly also suppresses Sparkle's first-run prompt.
        SUEnableAutomaticChecks: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_ID_PREFIX).Widen"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_KEY_CFBundleShortVersionString: "$(MARKETING_VERSION)"
        INFOPLIST_KEY_CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: NO
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
        # Private Cloud Compute needs the Apple-managed entitlement in
        # Widen/Widen.entitlements, which cannot ship on an ad-hoc signed
        # build (macOS kills the app at launch). Once Apple grants access
        # (https://developer.apple.com/private-cloud-compute/) and a real
        # signing identity exists, add here:
        #   CODE_SIGN_ENTITLEMENTS: Widen/Widen.entitlements
        #   CODE_SIGN_STYLE: Automatic
        #   DEVELOPMENT_TEAM: <team id>
        # and build with Xcode 27+ so the PCC code path is compiled in.
      configs:
        Release:
          ENABLE_HARDENED_RUNTIME: YES

  WidenTests:
    type: bundle.unit-test
    platform: macOS
    sources: [WidenTests]
    dependencies:
      - target: WidenKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(BUNDLE_ID_PREFIX).WidenTests"

schemes:
  Widen:
    build:
      targets:
        Widen: all
        WidenTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: false
      targets:
        - WidenTests
```

## `Widen/WidenApp.swift`

```swift
import AppKit
import SwiftUI
import WidenKit

@main
struct WidenApp: App {
    @State private var appState = AppState()
    @State private var updaterModel = UpdaterModel()
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    init() {
        // Make sure the app fronts properly even when launched from a bare
        // binary (e.g. during development without a full bundle).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Theme the whole app before the first window draws, so it opens in
        // the stored appearance instead of flashing the system one.
        AppearancePreference.stored.apply()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                // Drive the app appearance from the preference rather than
                // `.preferredColorScheme`, which leaves the window's materials
                // and chrome out of sync with the content on a theme switch.
                .onChange(of: appearanceRaw) { _, _ in appearance.apply() }
                .onAppear {
                    if updaterModel.isConfigured {
                        appState.updaterControl = updaterModel
                    }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if updaterModel.isConfigured {
                    CheckForUpdatesView(updater: updaterModel)
                }
            }
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
```

## `WidenKit/Views/MainView.swift`

```swift
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
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 400)
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
```

## `WidenKit/Views/Sidebar/SidebarView.swift`

```swift
import SwiftUI

/// Conductor-style sidebar: one group per configured database — the
/// database itself is a selectable row for schema browsing, with its
/// persistent query sessions indented beneath it.
public struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var renamingSessionID: UUID?

    public init() {}

    public var body: some View {
        if appState.connections.isEmpty {
            ContentUnavailableView {
                Label("No Databases", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Add a PostgreSQL connection to get started.")
            } actions: {
                Button("Add Database…") {
                    appState.openNewDatabaseSettings()
                }
            }
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        List(selection: selectionBinding) {
            ForEach(appState.connections) { connection in
                Section {
                    DatabaseGroupRow(connection: connection)
                        .tag(SidebarItem.database(connection.id))
                    ForEach(appState.sessions(for: connection.id)) { session in
                        SessionRow(session: session, renamingSessionID: $renamingSessionID)
                            .tag(SidebarItem.session(session.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        appState.openNewDatabaseSettings()
                    } label: {
                        Label("Add Database", systemImage: "plus.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .hoverHighlight()
                    Spacer()
                    AppearanceToggle()
                }
                // Leading padding keeps the icon clear of the window's
                // rounded bottom corner and aligned with the list rows.
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    /// Routes sidebar selection through AppState so controllers are
    /// snapshotted/created and the database connects lazily. A nil set
    /// (clicks on empty space) keeps the current selection.
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { appState.sidebarSelection },
            set: { item in
                switch item {
                case .database(let id): appState.selectDatabase(id)
                case .session(let id): appState.selectSession(id)
                case nil: break
                }
            }
        )
    }
}
```

Please answer with concrete SwiftUI/macOS guidance and a minimal patch-style recommendation.
