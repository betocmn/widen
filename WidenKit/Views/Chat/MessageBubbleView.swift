import SwiftUI

/// One transcript entry. User/assistant/error messages render as bubbles;
/// `.result` records render as a compact full-width row.
struct MessageBubbleView: View {
    let message: ChatMessage
    /// True when this is the latest run record and its result is still in
    /// memory, so "View results" can reopen the results pane.
    var showViewResults = false
    var onViewResults: (() -> Void)?
    /// Restores an older generation into the active SQL card.
    var onUseSQL: ((SQLGenerationResult) -> Void)?

    @State private var showSQL = false

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
            if showViewResults {
                Button("View results") {
                    onViewResults?()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
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
                } else if !generation.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlDisclosure(generation)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Collapsed by default so old generations don't clutter the transcript.
    private func sqlDisclosure(_ generation: SQLGenerationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { showSQL.toggle() }
            } label: {
                Label("View SQL", systemImage: showSQL ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showSQL {
                Text(generation.sql)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                if onUseSQL != nil {
                    Button("Use this SQL") {
                        onUseSQL?(generation)
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }
        }
    }
}
