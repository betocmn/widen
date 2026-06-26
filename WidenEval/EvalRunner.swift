import CryptoKit
import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

import WidenKit

struct EvalRun {
    var manifest: EvalRunManifest
    var results: [TextToSQLEvalResult]
    var summary: EvalRunSummary
    var backendSummaries: [TextToSQLEvalBackend: EvalRunSummary]
}

struct EvalRunManifest: Codable {
    var suiteName: String
    var suiteVersion: String
    var suitePath: String
    var evaluationMode: String
    var commitSHA: String
    var startedAt: String
    var finishedAt: String
    var backendMode: String
    var cloudAgentMode: String?
    var model: String?
    var osVersion: String
    var architecture: String
    var caseCount: Int
    var repeatCount: Int
    var caseTimeoutSeconds: Double
    var suiteFileHash: String
    var scorerVersion: String
    var scorerSourceHash: String
    var schemaFixtureHashes: [String: String]
    var semanticSuiteVersion: String?
    var semanticComparatorVersion: String?
    var semanticComparatorSourceHash: String?
    var setupFixtureHashes: [String: String]?
    var negativeControlMetadataHash: String?
    var postgresServerVersion: String?
    var semanticSettings: [String: String]?
}

struct EvalCountSummary: Codable {
    var count: Int
    var denominator: Int
}

struct EvalAverageSummary: Codable {
    var average: Double?
    var denominator: Int
}

struct EvalStaticSemanticCrossTab: Codable {
    var staticPassSemanticPass: Int
    var staticPassSemanticFail: Int
    var staticFailSemanticPass: Int
    var staticFailSemanticFail: Int
}

struct EvalRunSummary: Codable {
    var totalResults: Int
    var passed: Int
    var passRate: Double
    var statusCounts: [String: Int]
    var semanticPassed: Int?
    var semanticPassRate: Double?
    var semanticStatusCounts: [String: Int]?
    var sqlSemanticPass: EvalCountSummary?
    var clarificationDecisionPass: EvalCountSummary?
    var endToEndPass: EvalCountSummary?
    var endToEndPassRate: Double?
    var semanticEnvironmentAvailable: EvalCountSummary?
    var staticSemanticCrossTab: EvalStaticSemanticCrossTab?
    var semanticExecutionAttempted: EvalCountSummary?
    var resultEquivalent: EvalCountSummary?
    var goldenExecutionSucceeded: EvalCountSummary?
    var candidateExecutionSucceeded: EvalCountSummary?
    var backendAvailable: EvalCountSummary
    var transportSuccess: EvalCountSummary
    var structuredResponseParsed: EvalCountSummary
    var decisionMatches: EvalCountSummary
    var safetyValid: EvalCountSummary
    var schemaValid: EvalCountSummary
    var postgresVerificationAttemptedPass: EvalCountSummary?
    var postgresVerificationStatusCounts: [String: Int]?
    var forbiddenBindingViolationCount: Int
    var requiredTableCoverage: EvalAverageSummary
    var requiredColumnBindingCoverage: EvalAverageSummary
    var latency: LatencySummary
    var totalModelCalls: Int?
    var totalTokenUsage: Int?
    var estimatedCloudCostUSD: Double?
    var totalSchemaToolCalls: Int?
    var totalAgentModelTurns: Int?
    var totalAgentHTTPAttempts: Int?
    var toolBudgetFailureCount: Int?
    var averageEstimatedInitialPromptCharacters: Double?
    var maxEstimatedInitialPromptCharacters: Int?
}

struct LatencySummary: Codable {
    var minMs: Int
    var averageMs: Double
    var p50Ms: Int
    var p95Ms: Int
    var maxMs: Int
}

struct EvalRunner {
    private static let semanticSuiteVersion = "seeded-postgres-semantic-v2"

    var options: EvalCLIOptions

