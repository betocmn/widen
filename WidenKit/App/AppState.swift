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
    public var schemas: [UUID: DatabaseSchema] = [:] {
        didSet { schemaRevision &+= 1 }
    }
    /// Bumped on every change to `schemas`, so a cached schema fingerprint
    /// is reused only while the schemas it hashed are unchanged.
    @ObservationIgnored private var schemaRevision = 0
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

    /// Developer toggle: use the deterministic mock generator instead of
    /// Particle-1.
    public var useMockAI = UserDefaults.standard.bool(forKey: AppState.useMockAIKey) {
        didSet { UserDefaults.standard.set(useMockAI, forKey: Self.useMockAIKey) }
    }
    private static let useMockAIKey = "WidenUseMockAI"
    private static let selectedSessionKey = "WidenSelectedSessionID"

    static let missingParticleAPIKeyMessage = "Add a Particle API key in Settings › LLM."

    /// Test seam, mirrors `titleGeneratorOverride`: `.some(value)` replaces
    /// the Keychain lookup and save, including `.some(nil)` to force "no key
    /// stored", so tests never touch the real Keychain.
    var particleAPIKeyOverride: String??
    /// Test seam: the transport every Particle generator sends through.
    var cloudTransportOverride: (any HTTPTransport)?
    var sqlGeneratorOverride: (any SQLGenerator)?
    var queryExecutorOverride: (any QueryExecuting)?

    /// Set when Particle refused the key or account on a real request, and
    /// cleared by the next answer or a key change. In memory only.
    public private(set) var particleRuntimeIssue: ParticleRuntimeIssue?
    /// Bumped on every key save or removal. The key lives in the Keychain,
    /// which Observation cannot see, so reading this makes views that show
    /// the status refresh when the key changes.
    private var particleAPIKeyRevision = 0

    /// Whether text-to-SQL can answer: mock mode first, then a saved key,
    /// then any runtime issue Particle reported.
    public var textToSQLStatus: TextToSQLStatus {
        if useMockAI { return .mock }
        guard let key = particleAPIKey, !key.isEmpty else {
            return .notConfigured(Self.missingParticleAPIKeyMessage)
        }
        if let particleRuntimeIssue {
            return .unavailable(particleRuntimeIssue.message)
        }
        return .ready
    }

    private var particleAPIKey: String? {
        _ = particleAPIKeyRevision
        if let particleAPIKeyOverride { return particleAPIKeyOverride }
        return (try? keychain.loadParticleAPIKey()) ?? nil
    }

    /// Saves (empty deletes) the Particle API key. Keychain only; the key
    /// never touches UserDefaults. A key that belongs to another provider is
    /// refused with a banner, so it can never be sent to Particle.
    @discardableResult
    public func setParticleAPIKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = key.lowercased()
        guard
            !CloudModelCatalog.productionProfile.foreignAPIKeyPrefixes.contains(where: {
                normalizedKey.hasPrefix($0.lowercased())
            })
        else {
            errorBanner =
                "That is an OpenRouter key (sk-or-…). Text-to-SQL uses Particle-1, so paste a Particle API key (pai-…) from platform.particle.ai."
            return false
        }
        do {
            if particleAPIKeyOverride != nil {
                particleAPIKeyOverride = .some(key.isEmpty ? nil : key)
            } else {
                try keychain.saveParticleAPIKey(key)
            }
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
        particleAPIKeyRevision &+= 1
        particleRuntimeIssue = nil
        return true
    }

    /// The stored Particle API key, for the Settings field.
    public func loadParticleAPIKey() -> String? {
        if let particleAPIKeyOverride { return particleAPIKeyOverride }
        do {
            return try keychain.loadParticleAPIKey()
        } catch {
            errorBanner = error.localizedDescription
            return nil
        }
    }

    /// Records what a text-to-SQL run says about the Particle account. A
    /// rejected key, missing credits or missing inference scope is kept until
    /// a later run answers or the key changes; other failures leave the
    /// status alone. Mock runs say nothing about the account.
    func noteTextToSQLOutcome(_ outcome: TextToSQLRunOutcome) {
        guard !useMockAI else { return }
        switch outcome {
        case .answered:
            if particleRuntimeIssue != nil {
                particleRuntimeIssue = nil
            }
        case .failed(let category):
            if let issue = category.flatMap(ParticleRuntimeIssue.init(category:)) {
                particleRuntimeIssue = issue
            }
        }
    }

    /// Why text-to-SQL is off for one connection, or nil when it may run.
    /// A connection that turns off schema metadata sharing sends nothing to
    /// Particle, so it cannot generate SQL.
    public func textToSQLUnavailableMessage(for connectionID: UUID) -> String? {
        guard !useMockAI,
            let connection = connection(for: connectionID),
            !connection.allowCloudSchemaMetadata
        else { return nil }
        return "Text-to-SQL is off for this connection because schema metadata sharing is turned off."
    }

    /// The active SQL generation backend: mock takes precedence, then
    /// Particle-1 when a key is saved. Without a key, generation fails with a
    /// message that points at Settings › LLM.
    public var sqlGenerator: any SQLGenerator {
        makeSQLGenerator(connectionID: nil, schema: nil)
    }

    /// Connection-aware generation path used by live database sessions. The
    /// schema-tool agent needs host-controlled connection and schema scope;
    /// callers without that context keep using `sqlGenerator`.
    public func sqlGenerator(
        connectionID: UUID,
        schema: DatabaseSchema
    ) -> any SQLGenerator {
        makeSQLGenerator(connectionID: connectionID, schema: schema)
    }

    private func makeSQLGenerator(
        connectionID: UUID?,
        schema: DatabaseSchema?
    ) -> any SQLGenerator {
        if let sqlGeneratorOverride { return sqlGeneratorOverride }
        if useMockAI { return MockSQLGenerator() }
        guard let key = particleAPIKey, !key.isEmpty else {
            return UnavailableSQLGenerator(message: Self.missingParticleAPIKeyMessage)
        }
        let profile = CloudModelCatalog.productionProfile
        let generationConnection = connectionID.flatMap { connection(for: $0) }
        if let generationConnection, !generationConnection.allowCloudSchemaMetadata {
            return UnavailableSQLGenerator(
                message: "\(profile.displayName) SQL generation is disabled for this connection because schema metadata sharing is turned off in Database Settings."
            )
        }
        if let connectionID, let schema {
            let selectedSchemas = selectedSchemaSet(from: schema)
            return SchemaToolSQLAgent(
                apiKey: key,
                profile: profile,
                connectionID: connectionID,
                selectedSchemas: selectedSchemas,
                transport: cloudTransportOverride,
                indexStore: schemaSearchIndexStore ?? SchemaSearchIndexStore(),
                databaseInspectionPolicy: generationConnection?.databaseInspectionPolicy(
                    audience: DatabaseInspectionResultAudience.cloud
                ) ?? .disabled,
                databaseInspectionDatabase: databaseInspectionDatabase(
                    for: connectionID,
                    connection: generationConnection
                ),
                currentSchemaFingerprint: schemaFingerprintProvider(
                    connectionID: connectionID,
                    selectedSchemas: selectedSchemas
                )
            )
        }
        return CloudSQLGenerator(apiKey: key, profile: profile, transport: cloudTransportOverride)
    }

    private func selectedSchemaSet(from schema: DatabaseSchema) -> [String] {
        let names = Set(schema.schemas.map(\.name) + schema.tables.map(\.schema))
        return names.sorted()
    }

    private struct SchemaFingerprintKey: Hashable {
        var connectionID: UUID
        var selectedSchemas: [String]
    }

    /// Fingerprints hashed while `schemaRevision` was
    /// `schemaFingerprintCacheRevision`.
    @ObservationIgnored private var schemaFingerprintCache: [SchemaFingerprintKey: String] = [:]
    @ObservationIgnored private var schemaFingerprintCacheRevision = 0
    /// Test seam: how many times a scoped schema has been hashed.
    @ObservationIgnored private(set) var schemaFingerprintComputationCount = 0

    /// The schema-tool agent calls this on every turn and tool call, and
    /// fails as stale when the answer no longer matches its starting
    /// snapshot.
    func schemaFingerprintProvider(
        connectionID: UUID,
        selectedSchemas: [String]
    ) -> @Sendable () async throws -> String {
        { [weak self] in
            try await MainActor.run {
                guard let self else { return "" }
                return try self.schemaFingerprint(
                    connectionID: connectionID,
                    selectedSchemas: selectedSchemas
                )
            }
        }
    }

    /// Hashing the whole scoped schema on the main actor is costly, so the
    /// fingerprint is reused until `schemas` changes.
    private func schemaFingerprint(
        connectionID: UUID,
        selectedSchemas: [String]
    ) throws -> String {
        guard let schema = schemas[connectionID] else { return "" }
        if schemaFingerprintCacheRevision != schemaRevision {
            schemaFingerprintCache.removeAll()
            schemaFingerprintCacheRevision = schemaRevision
        }
        let key = SchemaFingerprintKey(connectionID: connectionID, selectedSchemas: selectedSchemas)
        if let cached = schemaFingerprintCache[key] {
            return cached
        }
        let scopedSchema: DatabaseSchema
        if selectedSchemas.count == 1, let name = selectedSchemas.first {
            scopedSchema = schema.filtered(toSchema: name)
        } else {
            scopedSchema = schema
        }
        let snapshot = SchemaSearchSnapshot(
            connectionID: connectionID,
            selectedSchemas: selectedSchemas,
            schema: scopedSchema
        )
        let fingerprint = try SchemaSearchIndexStore.cacheKey(for: snapshot).schemaFingerprint
        schemaFingerprintComputationCount += 1
        schemaFingerprintCache[key] = fingerprint
        return fingerprint
    }

    /// Label for the backend now serving generations, phrased to follow
    /// "Generating SQL with …" in the spinner and Settings.
    public var activeBackendDisplayName: String {
        useMockAI ? "the mock generator" : CloudModelCatalog.productionProfile.displayName
    }

    /// The session-title backend for a first message. Particle-1 names the
    /// session only when the message was a plain-English question, mock AI is
    /// off, Particle has reported no problem with the key, the connection
    /// shares schema metadata and a key is saved. Otherwise the title comes
    /// from the first question on this Mac, with no model involved.
    public func titleGenerator(
        for source: SessionTitleSource,
        connectionID: UUID?
    ) -> any SessionTitleGenerating {
        if let titleGeneratorOverride { return titleGeneratorOverride }
        // The key is read last, so the Keychain is only consulted when
        // everything else already allows a Particle title.
        guard source == .naturalLanguage, !useMockAI, particleRuntimeIssue == nil,
            let connectionID,
            connection(for: connectionID)?.allowCloudSchemaMetadata == true,
            let key = particleAPIKey, !key.isEmpty
        else { return MockTitleGenerator() }
        if let particleTitleGeneratorFactory { return particleTitleGeneratorFactory(key) }
        return ParticleTitleGenerator(
            apiKey: key,
            profile: CloudModelCatalog.productionProfile,
            transport: cloudTransportOverride
        )
    }
    /// Test seam: replaces every title backend, deterministic or not.
    var titleGeneratorOverride: (any SessionTitleGenerating)?
    /// Test seam: builds the Particle-1 title generator for a saved key, so
    /// tests can see when a session would be named by Particle-1.
    var particleTitleGeneratorFactory: ((String) -> any SessionTitleGenerating)?

    /// The paste-autofill backend. Deterministic and local by design: pasted
    /// text can contain credentials, so it is never sent to any model.
    public var connectionDetailsParser: any ConnectionDetailsParsing {
        MockConnectionDetailsParser()
    }

    /// nil when AI generation is ready; otherwise a user-readable reason.
    public var modelAvailabilityMessage: String? {
        textToSQLStatus.message
    }

    public let connectionStore: ConnectionStore
    public let sessionStore: SessionStore
    public let schemaStore: SchemaStore
    public let semanticBindingStore: DatabaseSemanticBindingStore
    public let keychain = KeychainService()
    public let schemaVM = SchemaViewModel()
    public var semanticBindings: [DatabaseSemanticBinding] = []

    /// The app's auto-updater, injected at launch by the app target so
    /// WidenKit's Settings UI can offer "check for updates" without depending
    /// on Sparkle. Nil in tests and until the app wires it up.
    public var updaterControl: (any UpdaterControlling)?

    /// nil in the app, where each agent uses the default index directory;
    /// the test initializer points it at the temporary directory.
    private let schemaSearchIndexStore: SchemaSearchIndexStore?
    private let retiredAIStateCleanup: RetiredAIStateCleanup
    private let introspection = SchemaIntrospectionService()
    private var saveTask: Task<Void, Never>?
    private var didLaunch = false

    public init() {
        let connectionStore = ConnectionStore()
        self.connectionStore = connectionStore
        self.sessionStore = SessionStore()
        self.schemaStore = SchemaStore()
        self.semanticBindingStore = DatabaseSemanticBindingStore()
        self.schemaSearchIndexStore = nil
        self.retiredAIStateCleanup = RetiredAIStateCleanup(
            defaults: .standard,
            applicationSupportDirectory: connectionStore.fileURL.deletingLastPathComponent(),
            deleteLegacyOpenRouterAPIKey: { try KeychainService().deleteLegacyOpenRouterAPIKey() }
        )
    }

    /// Test initializer: points both stores at a temporary directory. Unless a
    /// test injects its own `retiredAIStateCleanup`, the launch cleanup runs
    /// against that directory with a no-op Keychain deleter, so tests that
    /// call `onLaunch` never touch the real Keychain.
    init(
        connectionStore: ConnectionStore, sessionStore: SessionStore,
        schemaStore: SchemaStore,
        semanticBindingStore: DatabaseSemanticBindingStore? = nil,
        retiredAIStateCleanup: RetiredAIStateCleanup? = nil
    ) {
        let directory = connectionStore.fileURL.deletingLastPathComponent()
        self.connectionStore = connectionStore
        self.sessionStore = sessionStore
        self.schemaStore = schemaStore
        self.semanticBindingStore =
            semanticBindingStore ?? DatabaseSemanticBindingStore(directory: directory)
        self.schemaSearchIndexStore = SchemaSearchIndexStore(
            directory: directory.appendingPathComponent("schema-indexes", isDirectory: true)
        )
        self.retiredAIStateCleanup =
            retiredAIStateCleanup
            ?? RetiredAIStateCleanup(
                defaults: .standard,
                applicationSupportDirectory: directory,
                deleteLegacyOpenRouterAPIKey: {}
            )
    }

    // MARK: - Launch

    /// Called once at launch: removes the retired AI backends' leftovers,
    /// then loads the saved connections, schemas, and sessions. Nothing
    /// auto-opens — a fresh install starts on the welcome screen, whose Add
    /// Database button leads to Settings › Databases.
    public func onLaunch() async {
        guard !didLaunch else { return }
        didLaunch = true
        retiredAIStateCleanup.run()
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
        } catch let error as SessionStore.UnreadableFileError {
            let folder = (error.backupURL.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath
            errorBanner =
                "Could not read the saved sessions. The unreadable file was kept as "
                + "\(error.backupURL.lastPathComponent) in \(folder)."
        } catch {
            errorBanner = "Could not load the saved sessions: \(error.localizedDescription)"
        }
        do {
            semanticBindings = try semanticBindingStore.load()
        } catch {
            errorBanner = "Could not load remembered definitions: \(error.localizedDescription)"
        }

        UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
        sidebarSelection = nil
        #if DEBUG
            openDebugSettingsTab(from: ProcessInfo.processInfo.arguments)
        #endif
    }

    #if DEBUG
        static let debugOpenSettingsTabArgument = "-WidenDebugOpenSettingsTab"

        /// Debug builds only: `-WidenDebugOpenSettingsTab <tab>` (`general`,
        /// `llm`, `databases` or `archived`) opens Settings on that tab at
        /// launch, so screenshots can be taken without accessibility access.
        /// Nothing is saved; an unknown tab is ignored.
        func openDebugSettingsTab(from arguments: [String]) {
            guard let index = arguments.lastIndex(of: Self.debugOpenSettingsTabArgument),
                arguments.indices.contains(index + 1),
                let tab = SettingsTab(rawValue: arguments[index + 1].lowercased())
            else { return }
            openSettings(tab: tab)
        }
    #endif

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

    public func schemaForGeneration(
        _ generation: SQLGenerationResult?,
        connectionID: UUID
    ) -> DatabaseSchema? {
        guard let generation else { return nil }
        guard let schema = schemas[connectionID] else { return nil }
        if let name = generation.generationSchemaName,
            schema.containsSchema(named: name)
        {
            return schema.filtered(toSchema: name)
        }
        if let legacyScope = schemaForLegacyGeneration(generation, schema: schema) {
            return legacyScope
        }
        return promptSchema(for: connectionID)
    }

    private func schemaForLegacyGeneration(
        _ generation: SQLGenerationResult,
        schema: DatabaseSchema
    ) -> DatabaseSchema? {
        let schemaNames = referencedSchemaNames(in: generation, schema: schema)
        if schemaNames.count == 1, let name = schemaNames.first {
            return schema.filtered(toSchema: name)
        }
        if schemaNames.count > 1 {
            return schema
        }
        return nil
    }

    private func referencedSchemaNames(
        in generation: SQLGenerationResult,
        schema: DatabaseSchema
    ) -> Set<String> {
        let availableNames = Set(schema.schemas.map(\.name) + schema.tables.map(\.schema))
        var names = Set<String>()
        for referencedTable in generation.referencedTables {
            let parts = referencedTable.split(separator: ".", maxSplits: 1).map(String.init)
            if let name = parts.first, parts.count == 2, availableNames.contains(name) {
                names.insert(name)
            }
        }
        let analysis = SQLReferenceAnalyzer.analyze(generation.sql)
        for scope in analysis.scopes {
            for relation in scope.relations {
                if let name = relation.schema, availableNames.contains(name) {
                    names.insert(name)
                }
            }
        }
        for relation in analysis.upsertTargetRelations {
            if let name = relation.schema, availableNames.contains(name) {
                names.insert(name)
            }
        }
        return names
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

    func databaseInspectionDatabase(
        for id: UUID,
        connection: DatabaseConnectionConfig?
    ) -> (any DatabaseInspectionQuerying)? {
        guard connection?.allowLocalDataInspection == true,
            connectionState(id) == .connected
        else {
            return nil
        }
        return postgres(for: id)
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
        semanticBindings.removeAll { $0.connectionID == id }
        persistSemanticBindings()
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
            try semanticBindingStore.save(semanticBindings)
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

    /// True when the session's cached controller is generating SQL or running
    /// a query. Drives the sidebar's working indicator, which keeps showing
    /// across session switches because controllers persist once created.
    public func isSessionWorking(_ id: UUID) -> Bool {
        controllers[id]?.isWorking ?? false
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
        let schema = schemaForGeneration(session.lastGeneration, connectionID: session.connectionID)
        if let queryExecutorOverride {
            return SessionController(session: session, schema: schema, executor: queryExecutorOverride)
        }
        return SessionController(session: session, schema: schema)
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

    /// Names a session after its first question. `source` and `connectionID`
    /// decide whether Particle-1 may name it (see `titleGenerator(for:
    /// connectionID:)`); without a connection the title stays on this Mac.
    /// The model's title is sanitized; on failure (or an unusable result) the
    /// truncated question is used instead.
    public func autoTitleSession(
        _ id: UUID,
        question: String,
        source: SessionTitleSource = .naturalLanguage,
        connectionID: UUID? = nil
    ) async {
        guard let session = session(for: id),
            !session.titleWasManuallySet,
            session.title == QuerySession.placeholderTitle
        else { return }
        let generator = titleGenerator(for: source, connectionID: connectionID)
        let generated = try? await generator.generateTitle(for: question)
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

    public func currentSemanticBindings(
        for connectionID: UUID,
        schema: DatabaseSchema
    ) -> [DatabaseSemanticBinding] {
        semanticBindingStore.currentBindings(
            semanticBindings,
            connectionID: connectionID,
            schema: schema
        )
    }

    public func semanticBindingPromptLines(
        for connectionID: UUID,
        schema: DatabaseSchema
    ) -> [String] {
        currentSemanticBindings(for: connectionID, schema: schema).map(\.promptLine)
    }

    public func confirmSemanticBinding(
        connectionID: UUID,
        pending: PendingClarification,
        replyText: String,
        selectedOption: ClarificationOption?,
        schema: DatabaseSchema
    ) {
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = (selectedOption?.definition ?? trimmedReply)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return }
        let concept = pending.concept.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else { return }
        let evidence = Array(Set(pending.evidence + (selectedOption?.evidence ?? []))).sorted()
        let binding = DatabaseSemanticBinding(
            connectionID: connectionID,
            schemaNames: schema.semanticBindingSchemaNames,
            schemaFingerprint: schema.semanticFingerprint,
            concept: concept,
            definition: definition,
            evidence: evidence
        )
        semanticBindings.removeAll {
            $0.connectionID == connectionID
                && $0.schemaNames == binding.schemaNames
                && $0.schemaFingerprint == binding.schemaFingerprint
                && $0.concept.caseInsensitiveCompare(binding.concept) == .orderedSame
        }
        semanticBindings.append(binding)
        persistSemanticBindings()
    }

    public func deleteSemanticBinding(_ id: UUID) {
        semanticBindings.removeAll { $0.id == id }
        persistSemanticBindings()
    }

    private func persistSemanticBindings() {
        do {
            try semanticBindingStore.save(semanticBindings)
        } catch {
            errorBanner = "Could not save remembered definitions: \(error.localizedDescription)"
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
