import SwiftUI

/// The single conversational entry point: a large rounded input pinned to the
/// bottom of the session pane. Accepts plain-English questions or raw SQL.
/// Return submits; Option+Return inserts a newline.
struct ComposerView: View {
    @Binding var text: String
    var isBusy: Bool
    var onSubmit: () -> Void

    private var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask in plain English, or write SQL directly…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .onSubmit(submit)
            .disabled(isBusy)

            // No .keyboardShortcut(.defaultAction) here — the text field's
            // onSubmit already handles Return; both would double-fire.
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSubmit)
            .help("Send")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding([.horizontal, .bottom], 12)
    }

    private func submit() {
        // onSubmit fires on Return even while the send button is disabled.
        guard canSubmit else { return }
        onSubmit()
    }
}
