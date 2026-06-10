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

    public init() {}
}
