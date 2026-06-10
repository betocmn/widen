import SwiftUI

public struct ChatView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        @Bindable var chatVM = appState.chatVM

        VStack(spacing: 8) {
            HStack {
                Text("Ask your database")
                    .font(.headline)
                Spacer()
                if !appState.chatVM.messages.isEmpty {
                    Button("Clear Chat") {
                        appState.chatVM.clearConversation()
                    }
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
                        if appState.chatVM.messages.isEmpty {
                            emptyState
                        }
                        ForEach(appState.chatVM.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if appState.chatVM.isGenerating {
                            LoadingView(label: "Generating SQL with the local model…")
                                .id("generating")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: appState.chatVM.messages.count) {
                    if let lastID = appState.chatVM.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "e.g. “Which users have spent the most?”",
                    text: $chatVM.input
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { generate() }
                .disabled(appState.chatVM.isGenerating)

                Button("Generate SQL") {
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appState.chatVM.isGenerating
                        || appState.chatVM.input.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(10)
    }

    private func generate() {
        Task { await appState.chatVM.submit(appState: appState) }
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
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var background: some ShapeStyle {
        switch message.role {
        case .user: AnyShapeStyle(Color.accentColor.opacity(0.18))
        case .assistant: AnyShapeStyle(.quaternary.opacity(0.5))
        case .error: AnyShapeStyle(Color.red.opacity(0.15))
        }
    }
}
