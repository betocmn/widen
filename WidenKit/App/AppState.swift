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
    public var schema: DatabaseSchema?
    public var isLoadingSchema = false
    public var showSettings = false
    public var errorBanner: String?

    /// Developer toggle: use the deterministic mock generator instead of the
    /// on-device model.
    public var useMockAI = UserDefaults.standard.bool(forKey: AppState.useMockAIKey) {
        didSet { UserDefaults.standard.set(useMockAI, forKey: Self.useMockAIKey) }
    }
    private static let useMockAIKey = "WidenUseMockAI"

    /// The active SQL generation backend.
    public var sqlGenerator: any SQLGenerator {
        if useMockAI { return MockSQLGenerator() }
        #if canImport(FoundationModels)
            return FoundationModelsSQLGenerator()
        #else
            return MockSQLGenerator()
        #endif
    }

    /// nil when AI generation is ready; otherwise a user-readable reason.
    public var modelAvailabilityMessage: String? {
        if useMockAI { return nil }
        #if canImport(FoundationModels)
            return FoundationModelsSQLGenerator.availabilityMessage
        #else
            return
                "This build does not include FoundationModels (SDK too old). Mock mode is the only AI option."
        #endif
    }

    public let connectionStore = ConnectionStore()
    public let keychain = KeychainService()
    public let postgres = PostgresService()
    public let schemaVM = SchemaViewModel()
    public let queryVM = QueryResultViewModel()
    public let chatVM = ChatViewModel()

    private let introspection = SchemaIntrospectionService()

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
        clearLoadedSchema()
        connectionStatus = .connecting
        errorBanner = nil

        var password: String?
        do {
            password = try keychain.loadPassword(for: config.id)
        } catch {
            // Continue with no password — local trust auth may still work —
            // but tell the user the Keychain read failed.
            errorBanner = error.localizedDescription
        }

        do {
            try await postgres.connect(config: config, password: password)
            connectionStatus = .connected
            await refreshSchema()
        } catch {
            connectionStatus = .error(error.localizedDescription)
            errorBanner = error.localizedDescription
        }
    }

    public func disconnect() async {
        queryVM.cancelRun()
        await postgres.disconnect()
        connectionStatus = .notConnected
        schema = nil
        schemaVM.selectedTableID = nil
    }

    public func refreshSchema() async {
        guard connectionStatus == .connected else { return }
        let previousSelection = schemaVM.selectedTableID
        clearLoadedSchema()
        isLoadingSchema = true
        defer { isLoadingSchema = false }
        do {
            let loadedSchema = try await introspection.loadSchema(using: postgres)
            schema = loadedSchema
            if let previousSelection,
                loadedSchema.tables.contains(where: { $0.id == previousSelection })
            {
                schemaVM.selectedTableID = previousSelection
            }
        } catch {
            clearLoadedSchema()
            errorBanner = error.localizedDescription
        }
    }

    private func clearLoadedSchema() {
        schema = nil
        schemaVM.selectedTableID = nil
    }
}
