import Foundation
import Testing

@testable import WidenKit

/// Pins the single-signer rule: an API key is attached only to https
/// requests for its own profile's host, and never when it belongs to
/// another provider. Every refusal happens before a request is sent.
@Suite("Credential host guard")
struct CredentialHostGuardTests {
    /// A non-OpenRouter profile with static capabilities, so a generation
    /// sends nothing before its first chat request.
    private static let staticProfile: CloudModelProfile = {
        var profile = CloudModelProfile.openRouterTest
        profile.provider = .particle
        profile.displayName = "Static Test Model"
        profile.baseURL = URL(string: "https://provider.test/v1")!
        profile.requestedModelID = "static-test-model"
        profile.capabilityResolution = .staticCapabilities(staticCapabilities)
        profile.usesOpenRouterRouting = false
        profile.foreignAPIKeyPrefixes = ["sk-or-"]
        return profile
    }()

    private static let staticCapabilities = CloudModelCapabilities(
        supportsResponseFormat: true,
        supportsStructuredOutputs: false,
        supportsTools: true,
        supportsToolChoice: true,
        supportsTemperature: false,
        supportsSeed: false,
        supportsMaxTokens: false,
        supportsMaxCompletionTokens: true,
        contextLength: 128_000,
        maximumCompletionTokens: 16_000,
        capabilitySource: .staticProfile,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )

    @Test func foreignHostRejectedBeforeSend() async throws {
        let profile = Self.staticProfile
        for url in [
            "https://openrouter.ai/api/v1/chat/completions",
            "https://provider.test.evil.test/v1/chat/completions",
            "http://provider.test/v1/chat/completions",
            "https://provider.test:8443/v1/chat/completions",
        ] {
            try expectCredentialRefusal {
                _ = try profile.authorizedRequest(URL(string: url)!, apiKey: "test-key")
            }
        }

        // A profile whose own base URL is not https can sign nothing, so the
        // generator and the agent fail without sending a request.
        var insecure = profile
        insecure.baseURL = URL(string: "http://provider.test/v1")!
        let generatorTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await CloudSQLGenerator(
                apiKey: "test-key",
                profile: insecure,
                transport: generatorTransport
            ).generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(generatorTransport.requests.isEmpty)

        let agentTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await makeAgent(profile: insecure, apiKey: "test-key", transport: agentTransport)
                .generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(agentTransport.requests.isEmpty)
    }

