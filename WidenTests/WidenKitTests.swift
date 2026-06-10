import Testing

@testable import WidenKit

@Suite("WidenKit smoke")
struct WidenKitSmokeTests {
    @Test func appStateInitialStatus() async throws {
        let state = await AppState()
        await #expect(state.connectionStatus == .notConnected)
    }
}
