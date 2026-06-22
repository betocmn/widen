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
}

struct EvalRunManifest: Codable {
    var suiteName: String
    var suiteVersion: String
    var suitePath: String
    var commitSHA: String
    var startedAt: String
    var finishedAt: String
    var backendMode: String
    var model: String?
    var osVersion: String
    var architecture: String
    var caseCount: Int
    var repeatCount: Int
    var schemaFixtureHashes: [String: String]
}

struct EvalRunSummary: Codable {
    var totalResults: Int
    var passed: Int
    var passRate: Double
    var statusCounts: [String: Int]
    var backendAvailable: Int
    var transportSuccess: Int
    var structuredResponseParsed: Int
    var decisionMatches: Int
    var safetyValid: Int
    var schemaValid: Int
    var forbiddenBindingViolationCount: Int
    var averageRequiredTableCoverage: Double
    var averageRequiredColumnBindingCoverage: Double
    var latency: LatencySummary
    var totalModelCalls: Int?
    var averagePromptSize: Double?
    var maxPromptSize: Int?
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
        let suiteURL = URL(fileURLWithPath: options.suitePath)
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(TextToSQLEvalSuite.self, from: suiteData)
        let selectedCases = try filteredCases(suite.cases)
        let schemaDirectory = suiteURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("schemas", isDirectory: true)
        let schemas = try loadSchemas(
            for: Set(selectedCases.map(\.schemaFixture)),
            schemaDirectory: schemaDirectory
        )
        var results: [TextToSQLEvalResult] = []

        for backend in options.backendMode.backends {
            let unavailable = backendUnavailableReason(for: backend)
            let generator = unavailable == nil ? makeGenerator(for: backend) : nil
            for evalCase in selectedCases {
                guard let schema = schemas[evalCase.schemaFixture]?.schema else {
                    throw EvalRunnerError.missingSchemaFixture(evalCase.schemaFixture)
                }
                for repeatIndex in 1...options.repeatCount {
                    let prompt = promptText(for: backend, evalCase: evalCase, schema: schema)
                    let runOptions = TextToSQLEvalRunOptions(
                        backend: backend,
                        model: backend == .cloud ? options.model : nil,
                        repeatIndex: repeatIndex,
                        promptSize: prompt.count,
                        recordedPrompt: options.recordPrompts ? prompt : nil
                    )
                    if let unavailable {
                        results.append(
                            backendUnavailableResult(
                                evalCase: evalCase,
                                backend: backend,
                                message: unavailable,
                                options: runOptions
                            )
                        )
                    } else if let generator {
                        print("Running \(evalCase.id) [\(backend.rawValue)] repeat \(repeatIndex)")
                        let result = await TextToSQLEvalCaseRunner.run(
                            evalCase: evalCase,
                            schema: schema,
                            generator: generator,
                            options: runOptions
                        )
                        results.append(result)
                    }
                }
            }
        }

        let finishedAt = ISO8601DateFormatter().string(from: Date())
        let summary = summarize(results)
        let manifest = EvalRunManifest(
            suiteName: suite.name,
            suiteVersion: suite.version,
            suitePath: suiteURL.path,
            commitSHA: Self.commitSHA(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            backendMode: options.backendMode.rawValue,
            model: options.backendMode == .local ? nil : options.model,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture(),
            caseCount: selectedCases.count,
            repeatCount: options.repeatCount,
            schemaFixtureHashes: schemas.mapValues(\.sha256)
        )
        return EvalRun(manifest: manifest, results: results, summary: summary)
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
        options: TextToSQLEvalRunOptions
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: .backendUnavailable,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: false,
                transportSuccess: false,
                structuredResponseParsed: false,
                decisionMatches: false,
                latencyMs: 0,
                promptSize: options.promptSize
            ),
            diagnostics: TextToSQLEvalDiagnostics(errorMessage: message),
            recordedPrompt: options.recordedPrompt
        )
    }

    private func summarize(_ results: [TextToSQLEvalResult]) -> EvalRunSummary {
        let statusCounts = results.reduce(into: [String: Int]()) { counts, result in
            counts[result.status.rawValue, default: 0] += 1
        }
        let passed = statusCounts[TextToSQLEvalCaseStatus.passed.rawValue, default: 0]
        let latencies = results.map(\.metrics.latencyMs).sorted()
        let modelCalls = results.compactMap(\.metrics.modelCallCount)
        let promptSizes = results.compactMap(\.metrics.promptSize)

        return EvalRunSummary(
            totalResults: results.count,
            passed: passed,
            passRate: results.isEmpty ? 0 : Double(passed) / Double(results.count),
            statusCounts: statusCounts,
            backendAvailable: results.filter(\.metrics.backendAvailable).count,
            transportSuccess: results.filter(\.metrics.transportSuccess).count,
            structuredResponseParsed: results.filter(\.metrics.structuredResponseParsed).count,
            decisionMatches: results.filter(\.metrics.decisionMatches).count,
            safetyValid: results.filter { $0.metrics.safetyValid == true }.count,
            schemaValid: results.filter { $0.metrics.schemaValid == true }.count,
            forbiddenBindingViolationCount: results.reduce(0) {
                $0 + $1.metrics.forbiddenBindingViolations.count
            },
            averageRequiredTableCoverage: average(
                results.map(\.metrics.requiredTableCoverage)
            ),
            averageRequiredColumnBindingCoverage: average(
                results.map(\.metrics.requiredColumnBindingCoverage)
            ),
            latency: latencySummary(latencies),
            totalModelCalls: modelCalls.isEmpty ? nil : modelCalls.reduce(0, +),
            averagePromptSize: promptSizes.isEmpty
                ? nil
                : Double(promptSizes.reduce(0, +)) / Double(promptSizes.count),
            maxPromptSize: promptSizes.max()
        )
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
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
