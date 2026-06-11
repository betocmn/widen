import SwiftUI

/// Detail pane for one query session: a single chat thread with the composer
/// pinned at the bottom. The active SQL and the latest run's results render
/// inline in the transcript. Editor and transcript changes schedule a
/// debounced save through `sessionDidChange`.
public struct SessionDetailView: View {
    @Environment(AppState.self) private var appState
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        ChatModeView(controller: controller)
            .onChange(of: controller.queryVM.sqlText) {
                appState.sessionDidChange(controller.sessionID)
            }
            .onChange(of: controller.chatVM.messages.count) {
                appState.sessionDidChange(controller.sessionID)
            }
            .id(controller.sessionID)
    }
}
