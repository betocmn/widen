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
        VSplitView {
            ChatView()
                .frame(minHeight: 150, idealHeight: 210)
            SQLPreviewView()
                .frame(minHeight: 150, idealHeight: 210)
            QueryResultsView()
                .frame(minHeight: 170, maxHeight: .infinity)
        }
    }
}
