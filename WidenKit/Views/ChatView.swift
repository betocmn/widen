import SwiftUI

public struct ChatView: View {
    @Environment(AppState.self) private var appState
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var chatVM = controller.chatVM

        VStack(spacing: 8) {
            HStack {
                Text("Ask your database")
                    .font(.headline)
                Spacer()
                if !controller.chatVM.messages.isEmpty {
                    Button("Clear Chat") {
                        controller.chatVM.clearConversation()
                        appState.sessionDidChange(controller.sessionID)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            if let message = appState.modelAvailabilityMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if controller.chatVM.messages.isEmpty {
                            emptyState
                        }
                        ForEach(controller.chatVM.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if controller.chatVM.isGenerating {
                            LoadingView(label: "Generating SQL with the local model…")
                                .id("generating")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: controller.chatVM.messages.count) {
                    if let lastID = controller.chatVM.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    TextField(
                        "e.g. “Which users have spent the most?”",
                        text: $chatVM.input
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .onSubmit { generate() }
                    .disabled(controller.chatVM.isGenerating)

                    Button("Generate SQL") {
                        generate()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(
                        controller.chatVM.isGenerating
                            || controller.chatVM.input.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }
        .padding(10)
    }

    private func generate() {
        Task { await controller.submit(appState: appState) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask a question in plain English and Widen will draft a read-only SQL query you can review, edit, and run.")
                .foregroundStyle(.secondary)
            Text("Try: “Show me all users” · “Count orders by status” · “Which users have spent the most?”")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            bubble
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    /// The user bubble gets real glass; assistant and error bubbles use a
    /// plain material — they live in a scrolling LazyVStack, where stacked
    /// glass is needlessly expensive.
    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.35)),
                    in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if message.role == .error {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.red.opacity(0.4))
                    }
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .textSelection(.enabled)
            if let generation = message.generation, message.role == .assistant {
                if generation.needsClarification {
                    Label("Needs clarification", systemImage: "questionmark.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("SQL added to the editor below — review it, then press Run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
