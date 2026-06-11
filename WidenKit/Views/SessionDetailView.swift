import SwiftUI

/// Detail pane for one query session. Chat mode is the default: a transcript
/// with the composer pinned at the bottom and the active SQL inline. Running
/// a query flips to results mode, where the conversation collapses to a strip
/// and the grid takes the space. Editor and transcript changes schedule a
/// debounced save through `sessionDidChange`.
public struct SessionDetailView: View {
    @Environment(AppState.self) private var appState
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        Group {
            // Exactly one mode is mounted at a time — both declare ⌘Return
            // on their run buttons, which is only safe unduplicated.
            switch controller.focus {
            case .chat:
                ChatModeView(controller: controller)
            case .results:
                ResultsModeView(controller: controller)
            }
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
