import SwiftUI

/// Slim header shown in results mode: the conversation, minimized to one
/// clickable row that returns to chat mode.
struct CollapsedChatStrip: View {
    let controller: SessionController

    var body: some View {
        Button {
            controller.focus = .chat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .imageScale(.small)
                Label(messageCountText, systemImage: "bubble.left")
                    .foregroundStyle(.secondary)
                if let question = lastQuestion {
                    Text(question)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the conversation")
    }

    private var messageCountText: String {
        let count = controller.chatVM.messages.count
        return count == 1 ? "1 message" : "\(count) messages"
    }

    private var lastQuestion: String? {
        controller.chatVM.messages.last(where: { $0.role == .user })?.text
    }
}
