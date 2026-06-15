import SwiftUI

public struct LoadingView: View {
    let label: String

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 1)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}
