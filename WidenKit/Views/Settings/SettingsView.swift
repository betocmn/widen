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
        .preferredColorScheme(
            (AppearancePreference(rawValue: appearanceRaw) ?? .system).colorScheme)
    }
}
