import SwiftUI

/// Chat-first face of a session: a full-height transcript with the composer
/// pinned at the bottom. The active SQL renders as a card at the end of the
/// transcript; a fresh session is just a hint and the composer.
struct ChatModeView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController

    private static let activeCardID = "activeSQLCard"
    private static let generatingID = "generating"

    var body: some View {
        @Bindable var chatVM = controller.chatVM

        VStack(spacing: 0) {
            if let message = appState.modelAvailabilityMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if isEmpty {
                emptyHint
            } else {
                transcript
            }

            ComposerView(text: $chatVM.input, isBusy: controller.chatVM.isGenerating) {
                Task { await controller.submit(appState: appState) }
            }
        }
    }

    private var hasActiveSQL: Bool {
        !controller.queryVM.sqlText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEmpty: Bool {
        controller.chatVM.messages.isEmpty
            && !hasActiveSQL
            && !controller.chatVM.isGenerating
    }

    private var latestResultMessageID: UUID? {
        controller.chatVM.messages.last(where: { $0.role == .result })?.id
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("Ask your database anything")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Type a question in plain English, or paste a SELECT to run it as-is.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            // Content fills from the top on purpose. `.defaultScrollAnchor(.bottom)`
            // translates short content to the bottom visually but leaves the hit-test
            // regions top-aligned on macOS 26, making every button in the
            // transcript unclickable.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.chatVM.messages) { message in
                        MessageBubbleView(
                            message: message,
                            showViewResults: message.id == latestResultMessageID
                                && controller.queryVM.result != nil,
                            onViewResults: { controller.focus = .results },
                            onUseSQL: { controller.queryVM.setGeneration($0) }
                        )
                        .id(message.id)
                    }
                    if controller.chatVM.isGenerating {
                        LoadingView(label: "Generating SQL with the local model…")
                            .id(Self.generatingID)
                    }
                    if hasActiveSQL {
                        SQLCardView(controller: controller)
                            .id(Self.activeCardID)
                    }
                }
                .padding(12)
            }
            .onAppear {
                // LazyVStack needs a layout pass before scrollTo can resolve ids.
                Task { @MainActor in scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: controller.chatVM.messages.count) { scrollToBottom(proxy) }
            .onChange(of: controller.chatVM.isGenerating) { scrollToBottom(proxy) }
            .onChange(of: controller.queryVM.sqlText) { scrollToBottom(proxy) }
            .contextMenu {
                Button("Clear Conversation") {
                    controller.chatVM.clearConversation()
                    controller.queryVM.clear()
                    appState.sessionDidChange(controller.sessionID)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .default : nil) {
            if hasActiveSQL {
                proxy.scrollTo(Self.activeCardID, anchor: .bottom)
            } else if controller.chatVM.isGenerating {
                proxy.scrollTo(Self.generatingID, anchor: .bottom)
            } else if let lastID = controller.chatVM.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}
