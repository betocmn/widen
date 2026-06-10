import SwiftUI

public struct LoadingView: View {
    let label: String

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