    func run() async throws -> EvalRun {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let suiteURL = URL(fileURLWithPath: options.suitePath).standardizedFileURL
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(TextToSQLEvalSuite.self, from: suiteData)
        let selectedCases = try filteredCases(suite.cases)
        try TextToSQLEvalSuiteValidator.validate(
            suite: suite,
            suiteURL: suiteURL
        )
        if options.semanticDatabase {
            try TextToSQLEvalSuiteValidator.validate(
                suite: TextToSQLEvalSuite(
                    name: suite.name,
                    version: suite.version,
                    cases: selectedCases
                ),
                suiteURL: suiteURL,
                requireSemanticExpectations: true
            )
        }
        let evalDirectory = suiteURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaDirectory = evalDirectory
            .appendingPathComponent("schemas", isDirectory: true)
        let repositoryRoot = evalDirectory.deletingLastPathComponent()
        let schemas = try loadSchemas(
            for: Set(selectedCases.map(\.schemaFixture)),
            schemaDirectory: schemaDirectory
        )
        let databaseDirectory = evalDirectory.appendingPathComponent("databases", isDirectory: true)
        var results: [TextToSQLEvalResult] = []
        var semanticPreparation: SemanticPreparation?
        if options.semanticDatabase {
            semanticPreparation = await prepareSemanticDatabases(
                cases: selectedCases,
                schemas: schemas.mapValues(\.schema),
                databaseDirectory: databaseDirectory
            )
        }

        do {
            for backend in options.backendMode.backends {
                let unavailable = backendUnavailableReason(for: backend)
                let generator = unavailable == nil ? makeGenerator(for: backend) : nil
                for evalCase in selectedCases {
                    guard let schema = schemas[evalCase.schemaFixture]?.schema else {
                        throw EvalRunnerError.missingSchemaFixture(evalCase.schemaFixture)
                    }
                    for repeatIndex in 1...options.repeatCount {
                        if let unavailable {
                            results.append(
                                backendUnavailableResult(
                                    evalCase: evalCase,
                                    backend: backend,
                                    message: unavailable,
                                    repeatIndex: repeatIndex
                                )
                            )
                        } else if let semanticPreparation,
                            let semanticSkip = semanticPreparation.skipResult(
                                for: evalCase,
                                backend: backend,
                                model: backend == .cloud ? options.model : nil,
                                repeatIndex: repeatIndex
                            )
                        {
                            results.append(semanticSkip)
                        } else if let generator {
                            let prompt = promptText(for: backend, evalCase: evalCase, schema: schema)
                            let verificationService: PostgresService?
                            let verificationConnection: PostgresConnectionHandle?
                            if let semanticPreparation,
                                evalCase.expected.decision == .sql,
                                let database = semanticPreparation.database(for: evalCase)
                            {
                                let service = PostgresService()
                                do {
                                    try await service.connect(
                                        config: database.config,
                                        password: database.executionPassword
                                    )
                                    verificationService = service
                                    verificationConnection = PostgresConnectionHandle(postgres: service)
                                } catch {
                                    results.append(
                                        semanticVerificationUnavailableResult(
                                            evalCase: evalCase,
                                            backend: backend,
                                            model: backend == .cloud ? options.model : nil,
                                            repeatIndex: repeatIndex,
                                            message:
                                                "PostgreSQL verification connection failed: \(error.localizedDescription)"
                                        )
                                    )
                                    continue
                                }
                            } else {
                                verificationService = nil
                                verificationConnection = nil
                            }
                            let runOptions = TextToSQLEvalRunOptions(
                                backend: backend,
                                model: backend == .cloud ? options.model : nil,
                                repeatIndex: repeatIndex,
                                estimatedInitialPromptCharacters: prompt.count,
                                estimatedInitialPrompt: options.recordPrompts ? prompt : nil,
                                caseTimeoutSeconds: options.caseTimeoutSeconds,
                                sqlVerifier: verificationConnection == nil ? nil : PostgresSQLVerifier(),
                                verificationConnection: verificationConnection
                            )
                            print("Running \(evalCase.id) [\(backend.rawValue)] repeat \(repeatIndex)")
                            let staticResult = await TextToSQLEvalCaseRunner.run(
                                evalCase: evalCase,
                                schema: schema,
                                generator: generator,
                                options: runOptions
                            )
                            if let verificationService {
                                await verificationService.disconnect()
                            }
                            if let semanticPreparation {
                                let semanticResult = await semanticPreparation.annotate(
                                    staticResult,
                                    evalCase: evalCase
                                )
                                results.append(semanticResult)
                            } else {
                                results.append(staticResult)
                            }
                        }
                    }
                }
            }
            await semanticPreparation?.cleanup()
        } catch {
            await semanticPreparation?.cleanup()
            throw error
        }

        let finishedAt = ISO8601DateFormatter().string(from: Date())
        let casesByID = Dictionary(uniqueKeysWithValues: selectedCases.map { ($0.id, $0) })
        let summary = summarize(results, casesByID: casesByID)
        let backendSummaries = Dictionary(
            uniqueKeysWithValues: options.backendMode.backends.map { backend in
                (backend, summarize(results.filter { $0.backend == backend }, casesByID: casesByID))
            }
        )
        let isOpenRouterSmoke = suite.name.hasPrefix("openrouter-smoke")
        let scorerSourcePaths = [
            "WidenKit/Evals/TextToSQLEvalCase.swift",
            "WidenKit/Evals/TextToSQLEvalScorer.swift",
            "WidenKit/Evals/TextToSQLEvalResult.swift",
            "WidenEval/EvalRunner.swift",
            "WidenKit/Services/TextToSQLPipeline.swift",
            "WidenKit/Services/SQLGenerationFailure.swift",
            "WidenKit/Services/GeneratedSQLRepairSupport.swift",
            "WidenKit/Services/GeneratedSQLVerifier.swift",
            "WidenKit/Services/PostgresErrorMapper.swift",
            "WidenKit/Services/PostgresService.swift",
        ] + (isOpenRouterSmoke ? ["WidenKit/Services/OpenRouterSQLGenerator.swift"] : [])
            + (options.cloudAgentMode == .tools ? [
                "WidenKit/Services/OpenRouterSchemaToolSQLAgent.swift",
                "WidenKit/Services/OpenRouterToolChatProtocol.swift",
                "WidenKit/Services/SchemaToolSession.swift",
            ] : [])
        let manifest = EvalRunManifest(
            suiteName: suite.name,
            suiteVersion: suite.version,
            suitePath: suiteURL.path,
            evaluationMode: isOpenRouterSmoke
                ? "openrouter-transport-smoke"
                : options.semanticDatabase
                ? "production-pipeline-static-shape-plus-seeded-postgres-semantic"
                : "production-pipeline-static-shape",
            commitSHA: Self.commitSHA(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            backendMode: options.backendMode.rawValue,
            cloudAgentMode: options.backendMode.backends.contains(.cloud)
                ? options.cloudAgentMode.rawValue
                : nil,
            model: options.backendMode == .local ? nil : options.model,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture(),
            caseCount: selectedCases.count,
            repeatCount: options.repeatCount,
            caseTimeoutSeconds: options.caseTimeoutSeconds,
            suiteFileHash: Self.sha256(suiteData),
            scorerVersion: isOpenRouterSmoke
                ? "openrouter-transport-smoke-v1"
                : "production-pipeline-static-shape-v1",
            scorerSourceHash: Self.sourceHash(
                relativePaths: scorerSourcePaths,
                relativeTo: repositoryRoot
            ),
            schemaFixtureHashes: schemas.mapValues(\.sha256),
            semanticSuiteVersion: options.semanticDatabase ? Self.semanticSuiteVersion : nil,
            semanticComparatorVersion: options.semanticDatabase
                ? TextToSQLSemanticComparator.version
                : nil,
            semanticComparatorSourceHash: options.semanticDatabase
                ? Self.sourceHash(
                    relativePaths: [
                        "WidenKit/Evals/TextToSQLSemanticComparator.swift",
                        "WidenKit/Evals/TextToSQLSemanticDatabase.swift",
                    ],
                    relativeTo: repositoryRoot
                )
                : nil,
            setupFixtureHashes: options.semanticDatabase
                ? Self.setupFixtureHashes(
                    fixtures: Set(selectedCases.map(\.schemaFixture)),
                    databaseDirectory: databaseDirectory
                )
                : nil,
            negativeControlMetadataHash: options.semanticDatabase
                ? Self.negativeControlMetadataHash(cases: selectedCases)
                : nil,
            postgresServerVersion: semanticPreparation?.postgresServerVersion,
            semanticSettings: options.semanticDatabase ? TextToSQLSemanticExecutor().settings : nil
        )
        return EvalRun(
            manifest: manifest,
            results: results,
            summary: summary,
            backendSummaries: backendSummaries
        )
    }

    private struct SemanticFixtureIssue: Sendable {
        var status: TextToSQLEvalCaseStatus
        var semanticStatus: TextToSQLSemanticStatus
        var message: String
    }

    private final class SemanticPreparation: @unchecked Sendable {
        private let provisioner: TextToSQLSemanticDatabaseProvisioner
        private let server: TextToSQLSemanticDatabaseServer
        private let executor: TextToSQLSemanticExecutor
        private let databases: [String: TextToSQLSemanticProvisionedDatabase]
        private let caseIssues: [String: SemanticFixtureIssue]
        private let fixtureIssues: [String: SemanticFixtureIssue]
        private let globalIssue: SemanticFixtureIssue?
        let postgresServerVersion: String?

        init(
            provisioner: TextToSQLSemanticDatabaseProvisioner,
            server: TextToSQLSemanticDatabaseServer,
            executor: TextToSQLSemanticExecutor,
            databases: [String: TextToSQLSemanticProvisionedDatabase],
            caseIssues: [String: SemanticFixtureIssue],
            fixtureIssues: [String: SemanticFixtureIssue],
            globalIssue: SemanticFixtureIssue?,
            postgresServerVersion: String?
        ) {
            self.provisioner = provisioner
            self.server = server
            self.executor = executor
            self.databases = databases
            self.caseIssues = caseIssues
            self.fixtureIssues = fixtureIssues
            self.globalIssue = globalIssue
            self.postgresServerVersion = postgresServerVersion
        }

        func cleanup() async {
            for database in databases.values {
                await provisioner.drop(database)
            }
        }

        func skipResult(
            for evalCase: TextToSQLEvalCase,
            backend: TextToSQLEvalBackend,
            model: String?,
            repeatIndex: Int
        ) -> TextToSQLEvalResult? {
            guard evalCase.expected.decision == .sql else { return nil }
            let issue = globalIssue ?? fixtureIssues[evalCase.schemaFixture] ?? caseIssues[evalCase.id]
            guard let issue else { return nil }
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: backend,
                model: model,
                repeatIndex: repeatIndex,
                status: issue.status,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: false,
                    structuredResponseParsed: false,
                    decisionMatches: false,
                    latencyMs: 0,
                    semanticExecutionAttempted: false,
                    semanticEnvironmentAvailable: issue.semanticStatus != .semanticEnvironmentUnavailable,
                    endToEndPassed: false,
                    semanticStatus: issue.semanticStatus
                ),
                diagnostics: TextToSQLEvalDiagnostics(errorMessage: issue.message)
            )
        }

