import Foundation
import Testing

/// The app only ever builds Particle-1. OpenRouter stays in WidenKit as an
/// eval-only comparison provider, so the app and view layers must never
/// reach for its profiles, catalog, routing or connectivity check — any of
/// them would let a Particle key be signed for openrouter.ai.
@Suite("App layer provider isolation")
struct AppLayerProviderIsolationTests {
    private static let forbiddenSymbols = [
        "openRouterGPT55",
        "openRouter(requestedModelID",
        "OpenRouterModelCatalogService",
        "OpenRouterProviderPreferences",
        "OpenRouterConnectivityCheck",
        "CloudModelCatalog.profile(forRequestedModelID",
    ]
    private static let forbiddenHosts = ["openrouter.ai"]

    @Test func appAndViewSourcesNeverReferenceOpenRouterProviders() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try ["WidenKit/App", "WidenKit/Views"].flatMap {
            try Self.swiftFiles(in: repoRoot.appendingPathComponent($0, isDirectory: true))
        }
        let names = Set(files.map(\.lastPathComponent))
        // Guard against a vacuous pass if the folders move.
        #expect(names.isSuperset(of: [
            "AppState.swift", "SessionController.swift", "MainView.swift",
            "ParticleStatusChip.swift", "LLMSettingsView.swift",
        ]))

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let path = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for symbol in Self.forbiddenSymbols {
                #expect(!text.contains(symbol), "\(path) references \(symbol)")
            }
            for host in Self.forbiddenHosts {
                #expect(!text.lowercased().contains(host), "\(path) mentions \(host)")
            }
        }
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
