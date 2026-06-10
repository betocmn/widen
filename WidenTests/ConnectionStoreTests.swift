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
    }

    @Test func saveAndLoadRoundTripPreservesMultipleConnections() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var first = DatabaseConnectionConfig(
            name: "Test",
            host: "localhost",
            port: 5433,
            database: "widen_test",
            username: "beto",
            sslMode: .prefer,
            defaultRowLimit: 250,
            statementTimeoutSeconds: 30
        )
        first.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let second = DatabaseConnectionConfig(
            name: "Staging", host: "10.0.0.5", database: "staging", username: "svc")
        try store.save([first, second])

        let all = try store.load()
        #expect(all.count == 2)
        let loaded = try #require(all.first)
        #expect(loaded.id == first.id)
        #expect(loaded.name == "Test")
        #expect(loaded.host == "localhost")
        #expect(loaded.port == 5433)
        #expect(loaded.database == "widen_test")
        #expect(loaded.username == "beto")
        #expect(loaded.sslMode == .prefer)
        #expect(loaded.defaultRowLimit == 250)
        #expect(loaded.statementTimeoutSeconds == 30)
        #expect(all.last?.id == second.id)
        #expect(all.last?.name == "Staging")
    }

    @Test func savedFileNeverContainsPasswordField() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([DatabaseConnectionConfig(database: "db", username: "user")])
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.lowercased().contains("password"))
    }

    @Test func saveOverwritesPreviousContents() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([DatabaseConnectionConfig(name: "One", database: "a", username: "u")])
        try store.save([DatabaseConnectionConfig(name: "Two", database: "b", username: "u")])
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