        func database(for evalCase: TextToSQLEvalCase) -> TextToSQLSemanticProvisionedDatabase? {
            databases[evalCase.schemaFixture]
        }

        func annotate(
            _ result: TextToSQLEvalResult,
            evalCase: TextToSQLEvalCase
        ) async -> TextToSQLEvalResult {
            guard evalCase.expected.decision == .sql else {
                return result.withSemantic(
                    status: .notApplicable,
                    attempted: false,
                    endToEndPassed: result.status == .passed,
                    comparisonMode: nil
                )
            }

            guard evalCase.expected.decision == .sql,
                let goldenSQL = evalCase.expected.goldenSQL?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                !goldenSQL.isEmpty,
                let semantic = evalCase.expected.semantic,
                let candidateSQL = result.generatedSQL?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                !candidateSQL.isEmpty,
                result.metrics.safetyValid == true,
                result.metrics.schemaValid == true,
                result.metrics.postgresVerificationStatus == .passed,
                let database = databases[evalCase.schemaFixture]
            else {
                return result.withSemantic(
                    status: result.metrics.postgresVerificationStatus == .failed
                        ? .candidateExecutionFailure
                        : .notApplicable,
                    attempted: false,
                    endToEndPassed: false,
                    comparisonMode: evalCase.expected.semantic?.comparisonMode,
                    message: result.metrics.postgresVerificationStatus == .failed
                        ? "PostgreSQL verification failed before semantic execution."
                        : nil
                )
            }

            do {
                let output = try await executor.executePair(
                    goldenSQL: goldenSQL,
                    candidateSQL: candidateSQL,
                    expectation: semantic,
                    database: database
                )
                return result.withSemantic(output: output, comparisonMode: semantic.comparisonMode)
            } catch {
                return result.withSemantic(
                    status: .semanticEnvironmentUnavailable,
                    attempted: false,
                    endToEndPassed: false,
                    comparisonMode: semantic.comparisonMode,
                    message: "PostgreSQL semantic execution failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func prepareSemanticDatabases(
        cases: [TextToSQLEvalCase],
        schemas: [String: DatabaseSchema],
        databaseDirectory: URL
    ) async -> SemanticPreparation {
        let server = TextToSQLSemanticDatabaseServer.fromEnvironment(ProcessInfo.processInfo.environment)
        let provisioner = TextToSQLSemanticDatabaseProvisioner(server: server)
        let executor = TextToSQLSemanticExecutor()
        var databases: [String: TextToSQLSemanticProvisionedDatabase] = [:]
        var caseIssues: [String: SemanticFixtureIssue] = [:]
        var fixtureIssues: [String: SemanticFixtureIssue] = [:]
        let casesByFixture = Dictionary(grouping: cases, by: \.schemaFixture)
        let serverVersion = try? await provisioner.serverVersion()

        for fixture in casesByFixture.keys.sorted() {
            guard let schema = schemas[fixture] else {
                fixtureIssues[fixture] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .fixtureInvalid,
                    message: "Missing schema fixture \(fixture)."
                )
                continue
            }
            let setupURL = databaseDirectory
                .appendingPathComponent(fixture, isDirectory: true)
                .appendingPathComponent("setup.json")
            do {
                let database = try await provisioner.provision(
                    fixture: fixture,
                    setupURL: setupURL,
                    expectedSchema: schema
                )
                let issues = await validateSemanticFixture(
                    fixture: fixture,
                    cases: casesByFixture[fixture] ?? [],
                    schema: schema,
                    database: database,
                    executor: executor
                )
                caseIssues.merge(issues) { current, _ in current }
                databases[fixture] = database
            } catch let error as TextToSQLSemanticDatabaseError {
                switch error {
                case .environmentUnavailable(let message):
                    let globalIssue = SemanticFixtureIssue(
                        status: .semanticEnvironmentUnavailable,
                        semanticStatus: .semanticEnvironmentUnavailable,
                        message: message
                    )
                    return SemanticPreparation(
                        provisioner: provisioner,
                        server: server,
                        executor: executor,
                        databases: databases,
                        caseIssues: caseIssues,
                        fixtureIssues: fixtureIssues,
                        globalIssue: globalIssue,
                        postgresServerVersion: serverVersion
                    )
                case .fixtureInvalid(let message), .setupInvalid(let message),
                    .resultLimitExceeded(let message):
                    fixtureIssues[fixture] = SemanticFixtureIssue(
                        status: .fixtureInvalid,
                        semanticStatus: .fixtureInvalid,
                        message: message
                    )
                }
            } catch {
                fixtureIssues[fixture] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .fixtureInvalid,
                    message: "Fixture \(fixture) semantic preflight failed: \(error.localizedDescription)"
                )
            }
        }

        return SemanticPreparation(
            provisioner: provisioner,
            server: server,
            executor: executor,
            databases: databases,
            caseIssues: caseIssues,
            fixtureIssues: fixtureIssues,
            globalIssue: nil,
            postgresServerVersion: serverVersion
        )
    }