    @Test func signedRequestCarriesTheKeyOnlyForTheProfileHost() throws {
        let request = try Self.staticProfile.authorizedRequest(
            URL(string: "https://PROVIDER.test/v1/chat/completions")!,
            apiKey: "test-key"
        )

        #expect(request.httpMethod == "POST")
        #expect(
            request.allHTTPHeaderFields == [
                "Authorization": "Bearer test-key",
                "Content-Type": "application/json",
            ]
        )
    }

    @Test func foreignPrefixKeySendsNoRequest() async throws {
        let profile = Self.staticProfile
        for key in ["sk-or-v1-abc", " SK-OR-v1-abc"] {
            try expectCredentialRefusal {
                _ = try profile.authorizedRequest(profile.chatCompletionsURL, apiKey: key)
            }
        }

        let generatorTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await CloudSQLGenerator(
                apiKey: "sk-or-v1-abc",
                profile: profile,
                transport: generatorTransport
            ).generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(generatorTransport.requests.isEmpty)

        let agentTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await makeAgent(profile: profile, apiKey: "sk-or-v1-abc", transport: agentTransport)
                .generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(agentTransport.requests.isEmpty)
    }

    @Test func particleAndOpenRouterKeysNeverCrossProviders() async throws {
        try expectCredentialRefusal {
            _ = try CloudModelProfile.particle.authorizedRequest(
                CloudModelProfile.particle.chatCompletionsURL,
                apiKey: "sk-or-v1-abc"
            )
        }
        try expectCredentialRefusal {
            _ = try CloudModelProfile.openRouterGPT55.authorizedRequest(
                CloudModelProfile.openRouterGPT55.chatCompletionsURL,
                apiKey: "pai-abc"
            )
        }
        try expectCredentialRefusal {
            _ = try CloudModelProfile.particle.authorizedRequest(
                CloudModelProfile.openRouterGPT55.chatCompletionsURL,
                apiKey: "pai-abc"
            )
        }

        let generatorTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await CloudSQLGenerator(
                apiKey: "sk-or-v1-abc",
                profile: .particleTest,
                transport: generatorTransport
            ).generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(generatorTransport.requests.isEmpty)

        let agentTransport = RecordingTransport()
        try await expectAsyncCredentialRefusal {
            _ = try await makeAgent(profile: .particleTest, apiKey: "sk-or-v1-abc", transport: agentTransport)
                .generateSQL(question: "List users", schema: Self.makeSchema(), config: SQLGenerationConfig())
        }
        #expect(agentTransport.requests.isEmpty)

        #expect(OpenRouterModelCatalogService.evalShared(for: .particle) == nil)
    }

    @Test func catalogUnavailableForStaticCapabilityProfile() async throws {
        #expect(OpenRouterModelCatalogService.evalShared(for: Self.staticProfile) == nil)

        var staticOpenRouter = CloudModelProfile.openRouterTest
        staticOpenRouter.capabilityResolution = .staticCapabilities(Self.staticCapabilities)
        #expect(OpenRouterModelCatalogService.evalShared(for: staticOpenRouter) == nil)

        var catalogParticle = Self.staticProfile
        catalogParticle.capabilityResolution = .openRouterCatalog
        #expect(OpenRouterModelCatalogService.evalShared(for: catalogParticle) == nil)

        let shared = try #require(OpenRouterModelCatalogService.evalShared(for: .openRouterGPT55))
        #expect(OpenRouterModelCatalogService.evalShared(for: .openRouterGPT55) === shared)
        #expect(OpenRouterModelCatalogService.evalShared(for: .openRouterTest) !== shared)

        // Static capabilities resolve without a request, even when a catalog
        // is handed to the resolver.
        let catalogTransport = RecordingTransport()
        let resolver = CloudCapabilityResolver(
            profile: Self.staticProfile,
            catalogService: OpenRouterModelCatalogService(
                profile: .openRouterTest,
                transport: catalogTransport,
                cacheURL: Self.temporaryDirectory().appendingPathComponent("catalog.json")
            )
        )
        let lookup = try await resolver.validatedCapabilitiesForGeneration(
            apiKey: "test-key",
            maximumHTTPRequests: nil
        )
        #expect(lookup.capabilities == Self.staticCapabilities)
        #expect(lookup.httpRequestCount == 0)
        #expect(catalogTransport.requests.isEmpty)
    }

    @Test func openRouterConnectivityCheckSendsNothingForOtherProfiles() async {
        let transport = RecordingTransport()

        let result = await OpenRouterConnectivityCheck(
            apiKey: "test-key",
            profile: Self.staticProfile,
            transport: transport
        ).run()

        #expect(result.error?.category == .unsupportedFeature)
        #expect(transport.requests.isEmpty)
    }

    private func expectCredentialRefusal(_ body: () throws -> Void) throws {
        do {
            try body()
            Issue.record("expected the credential guard to refuse the request")
        } catch let failure as CloudRequestFailure {
            Self.expectCredentialRefusal(failure)
        }
    }

    private func expectAsyncCredentialRefusal(_ body: () async throws -> Void) async throws {
        do {
            try await body()
            Issue.record("expected the credential guard to refuse the request")
        } catch let failure as CloudRequestFailure {
            Self.expectCredentialRefusal(failure)
        } catch let failure as SchemaToolAgentFailure {
            #expect(failure.category == .cloudRequestFailure)
            Self.expectCredentialRefusal(try #require(failure.cloudFailure))
        }
    }

    private static func expectCredentialRefusal(_ failure: CloudRequestFailure) {
        #expect(failure.category == .invalidRequest)
        #expect(failure.message.lowercased().contains("credential host mismatch"))
        #expect(failure.diagnostic.attemptCount == 0)
    }

    private func makeAgent(
        profile: CloudModelProfile,
        apiKey: String,
        transport: RecordingTransport
    ) -> SchemaToolSQLAgent {
        SchemaToolSQLAgent(
            apiKey: apiKey,
            profile: profile,
            connectionID: UUID(),
            selectedSchemas: ["public"],
            transport: transport,
            indexStore: SchemaSearchIndexStore(directory: Self.temporaryDirectory())
        )
    }

    private static func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ]
        )
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-credential-guard-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
