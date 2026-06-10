import SwiftUI

public struct MainView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Text("Widen")
                .font(.largeTitle.bold())
            Text("Ask your PostgreSQL database questions in plain English.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 700, minHeight: 450)
    }
}
