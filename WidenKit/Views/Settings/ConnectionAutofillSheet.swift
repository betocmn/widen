import SwiftUI

/// Paste-autofill sheet: the user pastes connection details in any format
/// (URL, .env entries, prose) and local parsers fill the editor form. The
/// pasted text never leaves the Mac.
struct ConnectionAutofillSheet: View {
    @Bindable var viewModel: ConnectionSettingsViewModel
    var parser: any ConnectionDetailsParsing
    var onDone: () -> Void

    @State private var autofillTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Paste Connection Details", systemImage: "doc.on.clipboard")
                .font(.headline)

            Text(
                "Paste a connection URL, .env entries, or any text that mentions the host, database, and credentials. URLs and simple key-value entries are parsed directly; free-form text uses Apple's on-device model when available. Nothing leaves this Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.autofillText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .focused($editorFocused)

                if viewModel.autofillText.isEmpty {
                    Text("postgres://user:password@host:5432/database?sslmode=require\n\nor\n\nDB_HOST=…\nDB_NAME=…\nDB_PASSWORD=…")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }

            if case .failure(let message) = viewModel.autofillState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if viewModel.autofillState == .parsing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading details…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    cancelAutofill()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    startAutofill()
                } label: {
                    Label("Fill Form", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    viewModel.autofillState == .parsing
                        || viewModel.autofillText
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { editorFocused = true }
        .onDisappear {
            autofillTask?.cancel()
            autofillTask = nil
        }
    }

    private func startAutofill() {
        autofillTask?.cancel()
        autofillTask = Task { @MainActor in
            if await viewModel.autofill(using: parser), !Task.isCancelled {
                onDone()
            }
            autofillTask = nil
        }
    }

    private func cancelAutofill() {
        autofillTask?.cancel()
        autofillTask = nil
        viewModel.resetAutofill()
        onDone()
    }
}