    private func validateSemanticFixture(
        fixture: String,
        cases: [TextToSQLEvalCase],
        schema: DatabaseSchema,
        database: TextToSQLSemanticProvisionedDatabase,
        executor: TextToSQLSemanticExecutor
    ) async -> [String: SemanticFixtureIssue] {
        var issues: [String: SemanticFixtureIssue] = [:]
        for evalCase in cases where evalCase.expected.decision == .sql {
            guard let goldenSQL = evalCase.expected.goldenSQL,
                let semantic = evalCase.expected.semantic
            else {
                issues[evalCase.id] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .fixtureInvalid,
                    message: "Fixture \(fixture) case \(evalCase.id) is missing semantic SQL metadata."
                )
                continue
            }

            let goldenSafety = SQLSafetyValidator.validate(goldenSQL)
            let goldenSchemaValidation = SQLSchemaValidator.validate(sql: goldenSQL, against: schema)
            guard goldenSafety.isValid, !goldenSchemaValidation.hasDefiniteErrors else {
                issues[evalCase.id] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .goldenFixtureFailure,
                    message: "Fixture \(fixture) case \(evalCase.id) golden SQL failed safety/schema preflight: \((goldenSafety.errors + goldenSchemaValidation.errors).joined(separator: " "))"
                )
                continue
            }

