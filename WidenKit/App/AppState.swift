import Foundation
import Observation

/// Which tab the Settings UI shows.
public enum SettingsTab: String, Hashable, Sendable {
    case general
    case databases
    case archived
}

/// What the sidebar has selected: a whole database (for schema browsing)
/// or one of its query sessions.
public enum SidebarItem: Hashable, Sendable {
    case database(UUID)
    case session(UUID)
}

/// Root application state. Owns the services, the configured connections,
/// and the persistent query sessions shared across views.
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

    // MARK: - Connections

    public var connections: [DatabaseConnectionConfig] = []
    public var connectionStates: [UUID: ConnectionStatus] = [:]
    /// Schema cache per connection. Kept across disconnects so reconnecting
    /// is instant; dropped when the connection's endpoint changes.
    public var schemas: [UUID: DatabaseSchema] = [:]
    public var loadingSchemas: Set<UUID> = []
    private var services: [UUID: PostgresService] = [:]

    // MARK: - Sessions

    /// Every session, including archived ones.
    public var sessions: [QuerySession] = []
    /// The sidebar selection: a database row or a session row.
    public var sidebarSelection: SidebarItem?
    /// Runtime containers, cached so switching sessions never loses
    /// in-flight generations or query runs.
    private var controllers: [UUID: SessionController] = [:]

    /// The selected session, when the sidebar selection is a session.
    public var selectedSessionID: UUID? {
        if case .session(let id) = sidebarSelection { return id }
        return nil
    }

    /// The selected database, when the sidebar selection is a database row.
    public var selectedDatabaseID: UUID? {
        if case .database(let id) = sidebarSelection { return id }
        return nil
    }

    // MARK: - UI state

    /// The schema the user has "open" per connection, persisted across
    /// launches. Read through `currentSchemaName(for:)`, which falls back
    /// when the stored choice no longer exists.
    public var selectedSchemaNames: [UUID: String] = AppState.loadSelectedSchemaNames() {
        didSet { Self.saveSelectedSchemaNames(selectedSchemaNames) }
    }
    private static let selectedSchemaNamesKey = "WidenSelectedSchemaNames"

    public var showSchemaInspector = true
    public var settingsTab: SettingsTab = .general
    /// Incremented to ask MainView to open the Settings window.
    public var openSettingsRequest = 0
    public var errorBanner: String?

    /// Developer toggle: use the deterministic mock generator instead of the
    /// on-device model.
    public var useMockAI = UserDefaults.standard.bool(forKey: AppState.useMockAIKey) {
        didSet { UserDefaults.standard.set(useMockAI, forKey: Self.useMockAIKey) }
    }
    private static let useMockAIKey = "WidenUseMockAI"
    private static let selectedSessionKey = "WidenSelectedSessionID"

    /// The active SQL generation backend.
    public var sqlGenerator: any SQLGenerator {
        if useMockAI { return MockSQLGenerator() }
        #if canImport(FoundationModels)
            return FoundationModelsSQLGenerator()
        #else
            return MockSQLGenerator()
        #endif
    }

    /// The active session-title backend. Overridable for tests.
    public var titleGenerator: any SessionTitleGenerating {
        if let titleGeneratorOverride { return titleGeneratorOverride }
        if useMockAI { return MockTitleGenerator() }
        #if canImport(FoundationModels)
            return FoundationModelsTitleGenerator()
        #else
            return MockTitleGenerator()
        #endif
    }
    var titleGeneratorOverride: (any SessionTitleGenerating)?

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

    public let connectionStore: ConnectionStore
    public let sessionStore: SessionStore
    public let keychain = KeychainService()
    public let schemaVM = SchemaViewModel()

    private let introspection = SchemaIntrospectionService()
    private var saveTask: Task<Void, Never>?
    private var didLaunch = false

    public init() {
        self.connectionStore = ConnectionStore()
        self.sessionStore = SessionStore()
    }

    /// Test initializer: points both stores at a temporary directory.
    init(connectionStore: ConnectionStore, sessionStore: SessionStore) {
        self.connectionStore = connectionStore
        self.sessionStore = sessionStore
    }

    // MARK: - Launch

    /// Called once at launch: loads connections and sessions, restores the
    /// selection, and surfaces Settings when no database is configured yet.
    public func onLaunch() async {
        guard !didLaunch else { return }
        didLaunch = true
        do {
            connections = try connectionStore.load()
        } catch {
            errorBanner = "Could not load the saved connections: \(error.localizedDescription)"
        }
        do {
            sessions = try sessionStore.load()
        } catch {
            errorBanner = "Could not load the saved sessions: \(error.localizedDescription)"
        }

        let restoredID = UserDefaults.standard
            .string(forKey: Self.selectedSessionKey)
            .flatMap(UUID.init(uuidString:))
        if let restoredID,
            let restored = session(for: restoredID),
            !restored.isArchived,
            connection(for: restored.connectionID) != nil
        {
            selectSession(restoredID)
        } else {
            selectSession(mostRecentVisibleSession()?.id)
        }

        if connections.isEmpty {
            openSettings(tab: .databases)
        }
    }

    /// Asks the UI to show Settings on the given tab. MainView watches
    /// `openSettingsRequest` and opens the Settings window.
    public func openSettings(tab: SettingsTab) {
        settingsTab = tab
        openSettingsRequest += 1
    }

    // MARK: - Connection helpers

    public func connection(for id: UUID) -> DatabaseConnectionConfig? {
        connections.first { $0.id == id }
    }

    public func connectionState(_ id: UUID) -> ConnectionStatus {
        connectionStates[id] ?? .notConnected
    }

    /// The connection behind the sidebar selection: the selected database
    /// itself, or the selected session's database.
    public var activeConnectionID: UUID? {
        switch sidebarSelection {
        case .database(let id): id
        case .session(let id): session(for: id)?.connectionID
        case nil: nil
        }
    }

    // MARK: - Schema selection

    /// The effective open schema for a connection: the persisted choice when
    /// it still exists in the loaded schema, else "public", else the first
    /// schema. Self-validating on every read, so a refresh that drops the
    /// chosen schema silently falls back.
    public func currentSchemaName(for connectionID: UUID) -> String? {
        guard let schema = schemas[connectionID], !schema.schemas.isEmpty else { return nil }
        if let chosen = selectedSchemaNames[connectionID],
            schema.schemas.contains(where: { $0.name == chosen })
        {
            return chosen
        }
        if schema.schemas.contains(where: { $0.name == "public" }) {
            return "public"
        }
        return schema.schemas.first?.name
    }

    public func selectSchema(_ name: String, for connectionID: UUID) {
        selectedSchemaNames[connectionID] = name
    }

    /// The schema handed to the SQL generator: the loaded schema narrowed to
    /// the open schema, so generations only see what the user has open.
    public func promptSchema(for connectionID: UUID) -> DatabaseSchema? {
        guard let schema = schemas[connectionID] else { return nil }
        guard let name = currentSchemaName(for: connectionID) else { return schema }
        return schema.filtered(toSchema: name)
    }

    private static func loadSelectedSchemaNames() -> [UUID: String] {
        guard
            let raw = UserDefaults.standard.dictionary(forKey: selectedSchemaNamesKey)
                as? [String: String]
        else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let id = UUID(uuidString: pair.key) { result[id] = pair.value }
        }
    }

    private static func saveSelectedSchemaNames(_ names: [UUID: String]) {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: names.map { ($0.key.uuidString, $0.value) }),
            forKey: selectedSchemaNamesKey)
    }

    /// Lazily creates and caches one `PostgresService` per connection.
    func postgres(for id: UUID) -> PostgresService {
        if let service = services[id] { return service }
        let service = PostgresService()
        services[id] = service
        return service
    }

    /// Connects the given database unless it is already connected or
    /// connecting. The schema is loaded only when it is not cached yet.
    public func connectIfNeeded(_ id: UUID) async {
        guard let config = connection(for: id) else { return }
        switch connectionState(id) {
        case .connected, .connecting: return
        case .notConnected, .error: break
        }

        connectionStates[id] = .connecting
        var password: String?
        do {
            password = try keychain.loadPassword(for: id)
        } catch {
            // Continue with no password — local trust auth may still work —
            // but tell the user the Keychain read failed.
            errorBanner = error.localizedDescription
        }

        do {
            try await postgres(for: id).connect(config: config, password: password)
            connectionStates[id] = .connected
            if schemas[id] == nil {
                await refreshSchema(for: id)
            }
        } catch {
            connectionStates[id] = .error(error.localizedDescription)
            errorBanner = error.localizedDescription
        }
    }

    public func disconnect(_ id: UUID) async {
        // Stop runs against this connection before tearing the client down.
        for controller in controllers.values where controller.connectionID == id {
            controller.queryVM.cancelRun()
        }
        if let service = services[id] {
            await service.disconnect()
        }
        connectionStates[id] = .notConnected
        // The schema cache is intentionally kept for the next connect.
    }

    public func refreshSchema(for id: UUID) async {
        guard connectionState(id) == .connected else { return }
        let previousSelection = schemaVM.selectedTableID
        schemas[id] = nil
        if activeConnectionID == id {
            schemaVM.selectedTableID = nil
        }
        loadingSchemas.insert(id)
        defer { loadingSchemas.remove(id) }
        do {
            let loadedSchema = try await introspection.loadSchema(using: postgres(for: id))
            schemas[id] = loadedSchema
            if let previousSelection,
                loadedSchema.tables.contains(where: { $0.id == previousSelection })
            {
                schemaVM.selectedTableID = previousSelection
            }
        } catch {
            schemas[id] = nil
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Connection CRUD

    /// Saves the password to the Keychain and the config to disk. When an
    /// existing connection's endpoint changed, the live client and cached
    /// schema are invalidated so the next session connects fresh.
    public func addOrUpdateConnection(
        _ config: DatabaseConnectionConfig, password: String
    ) throws {
        try keychain.savePassword(password, for: config.id)
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            let previous = connections[index]
            connections[index] = config
            if Self.endpointChanged(from: previous, to: config) {
                schemas[config.id] = nil
                Task { await disconnect(config.id) }
            }
        } else {
            connections.append(config)
        }
        try connectionStore.save(connections)
    }

    /// Removes the connection, its Keychain password, and — by design —
    /// every session that belongs to it.
    public func deleteConnection(_ id: UUID) {
        if let service = services.removeValue(forKey: id) {
            Task { await service.disconnect() }
        }
        try? keychain.deletePassword(for: id)
        connectionStates[id] = nil
        schemas[id] = nil
        selectedSchemaNames[id] = nil
        loadingSchemas.remove(id)

        let removedSessionIDs = Set(sessions.filter { $0.connectionID == id }.map(\.id))
        for sessionID in removedSessionIDs {
            controllers[sessionID]?.queryVM.cancelRun()
            controllers[sessionID] = nil
        }
        sessions.removeAll { removedSessionIDs.contains($0.id) }
        connections.removeAll { $0.id == id }

        switch sidebarSelection {
        case .session(let sessionID) where removedSessionIDs.contains(sessionID):
            selectSession(mostRecentVisibleSession()?.id)
        case .database(let databaseID) where databaseID == id:
            selectSession(mostRecentVisibleSession()?.id)
        default:
            break
        }

        do {
            try connectionStore.save(connections)
            try sessionStore.save(sessions)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private static func endpointChanged(
        from old: DatabaseConnectionConfig, to new: DatabaseConnectionConfig
    ) -> Bool {
        old.host != new.host
            || old.port != new.port
            || old.database != new.database
            || old.username != new.username
            || old.sslMode != new.sslMode
    }

    // MARK: - Session helpers

    public func session(for id: UUID) -> QuerySession? {
        sessions.first { $0.id == id }
    }

    /// Visible (non-archived) sessions of one connection, newest first.
    public func sessions(for connectionID: UUID) -> [QuerySession] {
        sessions
            .filter { $0.connectionID == connectionID && !$0.isArchived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var archivedSessions: [QuerySession] {
        sessions.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    public var selectedController: SessionController? {
        selectedSessionID.flatMap { controllers[$0] }
    }

    private func mostRecentVisibleSession() -> QuerySession? {
        sessions
            .filter { !$0.isArchived && connection(for: $0.connectionID) != nil }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Session lifecycle

    @discardableResult
    public func createSession(connectionID: UUID) -> QuerySession {
        let session = QuerySession(connectionID: connectionID)
        sessions.append(session)
        selectSession(session.id)
        flushSessions()
        return session
    }

    /// Selects a session: snapshots the outgoing controller, restores or
    /// creates the incoming one, and lazily connects its database. Passing
    /// nil (or an unknown id) falls back to browsing the first database.
    public func selectSession(_ id: UUID?) {
        if let outgoingID = selectedSessionID, outgoingID != id {
            sessionDidChange(outgoingID)
        }

        guard let id, let session = session(for: id) else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
            if let first = connections.first {
                selectDatabase(first.id)
            } else {
                sidebarSelection = nil
            }
            return
        }

        if controllers[id] == nil {
            controllers[id] = SessionController(session: session)
        }
        sidebarSelection = .session(id)
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedSessionKey)
        Task { await connectIfNeeded(session.connectionID) }
    }

    /// Selects a database row for schema browsing — no session involved.
    /// The database connects lazily so its schema fills the inspector.
    public func selectDatabase(_ id: UUID) {
        guard connection(for: id) != nil else { return }
        if let outgoingID = selectedSessionID {
            sessionDidChange(outgoingID)
        }
        sidebarSelection = .database(id)
        UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
        Task { await connectIfNeeded(id) }
    }

    public func renameSession(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].title = trimmed
        sessions[index].titleWasManuallySet = true
        sessions[index].updatedAt = Date()
        flushSessions()
    }

    /// Applies a model-generated title. The guards are re-checked here —
    /// the user may have renamed the session while the title generated.
    public func applyGeneratedTitle(_ title: String, to id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
            !sessions[index].titleWasManuallySet,
            sessions[index].title == QuerySession.placeholderTitle
        else { return }
        sessions[index].title = title
        sessions[index].updatedAt = Date()
        flushSessions()
    }

    /// Names a session after its first question. The model's title is
    /// sanitized; on failure (or an unusable result) the truncated question
    /// is used instead.
    public func autoTitleSession(_ id: UUID, question: String) async {
        guard let session = session(for: id),
            !session.titleWasManuallySet,
            session.title == QuerySession.placeholderTitle
        else { return }
        let generated = try? await titleGenerator.generateTitle(for: question)
        let title =
            generated.flatMap(SessionTitleFallback.sanitize)
            ?? SessionTitleFallback.title(from: question)
        // applyGeneratedTitle re-checks the guards — the user may have
        // renamed the session while the title was generating.
        applyGeneratedTitle(title, to: id)
    }

    public func archiveSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessionDidChange(id)
        sessions[index].isArchived = true
        sessions[index].updatedAt = Date()
        controllers[id]?.queryVM.cancelRun()
        controllers[id] = nil
        if selectedSessionID == id {
            let connectionID = sessions[index].connectionID
            if let next = sessions(for: connectionID).first ?? mostRecentVisibleSession() {
                selectSession(next.id)
            } else if connection(for: connectionID) != nil {
                selectDatabase(connectionID)
            } else {
                selectSession(nil)
            }
        }
        flushSessions()
    }

    public func restoreSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isArchived = false
        sessions[index].updatedAt = Date()
        flushSessions()
    }

    public func deleteSessionForever(_ id: UUID) {
        controllers[id]?.queryVM.cancelRun()
        controllers[id] = nil
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectSession(mostRecentVisibleSession()?.id)
        }
        flushSessions()
    }

    // MARK: - Session persistence

    /// Snapshots the session's controller and schedules a debounced save.
    public func sessionDidChange(_ id: UUID) {
        guard let controller = controllers[id],
            let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        var session = sessions[index]
        if controller.snapshot(into: &session) {
            sessions[index] = session
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushSessions()
        }
    }

    /// Writes all sessions to disk immediately.
    public func flushSessions() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try sessionStore.save(sessions)
        } catch {
            errorBanner = "Could not save sessions: \(error.localizedDescription)"
        }
    }
}
