import Foundation
import Observation

/// Which tab the Settings UI shows.
public enum SettingsTab: String, Hashable, Sendable {
    case general
    case llm
    case databases
    case archived
}

public enum DatabaseSettingsRequest: Equatable, Sendable {
    case new
    case edit(UUID)
}

/// What the sidebar has selected: a whole database (for schema browsing)
/// or one of its query sessions.
public enum SidebarItem: Hashable, Sendable {
    case database(UUID)
    case session(UUID)
}

public struct LLMCompatibilityAlert: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case appleIntelligenceDisabled
        case localUnavailable
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let message: String
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
    /// Incremented to ask Settings > Databases to start an unsaved draft.
    public var newDatabaseSettingsRequest = 0
    /// Incremented to ask Settings > Databases to select a specific connection.
    public var editDatabaseSettingsRequest = 0
    public var editDatabaseSettingsID: UUID?
    /// Incremented to ask Settings > Databases to consume the latest request.
    public var databaseSettingsRequest = 0
    public var pendingDatabaseSettingsRequest: DatabaseSettingsRequest?
    public var errorBanner: String?
    public var llmCompatibilityAlert: LLMCompatibilityAlert?

    /// Developer toggle: use the deterministic mock generator instead of the
    /// on-device model.
    public var useMockAI = UserDefaults.standard.bool(forKey: AppState.useMockAIKey) {
        didSet { UserDefaults.standard.set(useMockAI, forKey: Self.useMockAIKey) }
    }
    private static let useMockAIKey = "WidenUseMockAI"
    private static let selectedSessionKey = "WidenSelectedSessionID"

    /// Whether SQL generation uses the on-device model or the configured
    /// cloud pro backend. The toolbar toggle flips this.
    public var aiBackendMode: AIBackendMode =
        AIBackendMode(
            rawValue: UserDefaults.standard.string(forKey: AppState.aiBackendModeKey) ?? "")
        ?? .local
    {
        didSet { UserDefaults.standard.set(aiBackendMode.rawValue, forKey: Self.aiBackendModeKey) }
    }
    private static let aiBackendModeKey = "WidenAIBackendMode"

    /// Which provider serves cloud generations. Defaults to OpenRouter —
    /// it works on every Mac today; Apple's Private Cloud Compute is an
    /// explicit opt-in (and only surfaces its requirements once selected).
    public var cloudProvider: CloudAIProvider =
        CloudAIProvider(
            rawValue: UserDefaults.standard.string(forKey: AppState.cloudProviderKey) ?? "")
        ?? .openRouter
    {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: Self.cloudProviderKey) }
    }
    private static let cloudProviderKey = "WidenCloudAIProvider"

    /// The OpenRouter model ID used for cloud generations.
    public var openRouterModelID: String =
        UserDefaults.standard.string(forKey: AppState.openRouterModelIDKey)
        ?? OpenRouterCatalog.defaultModelID
    {
        didSet {
            UserDefaults.standard.set(openRouterModelID, forKey: Self.openRouterModelIDKey)
        }
    }
    private static let openRouterModelIDKey = "WidenOpenRouterModelID"

    /// Test seam, mirrors `titleGeneratorOverride`: `.some(value)` replaces
    /// the Keychain lookup, including `.some(nil)` to force "no key stored".
    var openRouterAPIKeyOverride: String??
    /// Test seams for host-dependent model availability.
    var pccAvailabilityMessageOverride: String??
    var pccQuotaLimitReachedMessageOverride: String??
    var localModelAvailabilityMessageOverride: String??
    var localLLMEligibilityOverride: LocalLLMEligibility?
    var sqlGeneratorOverride: (any SQLGenerator)?
    var queryExecutorOverride: (any QueryExecuting)?

    /// Whether the chosen cloud provider can serve requests right now.
    public var cloudBackendStatus: CloudBackendStatus {
        switch cloudProvider {
        case .applePCC:
            if let message = pccAvailabilityMessage {
                return .unavailable(message)
            }
            if let message = pccQuotaLimitReachedMessage {
                return .unavailable(message)
            }
            return .ready
        case .openRouter:
            guard let key = openRouterAPIKey, !key.isEmpty else {
                return .notConfigured("Add an OpenRouter API key in Settings › LLM.")
            }
            guard !openRouterModelID.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .notConfigured("Choose an OpenRouter model in Settings › LLM.")
            }
            return .ready
        }
    }

    private var openRouterAPIKey: String? {
        if let openRouterAPIKeyOverride { return openRouterAPIKeyOverride }
        return (try? keychain.loadOpenRouterAPIKey()) ?? nil
    }

    private var pccAvailabilityMessage: String? {
        if let pccAvailabilityMessageOverride { return pccAvailabilityMessageOverride }
        return PCCSupport.availabilityMessage
    }

    private var pccQuotaLimitReachedMessage: String? {
        if let pccQuotaLimitReachedMessageOverride { return pccQuotaLimitReachedMessageOverride }
        return PCCSupport.quotaLimitReachedMessage
    }

    /// Saves (empty deletes) the OpenRouter API key. Keychain only; the key
    /// never touches UserDefaults.
    @discardableResult
    public func setOpenRouterAPIKey(_ key: String) -> Bool {
        do {
            try keychain.saveOpenRouterAPIKey(key)
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    /// The stored OpenRouter API key, for the Settings field.
    public func loadOpenRouterAPIKey() -> String? {
        do {
            return try keychain.loadOpenRouterAPIKey()
        } catch {
            errorBanner = error.localizedDescription
            return nil
        }
    }

    /// The active SQL generation backend: mock wins, then the selected
    /// backend if it is available. Production never silently swaps to another
    /// backend when the selected one is unavailable.
    public var sqlGenerator: any SQLGenerator {
        if let sqlGeneratorOverride { return sqlGeneratorOverride }
        if useMockAI { return MockSQLGenerator() }
        if aiBackendMode == .cloud {
            guard case .ready = cloudBackendStatus else {
                return UnavailableSQLGenerator(
                    message: cloudBackendStatus.message
                        ?? "The selected cloud model is unavailable. Check Settings › LLM.")
            }
            switch cloudProvider {
            case .openRouter:
                if let key = openRouterAPIKey, !key.isEmpty {
                    return OpenRouterSQLGenerator(apiKey: key, model: openRouterModelID)
                }
            case .applePCC:
                if let generator = PCCSupport.makeGenerator() {
                    return generator
                }
            }
            return UnavailableSQLGenerator(
                message: "The selected cloud model is unavailable. Check Settings › LLM.")
        }

        let localStatus = localLLMEligibility
        guard localStatus.isReady else {
            return UnavailableSQLGenerator(message: localStatus.message)
        }

        #if canImport(FoundationModels)
            return FoundationModelsSQLGenerator()
        #else
            return UnavailableSQLGenerator(
                message: LocalLLMEligibility.sdkUnavailable(
                    "The FoundationModels framework is not available to this build."
                ).message)
        #endif
        return UnavailableSQLGenerator(message: localStatus.message)
    }

    /// Label for the backend now serving generations, phrased to follow
    /// "Generating SQL with …" in the spinner and Settings.
    public var activeBackendDisplayName: String {
        if useMockAI { return "the mock generator" }
        if aiBackendMode == .cloud {
            switch cloudProvider {
            case .applePCC:
                return "Apple Private Cloud Compute"
            case .openRouter:
                return "\(OpenRouterCatalog.displayName(for: openRouterModelID)) via OpenRouter"
            }
        }
        return "the local model"
    }

    /// The active session-title backend. Overridable for tests.
    public var titleGenerator: any SessionTitleGenerating {
        if let titleGeneratorOverride { return titleGeneratorOverride }
        if useMockAI { return MockTitleGenerator() }
        #if canImport(FoundationModels)
            if localLLMEligibility.isReady {
                return FoundationModelsTitleGenerator()
            }
        #endif
        return MockTitleGenerator()
    }
    var titleGeneratorOverride: (any SessionTitleGenerating)?

    /// The paste-autofill backend. Local-only by design: pasted text can
    /// contain credentials, so there is no cloud fallback. Deterministic URL
    /// parsing still works when the on-device model is unavailable.
    public var connectionDetailsParser: (any ConnectionDetailsParsing)? {
        if useMockAI { return MockConnectionDetailsParser() }
        #if canImport(FoundationModels)
            if localLLMEligibility.isReady {
                return FoundationModelsConnectionParser()
            }
        #endif
        return MockConnectionDetailsParser()
    }

    /// nil when paste autofill is available; otherwise the user-readable
    /// reason the feature is disabled.
    public var connectionAutofillUnavailableMessage: String? {
        nil
    }

    /// nil when AI generation is ready; otherwise a user-readable reason.
    /// In cloud mode an unusable provider surfaces here instead of silently
    /// falling back to another backend.
    public var modelAvailabilityMessage: String? {
        if useMockAI { return nil }
        if aiBackendMode == .cloud {
            if let message = cloudBackendStatus.message {
                return message
            }
            if cloudProvider == .applePCC {
                return PCCSupport.quotaWarning
            }
            return nil
        }
        return localModelAvailabilityMessage
    }

    /// nil when the on-device model is ready; otherwise a user-readable
    /// reason. Mode-independent — Settings › LLM shows it for the Local
    /// section regardless of the active backend.
    public var localModelAvailabilityMessage: String? {
        if let localModelAvailabilityMessageOverride { return localModelAvailabilityMessageOverride }
        let status = localLLMEligibility
        return status.isReady ? nil : status.message
    }

    public var localLLMEligibility: LocalLLMEligibility {
        localLLMEligibilityOverride ?? LocalLLMEligibilityChecker.status()
    }

    public let connectionStore: ConnectionStore
    public let sessionStore: SessionStore
    public let schemaStore: SchemaStore
    public let keychain = KeychainService()
    public let schemaVM = SchemaViewModel()

    /// The app's auto-updater, injected at launch by the app target so
    /// WidenKit's Settings UI can offer "check for updates" without depending
    /// on Sparkle. Nil in tests and until the app wires it up.
    public var updaterControl: (any UpdaterControlling)?

    private let introspection = SchemaIntrospectionService()
    private var saveTask: Task<Void, Never>?
    private var didLaunch = false

    public init() {
        self.connectionStore = ConnectionStore()
        self.sessionStore = SessionStore()
        self.schemaStore = SchemaStore()
    }

    /// Test initializer: points both stores at a temporary directory.
    init(
        connectionStore: ConnectionStore, sessionStore: SessionStore,
        schemaStore: SchemaStore
    ) {
        self.connectionStore = connectionStore
        self.sessionStore = sessionStore
        self.schemaStore = schemaStore
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
            let cachedSchemas = try schemaStore.load()
            let connectionIDs = Set(connections.map(\.id))
            schemas = cachedSchemas.filter { connectionIDs.contains($0.key) }
        } catch {
            errorBanner = "Could not load the saved schema cache: \(error.localizedDescription)"
        }
        do {
            sessions = try sessionStore.load()
        } catch {
            errorBanner = "Could not load the saved sessions: \(error.localizedDescription)"
        }

        UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
        sidebarSelection = nil
        checkLocalLLMEligibilityForInstallIfNeeded()
    }

    public func checkLocalLLMEligibilityForInstallIfNeeded() {
        let status = localLLMEligibility
        guard !status.isReady else { return }
        guard !UserDefaults.standard.bool(forKey: Self.didShowInstallLLMCompatibilityAlertKey)
        else { return }

        UserDefaults.standard.set(true, forKey: Self.didShowInstallLLMCompatibilityAlertKey)
        llmCompatibilityAlert = compatibilityAlert(for: status)
    }

    @discardableResult
    public func requestAIBackendMode(_ mode: AIBackendMode) -> Bool {
        switch mode {
        case .local:
            let status = localLLMEligibility
            guard status.isReady else {
                llmCompatibilityAlert = compatibilityAlert(for: status)
                return false
            }
            aiBackendMode = .local
            return true
        case .cloud:
            if case .ready = cloudBackendStatus {
                aiBackendMode = .cloud
                return true
            }
            openSettings(tab: .llm)
            return false
        }
    }

    private func compatibilityAlert(for status: LocalLLMEligibility) -> LLMCompatibilityAlert {
        switch status {
        case .appleIntelligenceDisabled:
            return LLMCompatibilityAlert(
                kind: .appleIntelligenceDisabled,
                title: "Enable Apple Intelligence for Local mode",
                message: status.message
            )
        case .ready:
            return LLMCompatibilityAlert(
                kind: .localUnavailable,
                title: "Local model ready",
                message: status.message
            )
        default:
            return LLMCompatibilityAlert(
                kind: .localUnavailable,
                title: "Local model unavailable",
                message: status.message
            )
        }
    }

    /// Asks the UI to show Settings on the given tab. MainView watches
    /// `openSettingsRequest` and opens the Settings window.
    public func openSettings(tab: SettingsTab) {
        settingsTab = tab
        openSettingsRequest += 1
    }

    /// Opens Settings on Databases and starts the same draft flow as the
    /// Databases tab's "+" button.
    public func openNewDatabaseSettings() {
        settingsTab = .databases
        pendingDatabaseSettingsRequest = .new
        databaseSettingsRequest += 1
        newDatabaseSettingsRequest += 1
        openSettingsRequest += 1
    }

    /// Opens Settings on Databases and selects the requested connection.
    public func openDatabaseSettings(connectionID: UUID) {
        settingsTab = .databases
        pendingDatabaseSettingsRequest = .edit(connectionID)
        databaseSettingsRequest += 1
        editDatabaseSettingsID = connectionID
        editDatabaseSettingsRequest += 1
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

    static var didShowInstallLLMCompatibilityAlertKey: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "WidenDidShowInstallLLMCompatibilityAlert.\(version).\(build).v1"
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
    @discardableResult
    public func connectIfNeeded(_ id: UUID) async -> Bool {
        guard let config = connection(for: id) else { return false }
        switch connectionState(id) {
        case .connected:
            return true
        case .connecting:
            while connectionState(id) == .connecting {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return false
                }
            }
            return connectionState(id) == .connected
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
            return true
        } catch {
            connectionStates[id] = .error(error.localizedDescription)
            errorBanner = error.localizedDescription
            return false
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
        loadingSchemas.insert(id)
        defer { loadingSchemas.remove(id) }
        do {
            let loadedSchema = try await introspection.loadSchema(using: postgres(for: id))
            schemas[id] = loadedSchema
            persistSchemas()
            if activeConnectionID == id {
                if let previousSelection,
                    loadedSchema.tables.contains(where: { $0.id == previousSelection })
                {
                    schemaVM.selectedTableID = previousSelection
                } else {
                    schemaVM.selectedTableID = nil
                }
            }
        } catch {
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
                persistSchemas()
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
        persistSchemas()
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
            try schemaStore.save(schemas)
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
    public func createSession(
        connectionID: UUID,
        title: String = QuerySession.placeholderTitle,
        titleWasManuallySet: Bool = false,
        viewDataTarget: QuerySession.ViewDataTarget? = nil
    ) -> QuerySession {
        let session = QuerySession(
            connectionID: connectionID,
            title: title,
            titleWasManuallySet: titleWasManuallySet,
            viewDataTarget: viewDataTarget
        )
        sessions.append(session)
        selectSession(session.id)
        flushSessions()
        return session
    }

    /// Opens a deterministic session for browsing a table's rows. The SQL is
    /// treated like user-entered direct SQL: no model generation or title
    /// generation is involved.
    public func viewData(for table: TableInfo, connectionID: UUID) async {
        guard connection(for: connectionID) != nil else { return }
        let sql = Self.viewDataSQL(for: table)
        let target = QuerySession.ViewDataTarget(table: table)
        let controller: SessionController
        let viewDataSessionID: UUID
        if let existingSessionID = existingViewDataSessionID(
            connectionID: connectionID,
            target: target,
            sql: sql
        ) {
            selectSession(existingSessionID)
            guard let selectedController = controllers[existingSessionID] else { return }
            ensureViewDataTarget(target, on: existingSessionID)
            selectSchemaTable(for: target, connectionID: connectionID)
            viewDataSessionID = existingSessionID
            controller = selectedController
            guard !controller.queryVM.isRunning, !controller.chatVM.isGenerating else { return }
            controller.queryVM.setDirectSQL(sql)
            sessionDidChange(existingSessionID)
        } else {
            let session = createSession(
                connectionID: connectionID,
                title: "View \(table.qualifiedName)",
                titleWasManuallySet: true,
                viewDataTarget: target
            )
            guard let selectedController = controllers[session.id] else { return }
            viewDataSessionID = session.id
            controller = selectedController
            controller.chatVM.input = sql
            controller.chatVM.submitDirectSQL(queryVM: controller.queryVM)
            sessionDidChange(session.id)
        }

        guard await connectIfNeeded(connectionID) else {
            controller.chatVM.appendRunError(connectionFailureMessage(for: connectionID))
            sessionDidChange(viewDataSessionID)
            return
        }

        controller.runQuery(appState: self)
    }

    private func existingViewDataSessionID(
        connectionID: UUID,
        target: QuerySession.ViewDataTarget,
        sql: String
    ) -> UUID? {
        if let selectedSessionID {
            sessionDidChange(selectedSessionID)
        }
        return sessions(for: connectionID).first { session in
            session.viewDataTarget == target || isLegacyViewDataSession(session, sql: sql)
        }?.id
    }

    private func isLegacyViewDataSession(_ session: QuerySession, sql: String) -> Bool {
        session.messages.first { $0.role == .user }?.text == sql
    }

    private func ensureViewDataTarget(_ target: QuerySession.ViewDataTarget, on sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
            sessions[index].viewDataTarget != target
        else { return }
        sessions[index].viewDataTarget = target
        sessions[index].updatedAt = Date()
        flushSessions()
    }

    private func selectSchemaTableIfNeeded(for session: QuerySession) {
        guard let target = viewDataTarget(for: session) else { return }
        selectSchemaTable(for: target, connectionID: session.connectionID)
        ensureViewDataTarget(target, on: session.id)
    }

    private func viewDataTarget(for session: QuerySession) -> QuerySession.ViewDataTarget? {
        if let target = session.viewDataTarget {
            return target
        }
        guard let schema = schemas[session.connectionID],
            let firstSQL = session.messages.first(where: { $0.role == .user })?.text,
            let table = schema.tables.first(where: { Self.viewDataSQL(for: $0) == firstSQL })
        else { return nil }
        return QuerySession.ViewDataTarget(table: table)
    }

    private func selectSchemaTable(
        for target: QuerySession.ViewDataTarget,
        connectionID: UUID
    ) {
        selectSchema(target.schema, for: connectionID)
        schemaVM.selectedTableID = target.tableID
    }

    static func viewDataSQL(for table: TableInfo) -> String {
        viewDataSQL(for: QuerySession.ViewDataTarget(table: table))
    }

    private static func viewDataSQL(for target: QuerySession.ViewDataTarget) -> String {
        "SELECT * FROM \(quotedPostgresIdentifier(target.schema)).\(quotedPostgresIdentifier(target.table))"
    }

    private static func quotedPostgresIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
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
            controllers[id] = makeSessionController(session)
        }
        sidebarSelection = .session(id)
        selectSchemaTableIfNeeded(for: session)
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedSessionKey)
        Task { await connectIfNeeded(session.connectionID) }
    }

    private func makeSessionController(_ session: QuerySession) -> SessionController {
        if let queryExecutorOverride {
            return SessionController(session: session, executor: queryExecutorOverride)
        }
        return SessionController(session: session)
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
        sessions[index].title = SessionTitleFallback.titleCase(trimmed)
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
        sessions[index].title = SessionTitleFallback.titleCase(title)
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

    private func persistSchemas() {
        do {
            try schemaStore.save(schemas)
        } catch {
            errorBanner = "Could not save schema cache: \(error.localizedDescription)"
        }
    }

    private func connectionFailureMessage(for id: UUID) -> String {
        switch connectionState(id) {
        case .error(let message):
            message
        case .connecting:
            "Still connecting to the database."
        case .connected:
            AppError.notConnected.localizedDescription
        case .notConnected:
            AppError.notConnected.localizedDescription
        }
    }
}