            let goldenOutput: TextToSQLSemanticExecutionOutput
            do {
                goldenOutput = try await executor.executePair(
                    goldenSQL: goldenSQL,
                    candidateSQL: goldenSQL,
                    expectation: semantic,
                    database: database
                )
            } catch {
                issues[evalCase.id] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .goldenFixtureFailure,
                    message: "Fixture \(fixture) case \(evalCase.id) golden SQL failed semantic preflight: \(error.localizedDescription)"
                )
                continue
            }

            guard goldenOutput.goldenExecutionSucceeded,
                goldenOutput.candidateExecutionSucceeded,
                goldenOutput.comparison?.equivalent == true
            else {
                issues[evalCase.id] = SemanticFixtureIssue(
                    status: .fixtureInvalid,
                    semanticStatus: .goldenFixtureFailure,
                    message: "Fixture \(fixture) case \(evalCase.id) golden SQL failed semantic preflight: \(goldenOutput.goldenError ?? goldenOutput.candidateError ?? goldenOutput.comparison?.mismatchCategory ?? "self-comparison failed")."
                )
                continue
            }

            for negative in semantic.negativeControls {
                let negativeSafety = SQLSafetyValidator.validate(negative.sql)
                let negativeSchemaValidation = SQLSchemaValidator.validate(sql: negative.sql, against: schema)
                guard negativeSafety.isValid, !negativeSchemaValidation.hasDefiniteErrors else {
                    issues[evalCase.id] = SemanticFixtureIssue(
                        status: .fixtureInvalid,
                        semanticStatus: .fixtureInvalid,
                        message: "Fixture \(fixture) case \(evalCase.id) negative control \(negative.id) failed safety/schema preflight: \((negativeSafety.errors + negativeSchemaValidation.errors).joined(separator: " "))"
                    )
                    break
                }

                var negativeExpectation = semantic
                if let mode = negative.comparisonMode {
                    negativeExpectation.comparisonMode = mode
                }
                let output: TextToSQLSemanticExecutionOutput
                do {
                    output = try await executor.executePair(
                        goldenSQL: goldenSQL,
                        candidateSQL: negative.sql,
                        expectation: negativeExpectation,
                        database: database
                    )
                } catch {
                    issues[evalCase.id] = SemanticFixtureIssue(
                        status: .fixtureInvalid,
                        semanticStatus: .fixtureInvalid,
                        message: "Fixture \(fixture) case \(evalCase.id) negative control \(negative.id) failed semantic preflight: \(error.localizedDescription)"
                    )
                    break
                }
                guard output.goldenExecutionSucceeded,
                    output.candidateExecutionSucceeded,
                    output.comparison?.equivalent == false
                else {
                    issues[evalCase.id] = SemanticFixtureIssue(
                        status: .fixtureInvalid,
                        semanticStatus: .fixtureInvalid,
                        message: "Fixture \(fixture) case \(evalCase.id) negative control \(negative.id) did not prove semantic mismatch: \(output.goldenError ?? output.candidateError ?? output.comparison?.mismatchCategory ?? "matched golden result")."
                    )
                    break
                }
            }
        }
        return issues
    }

    private func filteredCases(_ cases: [TextToSQLEvalCase]) throws -> [TextToSQLEvalCase] {
        guard let caseID = options.caseID else { return cases }
        let matches = cases.filter { $0.id == caseID }
        guard !matches.isEmpty else { throw EvalRunnerError.missingCase(caseID) }
        return matches
    }

    private func loadSchemas(
        for fixtures: Set<String>,
        schemaDirectory: URL
    ) throws -> [String: (schema: DatabaseSchema, sha256: String)] {
        try fixtures.reduce(into: [:]) { result, fixture in
            let url = schemaDirectory.appendingPathComponent("\(fixture)-schema.json")
            let data = try Data(contentsOf: url)
            let schema = try JSONDecoder().decode(DatabaseSchema.self, from: data)
            result[fixture] = (schema, Self.sha256(data))
        }
    }

    private func makeGenerator(for backend: TextToSQLEvalBackend) -> (any SQLGenerator)? {
        switch backend {
        case .local:
            #if canImport(FoundationModels)
                return FoundationModelsSQLGenerator()
            #else
                return nil
            #endif
        case .cloud:
            guard let apiKey = Self.openRouterAPIKey() else { return nil }
            if options.cloudAgentMode == .tools {
                return EvalCloudSchemaToolSQLGenerator(apiKey: apiKey, model: options.model)
            }
            return OpenRouterSQLGenerator(apiKey: apiKey, model: options.model)
        }
    }

    private func backendUnavailableReason(for backend: TextToSQLEvalBackend) -> String? {
        switch backend {
        case .local:
            #if canImport(FoundationModels)
                return FoundationModelsSQLGenerator.availabilityMessage
            #else
                return "Foundation Models is not available in this build."
            #endif
        case .cloud:
            return Self.openRouterAPIKey() == nil
                ? "WIDEN_EVAL_OPENROUTER_API_KEY is not set."
                : nil
        }
    }

    private func promptText(
        for backend: TextToSQLEvalBackend,
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema
    ) -> String {
        if backend == .cloud, options.cloudAgentMode == .tools {
            return [
                "Schema-tool agent initial request estimate.",
                "The full DatabaseSchema is intentionally not sent in the first request.",
                "Question: \(evalCase.question)",
                "Database context: \(evalCase.databaseContext ?? "")",
            ].joined(separator: "\n")
        }
        let budget = backend == .cloud ? 60_000 : 8_000
        return SQLPromptBuilder.prompt(
            question: evalCase.question,
            schema: schema,
            databaseContext: evalCase.databaseContext,
            maxSchemaCharacters: budget
        )
    }

    private func backendUnavailableResult(
        evalCase: TextToSQLEvalCase,
        backend: TextToSQLEvalBackend,
        message: String,
        repeatIndex: Int
    ) -> TextToSQLEvalResult {
        let semanticDatabase = options.semanticDatabase
        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: backend,
            model: backend == .cloud ? options.model : nil,
            repeatIndex: repeatIndex,
            status: .backendUnavailable,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: false,
                transportSuccess: false,
                structuredResponseParsed: false,
                decisionMatches: false,
                latencyMs: 0,
                semanticExecutionAttempted: semanticDatabase ? false : nil,
                semanticEnvironmentAvailable: nil,
                endToEndPassed: semanticDatabase ? false : nil,
                semanticStatus: semanticDatabase ? .notApplicable : nil
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: message)
        )
    }

    private func semanticVerificationUnavailableResult(
        evalCase: TextToSQLEvalCase,
        backend: TextToSQLEvalBackend,
        model: String?,
        repeatIndex: Int,
        message: String
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: backend,
            model: model,
            repeatIndex: repeatIndex,
            status: .semanticEnvironmentUnavailable,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: false,
                structuredResponseParsed: false,
                decisionMatches: false,
                latencyMs: 0,
                postgresVerificationStatus: .skippedNoConnection,
                semanticExecutionAttempted: false,
                semanticEnvironmentAvailable: false,
                endToEndPassed: false,
                semanticStatus: .semanticEnvironmentUnavailable
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: message)
        )
    }

    private func summarize(
        _ results: [TextToSQLEvalResult],
        casesByID: [String: TextToSQLEvalCase]
    ) -> EvalRunSummary {
        let statusCounts = results.reduce(into: [String: Int]()) { counts, result in
            counts[result.status.rawValue, default: 0] += 1
        }
        let passed = statusCounts[TextToSQLEvalCaseStatus.passed.rawValue, default: 0]
        let latencies = results.map(\.metrics.latencyMs).sorted()
        let modelCalls = results.compactMap(\.metrics.modelCallCount)
        let tokenUsage = results.compactMap(\.metrics.tokenUsage)
        let cloudCosts = results.compactMap(\.metrics.estimatedCloudCostUSD)
        let schemaToolCalls = results.compactMap(\.metrics.openRouterSchemaToolCallCount)
        let agentModelTurns = results.compactMap(\.metrics.openRouterAgentLogicalTurnCount)
        let agentHTTPAttempts = results.compactMap(\.metrics.openRouterAgentHTTPAttemptCount)
        let toolsModeRequested = options.backendMode.backends.contains(.cloud)
            && options.cloudAgentMode == .tools
        let toolBudgetFailures = results.filter { result in
            return result.status == .generationFailure
                && (
                    result.metrics.openRouterAgentSelectionReason == "tools"
                        || (
                            toolsModeRequested
                                && result.metrics.openRouterAgentSelectionReason == nil
                        )
                )
                && result.trace?.schemaToolCalls.contains {
                    $0.errorCode == .sessionBudgetExceeded
                        || $0.errorCode == .resultBudgetExceeded
                } == true
        }
        let promptEstimateValues = results.compactMap(\.metrics.estimatedInitialPromptCharacters)
        let backendAvailableValues = results.map(\.metrics.backendAvailable)
        let transportEvaluated = results.filter(transportAttempted)
        let structuredEvaluated = results.filter(\.metrics.transportSuccess)
        let decisionEvaluated = results.filter(\.metrics.structuredResponseParsed)
        let safetyValues = results.compactMap(\.metrics.safetyValid)
        let schemaValues = results.compactMap(\.metrics.schemaValid)
        let postgresVerificationStatuses = results.compactMap(\.metrics.postgresVerificationStatus)
        let postgresVerificationStatusCounts = postgresVerificationStatuses.reduce(
            into: [String: Int]()
        ) { counts, status in
            counts[status.rawValue, default: 0] += 1
        }
        let tableCoverageValues = results.compactMap(\.metrics.requiredTableCoverage)
        let columnCoverageValues = results.compactMap(\.metrics.requiredColumnBindingCoverage)
        let semanticResults = results.filter { $0.metrics.semanticStatus != nil }
        let semanticStatusCounts = semanticResults.reduce(into: [String: Int]()) { counts, result in
            guard let status = result.metrics.semanticStatus else { return }
            counts[status.rawValue, default: 0] += 1
        }
        let sqlSemanticEvaluated = semanticResults.filter {
            casesByID[$0.caseID]?.expected.decision == .sql
                && $0.metrics.semanticExecutionAttempted == true
        }
        let clarificationResults = results.filter {
            casesByID[$0.caseID]?.expected.decision == .clarify
        }
        let endToEndValues = semanticResults.compactMap(\.metrics.endToEndPassed)
        let semanticPassed = endToEndValues.filter { $0 }.count
        let semanticEnvironmentValues = semanticResults.compactMap(\.metrics.semanticEnvironmentAvailable)
        let semanticAttempted = semanticResults.compactMap(\.metrics.semanticExecutionAttempted)
        let semanticEquivalent = semanticResults.compactMap(\.metrics.resultEquivalent)
        let semanticGoldenSucceeded = semanticResults.compactMap(\.metrics.goldenExecutionSucceeded)
        let semanticCandidateSucceeded = semanticResults.compactMap(\.metrics.candidateExecutionSucceeded)
        let crossTab = staticSemanticCrossTab(results: semanticResults)

        return EvalRunSummary(
            totalResults: results.count,
            passed: passed,
            passRate: results.isEmpty ? 0 : Double(passed) / Double(results.count),
            statusCounts: statusCounts,
            semanticPassed: semanticResults.isEmpty ? nil : semanticPassed,
            semanticPassRate: semanticResults.isEmpty || endToEndValues.isEmpty
                ? nil
                : Double(semanticPassed) / Double(endToEndValues.count),
            semanticStatusCounts: semanticResults.isEmpty ? nil : semanticStatusCounts,
            sqlSemanticPass: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: sqlSemanticEvaluated.filter { $0.metrics.resultEquivalent == true }.count,
                    denominator: sqlSemanticEvaluated.count
                ),
            clarificationDecisionPass: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: clarificationResults.filter { $0.status == .passed }.count,
                    denominator: clarificationResults.count
                ),
            endToEndPass: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: endToEndValues.filter { $0 }.count,
                    denominator: endToEndValues.count
                ),
            endToEndPassRate: endToEndValues.isEmpty
                ? nil
                : Double(endToEndValues.filter { $0 }.count) / Double(endToEndValues.count),
            semanticEnvironmentAvailable: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: semanticEnvironmentValues.filter { $0 }.count,
                    denominator: semanticEnvironmentValues.count
                ),
            staticSemanticCrossTab: crossTab,
            semanticExecutionAttempted: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: semanticAttempted.filter { $0 }.count,
                    denominator: semanticAttempted.count
                ),
            resultEquivalent: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: semanticEquivalent.filter { $0 }.count,
                    denominator: semanticEquivalent.count
                ),
            goldenExecutionSucceeded: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: semanticGoldenSucceeded.filter { $0 }.count,
                    denominator: semanticGoldenSucceeded.count
                ),
            candidateExecutionSucceeded: semanticResults.isEmpty
                ? nil
                : EvalCountSummary(
                    count: semanticCandidateSucceeded.filter { $0 }.count,
                    denominator: semanticCandidateSucceeded.count
                ),
            backendAvailable: EvalCountSummary(
                count: backendAvailableValues.filter { $0 }.count,
                denominator: backendAvailableValues.count
            ),
            transportSuccess: EvalCountSummary(
                count: transportEvaluated.filter(\.metrics.transportSuccess).count,
                denominator: transportEvaluated.count
            ),
            structuredResponseParsed: EvalCountSummary(
                count: structuredEvaluated.filter(\.metrics.structuredResponseParsed).count,
                denominator: structuredEvaluated.count
            ),
            decisionMatches: EvalCountSummary(
                count: decisionEvaluated.filter(\.metrics.decisionMatches).count,
                denominator: decisionEvaluated.count
            ),
            safetyValid: EvalCountSummary(
                count: safetyValues.filter { $0 }.count,
                denominator: safetyValues.count
            ),
            schemaValid: EvalCountSummary(
                count: schemaValues.filter { $0 }.count,
                denominator: schemaValues.count
            ),
            postgresVerificationAttemptedPass: {
                let attempted = postgresVerificationStatuses.filter {
                    $0 == .passed || $0 == .failed
                }
                guard !attempted.isEmpty else { return nil }
                return EvalCountSummary(
                    count: attempted.filter { $0 == .passed }.count,
                    denominator: attempted.count
                )
            }(),
            postgresVerificationStatusCounts: postgresVerificationStatuses.isEmpty
                ? nil
                : postgresVerificationStatusCounts,
            forbiddenBindingViolationCount: results.reduce(0) {
                $0 + $1.metrics.forbiddenBindingViolations.count
            },
            requiredTableCoverage: EvalAverageSummary(
                average: average(tableCoverageValues),
                denominator: tableCoverageValues.count
            ),
            requiredColumnBindingCoverage: EvalAverageSummary(
                average: average(columnCoverageValues),
                denominator: columnCoverageValues.count
            ),
            latency: latencySummary(latencies),
            totalModelCalls: modelCalls.isEmpty ? nil : modelCalls.reduce(0, +),
            totalTokenUsage: tokenUsage.isEmpty ? nil : tokenUsage.reduce(0, +),
            estimatedCloudCostUSD: cloudCosts.isEmpty ? nil : cloudCosts.reduce(0, +),
            totalSchemaToolCalls: schemaToolCalls.isEmpty ? nil : schemaToolCalls.reduce(0, +),
            totalAgentModelTurns: agentModelTurns.isEmpty ? nil : agentModelTurns.reduce(0, +),
            totalAgentHTTPAttempts: agentHTTPAttempts.isEmpty ? nil : agentHTTPAttempts.reduce(0, +),
            toolBudgetFailureCount: schemaToolCalls.isEmpty ? nil : toolBudgetFailures.count,
            averageEstimatedInitialPromptCharacters: promptEstimateValues.isEmpty
                ? nil
                : Double(promptEstimateValues.reduce(0, +)) / Double(promptEstimateValues.count),
            maxEstimatedInitialPromptCharacters: promptEstimateValues.max()
        )
    }

    private func transportAttempted(_ result: TextToSQLEvalResult) -> Bool {
        guard result.metrics.backendAvailable else { return false }
        let isSemanticPreflightSkip = result.metrics.semanticStatus != nil
            && result.metrics.semanticExecutionAttempted == false
            && (result.status == .fixtureInvalid || result.status == .semanticEnvironmentUnavailable)
        return !isSemanticPreflightSkip
    }

    private func staticSemanticCrossTab(
        results: [TextToSQLEvalResult]
    ) -> EvalStaticSemanticCrossTab? {
        let evaluated = results.filter { result in
            guard result.metrics.semanticExecutionAttempted == true else { return false }
            return result.metrics.semanticStatus != .notApplicable
                && result.metrics.semanticStatus != .semanticEnvironmentUnavailable
                && result.metrics.semanticStatus != .fixtureInvalid
        }
        guard !evaluated.isEmpty else { return nil }
        return evaluated.reduce(
            into: EvalStaticSemanticCrossTab(
                staticPassSemanticPass: 0,
                staticPassSemanticFail: 0,
                staticFailSemanticPass: 0,
                staticFailSemanticFail: 0
            )
        ) { counts, result in
            let staticPass = result.status == .passed
            let semanticPass = result.metrics.semanticStatus == .passed
            switch (staticPass, semanticPass) {
            case (true, true):
                counts.staticPassSemanticPass += 1
            case (true, false):
                counts.staticPassSemanticFail += 1
            case (false, true):
                counts.staticFailSemanticPass += 1
            case (false, false):
                counts.staticFailSemanticFail += 1
            }
        }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func latencySummary(_ sortedLatencies: [Int]) -> LatencySummary {
        guard !sortedLatencies.isEmpty else {
            return LatencySummary(minMs: 0, averageMs: 0, p50Ms: 0, p95Ms: 0, maxMs: 0)
        }
        return LatencySummary(
            minMs: sortedLatencies.first ?? 0,
            averageMs: Double(sortedLatencies.reduce(0, +)) / Double(sortedLatencies.count),
            p50Ms: percentile(sortedLatencies, percentile: 0.5),
            p95Ms: percentile(sortedLatencies, percentile: 0.95),
            maxMs: sortedLatencies.last ?? 0
        )
    }

    private func percentile(_ sorted: [Int], percentile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * percentile).rounded()))
        )
        return sorted[index]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func setupFixtureHashes(
        fixtures: Set<String>,
        databaseDirectory: URL
    ) -> [String: String] {
        fixtures.reduce(into: [:]) { result, fixture in
            let url = databaseDirectory
                .appendingPathComponent(fixture, isDirectory: true)
                .appendingPathComponent("setup.json")
            guard let data = try? Data(contentsOf: url) else {
                result[fixture] = "missing"
                return
            }
            result[fixture] = sha256(data)
        }
    }

    private static func negativeControlMetadataHash(cases: [TextToSQLEvalCase]) -> String {
        let lines = cases
            .sorted { $0.id < $1.id }
            .flatMap { evalCase -> [String] in
                (evalCase.expected.semantic?.negativeControls ?? [])
                    .sorted { $0.id < $1.id }
                    .map { control in
                        [
                            evalCase.id,
                            control.id,
                            control.comparisonMode?.rawValue ?? "",
                            control.sql,
                        ].joined(separator: "\u{1F}")
                    }
            }
            .joined(separator: "\n")
        return sha256(Data(lines.utf8))
    }

    private static func sourceHash(relativePaths: [String], relativeTo directory: URL) -> String {
        var data = Data()
        for path in relativePaths.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            let url = directory.appendingPathComponent(path)
            guard let fileData = try? Data(contentsOf: url) else {
                return "unknown"
            }
            data.append(fileData)
            data.append(0)
        }
        return sha256(data)
    }

    private static func openRouterAPIKey() -> String? {
        let value = ProcessInfo.processInfo.environment["WIDEN_EVAL_OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func commitSHA() -> String {
        runProcess("/usr/bin/git", arguments: ["rev-parse", "HEAD"]) ?? "unknown"
    }

    private static func architecture() -> String {
        runProcess("/usr/bin/uname", arguments: ["-m"]) ?? "unknown"
    }

    private static func runProcess(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

enum EvalRunnerError: LocalizedError {
    case missingCase(String)
    case missingSchemaFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingCase(let id):
            "No eval case found with id \(id)."
        case .missingSchemaFixture(let fixture):
            "No schema fixture loaded for \(fixture)."
        }
    }
}

