import Foundation
import Testing

@testable import WidenKit

@Suite("OpenRouter production profile")
struct OpenRouterCatalogTests {
    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<(Data, HTTPURLResponse), Error>]
        private var recordedRequests: [URLRequest] = []

        init(_ result: Result<(Data, HTTPURLResponse), Error>) {
            results = [result]
        }

        init(_ results: [Result<(Data, HTTPURLResponse), Error>]) {
            self.results = results
        }

        var requests: [URLRequest] {
            lock.withLock { recordedRequests }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try lock.withLock {
                recordedRequests.append(request)
                guard !results.isEmpty else {
                    throw URLError(.badServerResponse)
                }
                return try results.removeFirst().get()
            }
        }
    }

    private static let watchBaseURL = URL(string: "https://openrouter.test/api/v1")!

    @Test func productionProfilePinsDistinctRequestedAndCanonicalIDs() {
        let profile = OpenRouterCatalog.productionProfile
        #expect(!profile.requestedModelID.isEmpty)
        #expect(!profile.expectedCanonicalModelID.isEmpty)
        #expect(profile.requestedModelID != profile.expectedCanonicalModelID)
        #expect(!profile.displayName.isEmpty)
    }

    @Test func releaseGateModelPolicyRejectsUnpinnedDocPublishingRuns() {
        let pinned = OpenRouterCatalog.productionProfile.requestedModelID
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: nil,
                releaseTriageVersion: "0.1.0",
                allowModelOverride: false
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: nil,
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: TextToSQLReleaseGateModelPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: false,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: false
            )
        }
        #expect(throws: Never.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: pinned,
                backendIncludesCloud: false,
                releaseGateVersion: "0.1.0",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
    }

    @Test func releaseArtifactVersionsCannotEscapeTheirOutputDirectory() {
        for version in ["0.1.0", "1.0-beta_1"] {
            #expect(throws: Never.self) {
                try TextToSQLReleaseArtifactVersionPolicy.validate(version)
            }
        }

        let invalidVersions = [
            "",
            "../README",
            "0.1/../../README",
            ".hidden",
            "version with spaces",
            "v\u{00E9}rsion",
            String(repeating: "a", count: 65),
        ]
        for version in invalidVersions {
            #expect(throws: TextToSQLReleaseArtifactVersionPolicy.Violation.self) {
                try TextToSQLReleaseArtifactVersionPolicy.validate(version)
            }
        }

        #expect(throws: TextToSQLReleaseArtifactVersionPolicy.Violation.self) {
            try TextToSQLReleaseGateModelPolicy.validate(
                model: "vendor/other",
                backendIncludesCloud: true,
                releaseGateVersion: "../README",
                releaseTriageVersion: nil,
                allowModelOverride: true
            )
        }
    }

    @Test func committedDocEligibilityRequiresVerifiedCloudEvaluation() {
        let profile = OpenRouterCatalog.productionProfile
        #expect(
            TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: nil,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: false,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: "vendor/other",
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: nil,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: "openai/gpt-5.5-unevaluated",
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 1
            )
        )
        #expect(
            !TextToSQLReleaseGateModelPolicy.canPublishCommittedDocs(
                model: profile.requestedModelID,
                expectedCanonicalModelID: profile.expectedCanonicalModelID,
                backendIncludesCloud: true,
                cloudEvaluatedResultCount: 0
            )
        )
    }

    @Test func committedDocIneligibilityExplainsMissingExecutionEvidence() {
        let profile = OpenRouterCatalog.productionProfile
        let reason = TextToSQLReleaseGateModelPolicy.committedDocIneligibility(
            model: profile.requestedModelID,
            expectedCanonicalModelID: profile.expectedCanonicalModelID,
            backendIncludesCloud: true,
            cloudEvaluatedResultCount: 0
        )

        #expect(reason == .cloudEvaluationRequired)
        #expect(reason?.description.contains("no backend-available cloud results") == true)
    }

    @Test func releaseGateViolationHasAnActionableLocalizedDescription() {
        let pinned = OpenRouterCatalog.productionProfile.requestedModelID
        let violation = TextToSQLReleaseGateModelPolicy.Violation(
            model: nil,
            pinnedModel: pinned
        )

        #expect(violation.localizedDescription.contains("require a cloud run"))
        #expect(violation.localizedDescription.contains("--allow-model-override"))
    }

    @Test func expectedCanonicalModelIDEnforcesOnlyThePinnedModel() {
        let profile = OpenRouterCatalog.productionProfile
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(
                forRequestedModelID: profile.requestedModelID
            ) == profile.expectedCanonicalModelID
        )
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(forRequestedModelID: "vendor/other-model")
                == nil
        )
        #expect(
            OpenRouterCatalog.expectedCanonicalModelID(
                forRequestedModelID: profile.expectedCanonicalModelID
            ) == nil
        )
    }

    @Test func canonicalWatchUsesOneFreshPublicSingleModelLookup() async throws {
        let profile = OpenRouterCatalog.productionProfile
        let transport = Self.watchTransport(
            id: profile.requestedModelID,
            canonicalModelID: profile.expectedCanonicalModelID
        )
        let catalogService = Self.watchCatalogService(transport: transport)

        let observation = try await OpenRouterProductionCanonicalWatch.check(
            catalogService: catalogService
        )

        #expect(!observation.hasDrift)
        #expect(observation.requestedModelID == profile.requestedModelID)
        #expect(observation.expectedCanonicalModelID == profile.expectedCanonicalModelID)
        #expect(observation.observedCanonicalModelID == profile.expectedCanonicalModelID)
        let request = try #require(transport.requests.only)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/model/openai/gpt-5.5")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Widen Canonical Watch")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpBody == nil)
    }

    @Test func canonicalWatchIgnoresWidenCachedAndStaleFallbackMetadata() async throws {
        let profile = OpenRouterCatalog.productionProfile
        let catalogEndpoint = Self.watchBaseURL.appendingPathComponent("models/user")
        let watchEndpoint = Self.watchEndpoint()
        let rolledCanonicalModelID = "openai/gpt-5.5-rolled"
        let transport = StubTransport([
            .success((
                Self.catalogResponseData(
                    id: profile.requestedModelID,
                    canonicalModelID: profile.expectedCanonicalModelID
                ),
                Self.watchHTTPResponse(url: catalogEndpoint)
            )),
            .success((
                Self.watchResponseData(
                    id: profile.requestedModelID,
                    canonicalModelID: rolledCanonicalModelID
                ),
                Self.watchHTTPResponse(url: watchEndpoint)
            )),
            .success((Data(), Self.watchHTTPResponse(url: watchEndpoint, statusCode: 503))),
        ])
        let catalogService = Self.watchCatalogService(transport: transport)

        let cached = try await catalogService.availableModels(
            apiKey: "cache-priming-key",
            forceRefresh: true
        )
        #expect(cached.only?.canonicalModelID == profile.expectedCanonicalModelID)

        let observation = try await OpenRouterProductionCanonicalWatch.check(
            catalogService: catalogService
        )
        #expect(observation.hasDrift)
        #expect(observation.observedCanonicalModelID == rolledCanonicalModelID)

        do {
            _ = try await OpenRouterProductionCanonicalWatch.check(
                catalogService: catalogService
            )
            Issue.record("Expected fresh catalog failure instead of cached metadata")
        } catch let error as OpenRouterProductionCanonicalWatchError {
            #expect(error == .catalogLookupFailed(profile.requestedModelID))
        } catch {
            Issue.record("Expected sanitized canonical watch error, got \(error)")
        }

        #expect(transport.requests.count == 3)
        #expect(transport.requests[0].url?.path == "/api/v1/models/user")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") != nil)
        #expect(transport.requests[1].url?.path == "/api/v1/model/openai/gpt-5.5")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.requests[1].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(transport.requests[2].url?.path == "/api/v1/model/openai/gpt-5.5")
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.requests[2].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }

    @Test func canonicalWatchReportsOnlyAConfirmedCanonicalMismatchAsDrift() async throws {
        let profile = OpenRouterCatalog.productionProfile
        let observedCanonicalModelID = "openai/gpt-5.5-rolled"
        let transport = Self.watchTransport(
            id: profile.requestedModelID,
            canonicalModelID: observedCanonicalModelID
        )

        let observation = try await OpenRouterProductionCanonicalWatch.check(
            catalogService: Self.watchCatalogService(transport: transport)
        )

        #expect(observation.hasDrift)
        #expect(observation.observedCanonicalModelID == observedCanonicalModelID)
        #expect(transport.requests.count == 1)
    }

    @Test func canonicalWatchRejectsMissingOrUnexpectedModelIdentity() async throws {
        let profile = OpenRouterCatalog.productionProfile

        await expectCanonicalWatchError(
            .requestedModelNotFound(profile.requestedModelID),
            data: Data(),
            statusCode: 404
        )
        await expectCanonicalWatchError(
            .unexpectedRequestedModel(profile.requestedModelID),
            data: Self.watchResponseData(
                id: "OpenAI/gpt-5.5",
                canonicalModelID: profile.expectedCanonicalModelID
            )
        )
    }

    @Test func canonicalWatchRejectsMissingEmptyOrInvalidCanonicalIdentity() async throws {
        let profile = OpenRouterCatalog.productionProfile

        await expectCanonicalWatchError(
            .canonicalModelMissing(profile.requestedModelID),
            data: Self.watchResponseData(id: profile.requestedModelID, canonicalModelID: nil)
        )
        await expectCanonicalWatchError(
            .canonicalModelInvalid(profile.requestedModelID),
            data: Self.watchResponseData(id: profile.requestedModelID, canonicalModelID: "")
        )
        await expectCanonicalWatchError(
            .canonicalModelInvalid(profile.requestedModelID),
            data: Self.watchResponseData(
                id: profile.requestedModelID,
                canonicalModelID: "openai/gpt-5.5 rolled\nunsafe"
            )
        )
        for invalidID in ["garbage", "/", "openai/", "/gpt-5.5", "openai//gpt-5.5"] {
            await expectCanonicalWatchError(
                .canonicalModelInvalid(profile.requestedModelID),
                data: Self.watchResponseData(
                    id: profile.requestedModelID,
                    canonicalModelID: invalidID
                )
            )
        }
        await expectCanonicalWatchError(
            .canonicalModelInvalid(profile.requestedModelID),
            data: Self.watchResponseData(
                id: profile.requestedModelID,
                canonicalModelID: "openai/" + String(repeating: "x", count: 200)
            )
        )
    }

    @Test func canonicalWatchTreatsMalformedHTTPAndTransportFailuresAsOperational() async {
        let profile = OpenRouterCatalog.productionProfile
        let endpoint = Self.watchEndpoint()
        let malformedTransport = StubTransport(
            .success((Data("not-json".utf8), Self.watchHTTPResponse(url: endpoint)))
        )
        do {
            _ = try await OpenRouterProductionCanonicalWatch.check(
                catalogService: Self.watchCatalogService(transport: malformedTransport)
            )
            Issue.record("Expected malformed catalog response to fail")
        } catch let error as OpenRouterProductionCanonicalWatchError {
            #expect(error == .catalogLookupFailed(profile.requestedModelID))
        } catch {
            Issue.record("Expected sanitized canonical watch error, got \(error)")
        }

        let serverTransport = StubTransport(
            .success((Data(), Self.watchHTTPResponse(url: endpoint, statusCode: 503)))
        )
        do {
            _ = try await OpenRouterProductionCanonicalWatch.check(
                catalogService: Self.watchCatalogService(transport: serverTransport)
            )
            Issue.record("Expected catalog HTTP failure")
        } catch let error as OpenRouterProductionCanonicalWatchError {
            #expect(error == .catalogLookupFailed(profile.requestedModelID))
        } catch {
            Issue.record("Expected sanitized canonical watch error, got \(error)")
        }

        let transportFailure = StubTransport(.failure(URLError(.timedOut)))
        do {
            _ = try await OpenRouterProductionCanonicalWatch.check(
                catalogService: Self.watchCatalogService(transport: transportFailure)
            )
            Issue.record("Expected catalog transport failure")
        } catch let error as OpenRouterProductionCanonicalWatchError {
            #expect(error == .catalogLookupFailed(profile.requestedModelID))
        } catch {
            Issue.record("Expected sanitized canonical watch error, got \(error)")
        }
    }

    private static func watchTransport(
        id: String,
        canonicalModelID: String?
    ) -> StubTransport {
        let endpoint = watchEndpoint()
        return StubTransport(
            .success((
                watchResponseData(id: id, canonicalModelID: canonicalModelID),
                watchHTTPResponse(url: endpoint)
            ))
        )
    }

    private static func watchCatalogService(
        transport: StubTransport
    ) -> OpenRouterModelCatalogService {
        OpenRouterModelCatalogService(
            transport: transport,
            baseURL: watchBaseURL,
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    private static func watchEndpoint() -> URL {
        watchBaseURL
            .appendingPathComponent("model")
            .appendingPathComponent("openai")
            .appendingPathComponent("gpt-5.5")
    }

    private static func watchResponseData(
        id: String,
        canonicalModelID: String?
    ) -> Data {
        var model: [String: Any] = ["id": id]
        if let canonicalModelID {
            model["canonical_slug"] = canonicalModelID
        }
        return try! JSONSerialization.data(withJSONObject: ["data": model])
    }

    private static func catalogResponseData(
        id: String,
        canonicalModelID: String?
    ) -> Data {
        var model: [String: Any] = ["id": id]
        if let canonicalModelID {
            model["canonical_slug"] = canonicalModelID
        }
        return try! JSONSerialization.data(withJSONObject: ["data": [model]])
    }

    private static func watchHTTPResponse(
        url: URL,
        statusCode: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func expectCanonicalWatchError(
        _ expected: OpenRouterProductionCanonicalWatchError,
        data: Data,
        statusCode: Int = 200
    ) async {
        let endpoint = Self.watchEndpoint()
        let transport = StubTransport(
            .success((data, Self.watchHTTPResponse(url: endpoint, statusCode: statusCode)))
        )
        do {
            _ = try await OpenRouterProductionCanonicalWatch.check(
                catalogService: Self.watchCatalogService(transport: transport)
            )
            Issue.record("Expected canonical watch failure \(expected)")
        } catch let error as OpenRouterProductionCanonicalWatchError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected canonical watch error, got \(error)")
        }
        #expect(transport.requests.count == 1)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
