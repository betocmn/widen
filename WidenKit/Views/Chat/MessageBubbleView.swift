import SwiftUI

/// One transcript entry. User/assistant/error messages render as bubbles;
/// `.result` records render as a compact full-width row. (Run records whose
/// result is still in memory are rendered by the transcript as a full
/// `ResultsCardView` instead, and SQL-bearing messages get their card from
/// the transcript too.)
struct MessageBubbleView: View {
    let message: ChatMessage
    /// Present on a failed-write error bubble: asks the model to repair the
    /// query and refill the editor (without running it).
    var onRetryWrite: (() -> Void)? = nil

    var body: some View {
        if message.role == .result {
            resultRow
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }
                bubble
                if message.role != .user { Spacer(minLength: 60) }
            }
        }
    }

    private var resultRow: some View {
        HStack(spacing: 8) {
            Label(message.text, systemImage: "tablecells")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// The user bubble gets real glass; assistant and error bubbles use a
    /// plain material — they live in a scrolling LazyVStack, where stacked
    /// glass is needlessly expensive.
    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            content
                .widenGlassEffect(cornerRadius: 14, tint: Color.accentColor.opacity(0.35))
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
            if let generation = message.generation,
                message.role == .assistant,
                generation.needsClarification
            {
                Label("Needs clarification", systemImage: "questionmark.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if message.role == .error, let onRetryWrite {
                Button("Try Again", systemImage: "arrow.clockwise") {
                    onRetryWrite()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverBrightness()
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