private extension TextToSQLEvalResult {
    func withSemantic(
        output: TextToSQLSemanticExecutionOutput,
        comparisonMode: TextToSQLResultComparisonMode
    ) -> TextToSQLEvalResult {
        if output.resultLimitExceeded {
            return withSemantic(
                status: .resultLimitExceeded,
                attempted: true,
                endToEndPassed: false,
                goldenSucceeded: output.goldenExecutionSucceeded,
                candidateSucceeded: output.candidateExecutionSucceeded,
                equivalent: false,
                goldenRowCount: output.goldenResult?.rows.count,
                comparisonMode: comparisonMode,
                executionLatencyMs: output.latencyMs,
                goldenDigest: output.goldenResult.map {
                    TextToSQLSemanticComparator.digest(for: $0, mode: comparisonMode)
                },
                message: output.goldenError ?? output.candidateError
            )
        }
        if let goldenError = output.goldenError {
            return withSemantic(
                status: .goldenFixtureFailure,
                attempted: true,
                endToEndPassed: false,
                goldenSucceeded: false,
                candidateSucceeded: false,
                equivalent: false,
                comparisonMode: comparisonMode,
                executionLatencyMs: output.latencyMs,
                message: goldenError
            )
        }
        if let candidateError = output.candidateError {
            return withSemantic(
                status: .candidateExecutionFailure,
                attempted: true,
                endToEndPassed: false,
                goldenSucceeded: true,
                candidateSucceeded: false,
                equivalent: false,
                goldenRowCount: output.goldenResult?.rows.count,
                comparisonMode: comparisonMode,
                executionLatencyMs: output.latencyMs,
                goldenDigest: output.goldenResult.map {
                    TextToSQLSemanticComparator.digest(for: $0, mode: comparisonMode)
                },
                message: candidateError
            )
        }
        let comparison = output.comparison
        return withSemantic(
            status: comparison?.equivalent == true ? .passed : .resultMismatch,
            attempted: true,
            endToEndPassed: self.status == .passed && comparison?.equivalent == true,
            goldenSucceeded: true,
            candidateSucceeded: true,
            equivalent: comparison?.equivalent ?? false,
            goldenRowCount: comparison?.goldenRowCount,
            candidateRowCount: comparison?.candidateRowCount,
            comparisonMode: comparisonMode,
            executionLatencyMs: output.latencyMs,
            goldenDigest: comparison?.goldenDigest,
            candidateDigest: comparison?.candidateDigest,
            mismatchCategory: comparison?.mismatchCategory
        )
    }

