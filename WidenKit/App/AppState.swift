import Foundation
import Observation

/// Root application state. Owns the services and the data shared across views.
@MainActor
@Observable
public final class AppState {
    public enum ConnectionStatus: Equatable, Sendable {
        case notConnected
        case connecting
        case connected
        case error(String)

        public var label: String {
            switch self {
            case .notConnected: "Not connected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .error: "Error"
            }
        }
    }

    public var connectionStatus: ConnectionStatus = .notConnected
    public var config: DatabaseConnectionConfig?
    public var showSettings = false
    public var errorBanner: String?

    public let connectionStore = ConnectionStore()
    public let keychain = KeychainService()
    public let postgres = PostgresService()

    private var didLaunch = false

    public init() {}

    /// Called once at launch: loads the saved connection if there is one,
    /// otherwise surfaces the first-launch settings screen.
    public func onLaunch() async {
        guard !didLaunch else { return }
        didLaunch = true
        do {
            if let saved = try connectionStore.loadPrimary() {
                config = saved
                await connect(saved)
            } else {
                showSettings = true
            }
        } catch {
            showSettings = true
            errorBanner = "Could not load the saved connection: \(error.localizedDescription)"
        }
    }

    public func connect(_ config: DatabaseConnectionConfig) async {
        // Implemented with the Postgres service milestone.
    }
}
