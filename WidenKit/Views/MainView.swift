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
        // The chat panel arrives with the chat milestone.
        VSplitView {
            SQLPreviewView()
                .frame(minHeight: 150, idealHeight: 200)
            QueryResultsView()
                .frame(minHeight: 180, maxHeight: .infinity)
        }
    }
}