    func withSemantic(
        status: TextToSQLSemanticStatus,
        attempted: Bool,
        endToEndPassed: Bool,
        goldenSucceeded: Bool? = nil,
        candidateSucceeded: Bool? = nil,
        equivalent: Bool? = nil,
        goldenRowCount: Int? = nil,
        candidateRowCount: Int? = nil,
        comparisonMode: TextToSQLResultComparisonMode?,
        executionLatencyMs: Int? = nil,
        goldenDigest: String? = nil,
        candidateDigest: String? = nil,
        mismatchCategory: String? = nil,
        message: String? = nil
    ) -> TextToSQLEvalResult {
        var copy = self
        copy.metrics.semanticExecutionAttempted = attempted
        copy.metrics.semanticEnvironmentAvailable = semanticEnvironmentAvailable(
            status: status,
            attempted: attempted
        )
        copy.metrics.goldenExecutionSucceeded = goldenSucceeded
        copy.metrics.candidateExecutionSucceeded = candidateSucceeded
        copy.metrics.resultEquivalent = equivalent
        copy.metrics.endToEndPassed = endToEndPassed
        copy.metrics.semanticStatus = status
        copy.metrics.goldenRowCount = goldenRowCount
        copy.metrics.candidateRowCount = candidateRowCount
        copy.metrics.comparisonMode = comparisonMode
        copy.metrics.executionLatencyMs = executionLatencyMs
        copy.metrics.goldenResultDigest = goldenDigest
        copy.metrics.candidateResultDigest = candidateDigest
        copy.metrics.semanticMismatchCategory = mismatchCategory
        if let message {
            let existing = copy.diagnostics.errorMessage
            copy.diagnostics.errorMessage = [existing, message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .nilIfBlank
        }
        return copy
    }

    private func semanticEnvironmentAvailable(
        status: TextToSQLSemanticStatus,
        attempted: Bool
    ) -> Bool? {
        if status == .notApplicable && !attempted { return nil }
        return status != .semanticEnvironmentUnavailable
    }
}

private struct EvalCloudSchemaToolSQLGenerator: SQLGenerator, Sendable {
    var apiKey: String
    var model: String

    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        let selectedSchemas = selectedSchemaSet(from: schema)
        let schemaFingerprint = try SchemaSearchIndexStore.schemaFingerprint(for: schema)
        let connectionID = deterministicConnectionID(
            for: "\(schemaFingerprint)|\(selectedSchemas.joined(separator: ","))"
        )
        let agent = OpenRouterSchemaToolSQLAgent(
            apiKey: apiKey,
            model: model,
            connectionID: connectionID,
            selectedSchemas: selectedSchemas
        )
        return try await agent.generateSQL(
            question: question,
            schema: schema,
            context: context,
            config: config
        )
    }

    private func selectedSchemaSet(from schema: DatabaseSchema) -> [String] {
        let names = Set(schema.schemas.map(\.name) + schema.tables.map(\.schema))
        return names.sorted()
    }

    private func deterministicConnectionID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        let bytes = Array(digest.prefix(16))
        let uuidString = String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
