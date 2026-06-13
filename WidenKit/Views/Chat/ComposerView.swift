import SwiftUI

/// The single conversational entry point: a large rounded input pinned to the
/// bottom of the session pane. Accepts plain-English questions or raw SQL.
/// Return submits; Option+Return inserts a newline.
struct ComposerView: View {
    @Binding var text: String
    var isBusy: Bool
    var onSubmit: () -> Void

    @FocusState private var isComposerFocused: Bool
    @State private var didRequestInitialFocus = false

    private var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Conductor-style tall box: text grows from the top, with the primary
        // send action sitting along the bottom edge.
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
                .hoverBrightness()
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
