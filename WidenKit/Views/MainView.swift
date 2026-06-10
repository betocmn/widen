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
    }

    @ViewBuilder
    private var detailContent: some View {
        // The chat / SQL / results panels arrive with the next milestones.
        VStack(spacing: 12) {
            Text("Widen")
                .font(.largeTitle.bold())
            Text("Ask your PostgreSQL database questions in plain English.")
                .foregroundStyle(.secondary)
            Text(appState.connectionStatus.label)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
