import SwiftUI

/// The single conversational entry point: a large rounded input pinned to the
/// bottom of the session pane. Accepts plain-English questions or raw SQL.
/// Return submits; Option+Return inserts a newline.
struct ComposerView: View {
    @Binding var text: String
    var isBusy: Bool
    var databaseContext: String
    var onSubmit: () -> Void
    var onEditContext: () -> Void

    @FocusState private var isComposerFocused: Bool
    @State private var didRequestInitialFocus = false

    private var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasDatabaseContext: Bool {
        !databaseContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Conductor-style tall box: text grows from the top while low-emphasis
        // context controls and the primary send action sit along the bottom.
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Ask in plain English, or write SQL directly…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(3...12)
            .onSubmit(submit)
            .focused($isComposerFocused)
            .disabled(isBusy)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack {
                Button(action: onEditContext) {
                    Label(
                        hasDatabaseContext ? "Context added" : "Add context",
                        systemImage: hasDatabaseContext
                            ? "text.book.closed.fill" : "text.book.closed"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasDatabaseContext ? Color.accentColor : Color.secondary)
                .background {
                    Capsule()
                        .fill(
                            hasDatabaseContext
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(0.06)
                        )
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            hasDatabaseContext
                                ? Color.accentColor.opacity(0.2)
                                : Color.primary.opacity(0.1),
                            lineWidth: 1
                        )
                }
                .help(
                    hasDatabaseContext
                        ? "Edit extra context sent with natural-language questions"
                        : "Add optional context for natural-language questions"
                )

                Spacer()
                // No .keyboardShortcut(.defaultAction) here — the text field's
                // onSubmit already handles Return; both would double-fire.
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSubmit)
                .help("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding([.horizontal, .bottom], 12)
        .onAppear {
            requestInitialFocus()
        }
        .onChange(of: isBusy) {
            requestInitialFocus()
        }
    }

    private func submit() {
        // onSubmit fires on Return even while the send button is disabled.
        guard canSubmit else { return }
        onSubmit()
    }

    private func requestInitialFocus() {
        guard !didRequestInitialFocus, !isBusy else { return }
        didRequestInitialFocus = true
        Task { @MainActor in
            await Task.yield()
            isComposerFocused = true
        }
    }
}
