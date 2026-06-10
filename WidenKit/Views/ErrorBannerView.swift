import SwiftUI

/// Dismissible red banner shown at the top of the main content area.
public struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 10)
    }
}
