import SwiftUI

/// Detail pane for one query session: chat, SQL editor, and results, all
/// backed by the session's runtime controller. Editor and transcript changes
/// schedule a debounced save through `sessionDidChange`.
public struct SessionDetailView: View {
    @Environment(AppState.self) private var appState
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        VSplitView {
            ChatView(controller: controller)
                .frame(minHeight: 150, idealHeight: 210)
            SQLPreviewView(controller: controller)
                .frame(minHeight: 150, idealHeight: 210)
            QueryResultsView(controller: controller)
                .frame(minHeight: 170, maxHeight: .infinity)
        }
        .onChange(of: controller.queryVM.sqlText) {
            appState.sessionDidChange(controller.sessionID)
        }
        .onChange(of: controller.chatVM.messages.count) {
            appState.sessionDidChange(controller.sessionID)
        }
        .id(controller.sessionID)
    }
}
