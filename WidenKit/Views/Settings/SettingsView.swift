import SwiftUI

/// The Settings window: General, LLM, Databases, and Archived Sessions tabs.
public struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    public init() {}

    public var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            LLMSettingsView()
                .tabItem { Label("LLM", systemImage: "sparkles") }
                .tag(SettingsTab.llm)

            DatabasesSettingsView()
                .tabItem { Label("Databases", systemImage: "cylinder.split.1x2") }
                .tag(SettingsTab.databases)

            ArchivedSessionsSettingsView()
                .tabItem { Label("Archived Sessions", systemImage: "archivebox") }
                .tag(SettingsTab.archived)
        }
        .frame(width: 720, height: 560)
        // The General tab changes the appearance too; re-theme the whole app
        // (not just this window) so the change reaches the main window's
        // chrome and materials. Idempotent with the main window's own handler.
        .onChange(of: appearanceRaw) { _, newValue in
            (AppearancePreference(rawValue: newValue) ?? .system).apply()
        }
    }
}
