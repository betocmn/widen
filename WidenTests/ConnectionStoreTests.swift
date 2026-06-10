import Foundation
import Testing

@testable import WidenKit

@Suite("ConnectionStore")
struct ConnectionStoreTests {
    private func makeTempStore() -> (ConnectionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        return (ConnectionStore(directory: dir), dir)
    }

    @Test func loadFromEmptyDirectoryReturnsNoConnections() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load().isEmpty)
        #expect(try store.loadPrimary() == nil)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = DatabaseConnectionConfig(
            name: "Test",
            host: "localhost",
            port: 5433,
            database: "widen_test",
            username: "beto",
            sslMode: .prefer,
            defaultRowLimit: 250,
            statementTimeoutSeconds: 30
        )
        config.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        try store.savePrimary(config)

        let loaded = try #require(try store.loadPrimary())
        #expect(loaded.id == config.id)
        #expect(loaded.name == "Test")
        #expect(loaded.host == "localhost")
        #expect(loaded.port == 5433)
        #expect(loaded.database == "widen_test")
        #expect(loaded.username == "beto")
        #expect(loaded.sslMode == .prefer)
        #expect(loaded.defaultRowLimit == 250)
        #expect(loaded.statementTimeoutSeconds == 30)
    }

    @Test func savedFileNeverContainsPasswordField() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.savePrimary(DatabaseConnectionConfig(database: "db", username: "user"))
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.lowercased().contains("password"))
    }

    @Test func savePrimaryOverwritesPreviousConnection() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.savePrimary(DatabaseConnectionConfig(name: "One", database: "a", username: "u"))
        try store.savePrimary(DatabaseConnectionConfig(name: "Two", database: "b", username: "u"))
        let all = try store.load()
        #expect(all.count == 1)
        #expect(all.first?.name == "Two")
    }
}

@Suite("ConnectionSettingsViewModel validation")
@MainActor
struct ConnectionSettingsViewModelTests {
    private func makeValidViewModel() -> ConnectionSettingsViewModel {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.host = "localhost"
        viewModel.portText = "5432"
        viewModel.database = "widen_test"
        viewModel.username = "beto"
        return viewModel
    }

    @Test func validFormBuildsConfig() {
        let viewModel = makeValidViewModel()
        let config = viewModel.buildConfig()
        #expect(config != nil)
        #expect(viewModel.validationErrors.isEmpty)
        #expect(config?.port == 5432)
        #expect(config?.defaultRowLimit == 100)
        #expect(config?.statementTimeoutSeconds == 10)
    }

    @Test func invalidPortIsRejected() {
        let viewModel = makeValidViewModel()
        viewModel.portText = "70000"
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.contains { $0.contains("Port") })
    }

    @Test func missingRequiredFieldsAreRejected() {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.host = " "
        viewModel.database = ""
        viewModel.username = ""
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.count >= 3)
    }

    @Test func rowLimitAndTimeoutRangesAreEnforced() {
        let viewModel = makeValidViewModel()
        viewModel.rowLimitText = "0"
        viewModel.timeoutText = "500"
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.contains { $0.contains("Row limit") })
        #expect(viewModel.validationErrors.contains { $0.contains("Timeout") })
    }

    @Test func emptyPasswordIsAllowed() {
        let viewModel = makeValidViewModel()
        viewModel.password = ""
        #expect(viewModel.buildConfig() != nil)
    }
}
