import SwiftUI

/// Chat-first face of a session: a full-height transcript with the composer
/// pinned at the bottom. SQL and results render inline at their
/// chronological position in the thread — permanent entries that scroll up
/// as the conversation grows. Only the newest SQL card is runnable; a fresh
/// session is just a hint and the composer.
struct ChatModeView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController

    private static let activeCardID = "activeSQLCard"
    private static let generatingID = "generating"
    private static let runningID = "runningQuery"

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

    /// The message that introduced the SQL currently in the preview — the
    /// last generation, or the last directly-typed SQL. The active card
    /// renders right after it, keeping the thread chronological.
    private var activeSQLAnchorID: UUID? {
        controller.chatVM.messages.last(where: { message in
            switch message.role {
            case .assistant:
                return !(message.generation?.sql ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return ChatViewModel.isDirectSQL(message.text)
            case .error, .result:
                return false
            }
        })?.id
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
                        messageGroup(message)
                            .id(message.id)
                    }
                    if controller.chatVM.isGenerating {
                        LoadingView(label: "Generating SQL with the local model…")
                            .id(Self.generatingID)
                    }
                    if controller.queryVM.isRunning {
                        HStack(spacing: 8) {
                            LoadingView(label: "Running query…")
                            Button("Stop waiting") {
                                controller.queryVM.cancelRun()
                            }
                            .controlSize(.small)
                        }
                        .id(Self.runningID)
                    }
                    // Restored sessions can carry SQL whose introducing
                    // message is gone; keep it runnable at the end.
                    if hasActiveSQL && activeSQLAnchorID == nil {
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
            .onChange(of: controller.queryVM.isRunning) { scrollToBottom(proxy) }
            .onChange(of: controller.queryVM.sqlText) { scrollToBottom(proxy) }
            .contextMenu {
                Button("Clear Conversation") {
                    controller.clearConversation()
                    appState.sessionDidChange(controller.sessionID)
                }
            }
        }
    }

    /// One chronological transcript entry: run records render their full
    /// results card while the result is in memory; the SQL-introducing
    /// messages carry their card right below the bubble — the newest one
    /// runnable, earlier ones as permanent read-only records.
    @ViewBuilder
    private func messageGroup(_ message: ChatMessage) -> some View {
        if message.role == .result, let result = controller.results[message.id] {
            ResultsCardView(result: result)
        } else if message.id == activeSQLAnchorID, hasActiveSQL {
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(message: message)
                SQLCardView(controller: controller)
            }
        } else if message.role == .assistant,
            let sql = message.generation?.sql,
            !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(message: message)
                StaticSQLCardView(sql: sql)
            }
        } else {
            MessageBubbleView(message: message)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .default : nil) {
            if controller.queryVM.isRunning {
                proxy.scrollTo(Self.runningID, anchor: .bottom)
            } else if controller.chatVM.isGenerating {
                proxy.scrollTo(Self.generatingID, anchor: .bottom)
            } else if hasActiveSQL && activeSQLAnchorID == nil {
                proxy.scrollTo(Self.activeCardID, anchor: .bottom)
            } else if let lastID = controller.chatVM.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}
