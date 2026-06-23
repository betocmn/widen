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
}

struct EvalCountSummary: Codable {
    var count: Int
    var denominator: Int
}

struct EvalAverageSummary: Codable {
    var average: Double?
    var denominator: Int
}

struct EvalRunSummary: Codable {
    var totalResults: Int
    var passed: Int
    var passRate: Double
    var statusCounts: [String: Int]
    var semanticPassed: Int?
    var semanticPassRate: Double?
    var semanticStatusCounts: [String: Int]?
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
    var forbiddenBindingViolationCount: Int
    var requiredTableCoverage: EvalAverageSummary
    var requiredColumnBindingCoverage: EvalAverageSummary
    var latency: LatencySummary
    var totalModelCalls: Int?
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
    var options: EvalCLIOptions

    func run() async throws -> EvalRun {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let suiteURL = URL(fileURLWithPath: options.suitePath).standardizedFileURL
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(TextToSQLEvalSuite.self, from: suiteData)
        try TextToSQLEvalSuiteValidator.validate(suite: suite, suiteURL: suiteURL)
        let selectedCases = try filteredCases(suite.cases)
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
        var results: [TextToSQLEvalResult] = []
        var semanticPreparation: SemanticPreparation?
        if options.semanticDatabase {
            let databaseDirectory = evalDirectory.appendingPathComponent("databases", isDirectory: true)
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
                        if let semanticPreparation,
                            let semanticSkip = semanticPreparation.skipResult(
                                for: evalCase,
                                backend: backend,
                                model: backend == .cloud ? options.model : nil,
                                repeatIndex: repeatIndex
                            )
                        {
                            results.append(semanticSkip)
                        } else if let unavailable {
                            results.append(
                                backendUnavailableResult(
                                    evalCase: evalCase,
                                    backend: backend,
                                    message: unavailable,
                                    repeatIndex: repeatIndex
                                )
                            )
                        } else if let generator {
                            let prompt = promptText(for: backend, evalCase: evalCase, schema: schema)
                            let runOptions = TextToSQLEvalRunOptions(
                                backend: backend,
                                model: backend == .cloud ? options.model : nil,
                                repeatIndex: repeatIndex,
                                estimatedInitialPromptCharacters: prompt.count,
                                estimatedInitialPrompt: options.recordPrompts ? prompt : nil,
                                caseTimeoutSeconds: options.caseTimeoutSeconds
                            )
                            print("Running \(evalCase.id) [\(backend.rawValue)] repeat \(repeatIndex)")
                            let staticResult = await TextToSQLEvalCaseRunner.run(
                                evalCase: evalCase,
                                schema: schema,
                                generator: generator,
                                options: runOptions
                            )
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
        let summary = summarize(results)
        let backendSummaries = Dictionary(
            uniqueKeysWithValues: options.backendMode.backends.map { backend in
                (backend, summarize(results.filter { $0.backend == backend }))
            }
        )
        let manifest = EvalRunManifest(
            suiteName: suite.name,
            suiteVersion: suite.version,
            suitePath: suiteURL.path,
            evaluationMode: options.semanticDatabase
                ? "production-pipeline-static-shape-plus-seeded-postgres-semantic"
                : "production-pipeline-static-shape",
            commitSHA: Self.commitSHA(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            backendMode: options.backendMode.rawValue,
            model: options.backendMode == .local ? nil : options.model,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture(),
            caseCount: selectedCases.count,
            repeatCount: options.repeatCount,
            caseTimeoutSeconds: options.caseTimeoutSeconds,
            suiteFileHash: Self.sha256(suiteData),
            scorerVersion: "production-pipeline-static-shape-v1",
            scorerSourceHash: Self.sourceHash(
                relativePaths: [
                    "WidenKit/Evals/TextToSQLEvalCase.swift",
                    "WidenKit/Evals/TextToSQLEvalScorer.swift",
                    "WidenKit/Evals/TextToSQLEvalResult.swift",
                    "WidenKit/Evals/TextToSQLSemanticComparator.swift",
                    "WidenKit/Evals/TextToSQLSemanticDatabase.swift",
                    "WidenEval/EvalRunner.swift",
                    "WidenKit/Services/TextToSQLPipeline.swift",
                    "WidenKit/Services/SQLGenerationFailure.swift",
                    "WidenKit/Services/GeneratedSQLRepairSupport.swift",
                ],
                relativeTo: repositoryRoot
            ),
            schemaFixtureHashes: schemas.mapValues(\.sha256)
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
        private let fixtureIssues: [String: SemanticFixtureIssue]
        private let globalIssue: SemanticFixtureIssue?

        init(
            provisioner: TextToSQLSemanticDatabaseProvisioner,
            server: TextToSQLSemanticDatabaseServer,
            executor: TextToSQLSemanticExecutor,
            databases: [String: TextToSQLSemanticProvisionedDatabase],
            fixtureIssues: [String: SemanticFixtureIssue],
            globalIssue: SemanticFixtureIssue?
        ) {
            self.provisioner = provisioner
            self.server = server
            self.executor = executor
            self.databases = databases
            self.fixtureIssues = fixtureIssues
            self.globalIssue = globalIssue
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
            let issue = globalIssue ?? fixtureIssues[evalCase.schemaFixture]
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
                    goldenExecutionSucceeded: false,
                    candidateExecutionSucceeded: false,
                    resultEquivalent: false,
                    semanticStatus: issue.semanticStatus
                ),
                diagnostics: TextToSQLEvalDiagnostics(errorMessage: issue.message)
            )
        }

        func annotate(
            _ result: TextToSQLEvalResult,
            evalCase: TextToSQLEvalCase
        ) async -> TextToSQLEvalResult {
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
                let database = databases[evalCase.schemaFixture]
            else {
                return result.withSemantic(
                    status: .notApplicable,
                    attempted: false,
                    comparisonMode: evalCase.expected.semantic?.comparisonMode
                )
            }

            do {
                let output = try await executor.executePair(
                    goldenSQL: goldenSQL,
                    candidateSQL: candidateSQL,
                    expectation: semantic,
                    config: database.config,
                    password: server.password
                )
                return result.withSemantic(output: output, comparisonMode: semantic.comparisonMode)
            } catch {
                return result.withSemantic(
                    status: .semanticEnvironmentUnavailable,
                    attempted: false,
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
        var fixtureIssues: [String: SemanticFixtureIssue] = [:]
        let casesByFixture = Dictionary(grouping: cases, by: \.schemaFixture)

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
                try await validateSemanticFixture(
                    fixture: fixture,
                    cases: casesByFixture[fixture] ?? [],
                    database: database,
                    server: server,
                    executor: executor
                )
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
                        fixtureIssues: fixtureIssues,
                        globalIssue: globalIssue
                    )
                case .fixtureInvalid(let message), .setupInvalid(let message):
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
            fixtureIssues: fixtureIssues,
            globalIssue: nil
        )
    }

    private func validateSemanticFixture(
        fixture: String,
        cases: [TextToSQLEvalCase],
        database: TextToSQLSemanticProvisionedDatabase,
        server: TextToSQLSemanticDatabaseServer,
        executor: TextToSQLSemanticExecutor
    ) async throws {
        for evalCase in cases where evalCase.expected.decision == .sql {
            guard let goldenSQL = evalCase.expected.goldenSQL,
                let semantic = evalCase.expected.semantic
            else {
                throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                    "Fixture \(fixture) case \(evalCase.id) is missing semantic SQL metadata."
                )
            }

            let goldenOutput = try await executor.executePair(
                goldenSQL: goldenSQL,
                candidateSQL: goldenSQL,
                expectation: semantic,
                config: database.config,
                password: server.password
            )
            guard goldenOutput.goldenExecutionSucceeded,
                goldenOutput.candidateExecutionSucceeded,
                goldenOutput.comparison?.equivalent == true
            else {
                throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                    "Fixture \(fixture) case \(evalCase.id) golden SQL failed semantic preflight."
                )
            }

            for negative in semantic.negativeControls {
                var negativeExpectation = semantic
                if let mode = negative.comparisonMode {
                    negativeExpectation.comparisonMode = mode
                }
                let output = try await executor.executePair(
                    goldenSQL: goldenSQL,
                    candidateSQL: negative.sql,
                    expectation: negativeExpectation,
                    config: database.config,
                    password: server.password
                )
                guard output.goldenExecutionSucceeded,
                    output.candidateExecutionSucceeded,
                    output.comparison?.equivalent == false
                else {
                    throw TextToSQLSemanticDatabaseError.fixtureInvalid(
                        "Fixture \(fixture) case \(evalCase.id) negative control \(negative.id) did not fail result equivalence."
                    )
                }
            }
        }
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
                latencyMs: 0
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: message)
        )
    }

    private func summarize(_ results: [TextToSQLEvalResult]) -> EvalRunSummary {
        let statusCounts = results.reduce(into: [String: Int]()) { counts, result in
            counts[result.status.rawValue, default: 0] += 1
        }
        let passed = statusCounts[TextToSQLEvalCaseStatus.passed.rawValue, default: 0]
        let latencies = results.map(\.metrics.latencyMs).sorted()
        let modelCalls = results.compactMap(\.metrics.modelCallCount)
        let promptEstimateValues = results.compactMap(\.metrics.estimatedInitialPromptCharacters)
        let backendAvailableValues = results.map(\.metrics.backendAvailable)
        let transportEvaluated = results.filter(\.metrics.backendAvailable)
        let structuredEvaluated = results.filter(\.metrics.transportSuccess)
        let decisionEvaluated = results.filter(\.metrics.structuredResponseParsed)
        let safetyValues = results.compactMap(\.metrics.safetyValid)
        let schemaValues = results.compactMap(\.metrics.schemaValid)
        let tableCoverageValues = results.compactMap(\.metrics.requiredTableCoverage)
        let columnCoverageValues = results.compactMap(\.metrics.requiredColumnBindingCoverage)
        let semanticResults = results.filter { $0.metrics.semanticStatus != nil }
        let semanticStatusCounts = semanticResults.reduce(into: [String: Int]()) { counts, result in
            guard let status = result.metrics.semanticStatus else { return }
            counts[status.rawValue, default: 0] += 1
        }
        let semanticPassed = semanticResults.filter(semanticPasses).count
        let semanticAttempted = semanticResults.compactMap(\.metrics.semanticExecutionAttempted)
        let semanticEquivalent = semanticResults.compactMap(\.metrics.resultEquivalent)
        let semanticGoldenSucceeded = semanticResults.compactMap(\.metrics.goldenExecutionSucceeded)
        let semanticCandidateSucceeded = semanticResults.compactMap(\.metrics.candidateExecutionSucceeded)

        return EvalRunSummary(
            totalResults: results.count,
            passed: passed,
            passRate: results.isEmpty ? 0 : Double(passed) / Double(results.count),
            statusCounts: statusCounts,
            semanticPassed: semanticResults.isEmpty ? nil : semanticPassed,
            semanticPassRate: semanticResults.isEmpty
                ? nil
                : Double(semanticPassed) / Double(semanticResults.count),
            semanticStatusCounts: semanticResults.isEmpty ? nil : semanticStatusCounts,
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
            averageEstimatedInitialPromptCharacters: promptEstimateValues.isEmpty
                ? nil
                : Double(promptEstimateValues.reduce(0, +)) / Double(promptEstimateValues.count),
            maxEstimatedInitialPromptCharacters: promptEstimateValues.max()
        )
    }

    private func semanticPasses(_ result: TextToSQLEvalResult) -> Bool {
        switch result.metrics.semanticStatus {
        case .passed:
            true
        case .notApplicable:
            result.status == .passed
        default:
            false
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
        if let goldenError = output.goldenError {
            return withSemantic(
                status: .goldenFixtureFailure,
                attempted: true,
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
        copy.metrics.goldenExecutionSucceeded = goldenSucceeded
        copy.metrics.candidateExecutionSucceeded = candidateSucceeded
        copy.metrics.resultEquivalent = equivalent
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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
