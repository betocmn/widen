import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

import WidenKit

@main
enum WidenEvalMain {
    static func main() async {
        do {
            let options = try EvalCLIOptions.parse(CommandLine.arguments.dropFirst())
            if options.showHelp {
                print(EvalCLIOptions.helpText)
                return
            }

            if options.checkOpenRouterCanonical {
                let observation = try await OpenRouterProductionCanonicalWatch.check()
                print("canonical_watch_status=\(observation.hasDrift ? "drift" : "current")")
                print("requested_model=\(observation.requestedModelID)")
                print("expected_canonical_model=\(observation.expectedCanonicalModelID)")
                print("observed_canonical_model=\(observation.observedCanonicalModelID)")
                if observation.hasDrift {
                    exit(2)
                }
                return
            }

            await GenerationLog.shared.setEnabled(options.recordPrompts)

            if let releaseTriageInputPath = options.releaseTriageInputPath {
                let triageOutput = try TextToSQLReleaseTriageReporter.writeExisting(
                    runJSONPath: releaseTriageInputPath,
                    copyVersion: options.releaseTriageVersion,
                    allowModelOverride: options.allowModelOverride
                )
                print("Release gate triage: \(triageOutput.triage.path)")
                if let copied = triageOutput.copiedSummary {
                    print("Copied sanitized triage summary: \(copied.path)")
                } else if options.releaseTriageVersion != nil,
                    let reason = triageOutput.committedDocIneligibility
                {
                    print(
                        "Skipped committed triage copy: \(reason.description)."
                    )
                }
                return
            }

            if options.inspectionTools {
                let runner = DatabaseInspectionEvalRunner(options: options)
                let run = try await runner.run()
                let output = try DatabaseInspectionEvalReporter.write(run: run, options: options)

                print("Wrote database inspection eval results to \(output.directory.path)")
                print("Summary: \(output.summary.path)")
                if !run.acceptance.passed {
                    fputs(
                        "Database inspection acceptance failed: \(run.acceptance.messages.joined(separator: "; "))\n",
                        stderr
                    )
                    exit(1)
                }
                return
            }

            if options.schemaTools {
                let runner = SchemaToolContractEvalRunner(options: options)
                let run = try await runner.run()
                let output = try SchemaToolContractEvalReporter.write(run: run, options: options)

                print("Wrote schema tool eval results to \(output.directory.path)")
                print("Summary: \(output.summary.path)")
                if !run.acceptance.passed {
                    fputs(
                        "Schema tool acceptance failed: \(run.acceptance.messages.joined(separator: "; "))\n",
                        stderr
                    )
                    exit(1)
                }
                return
            }

            if options.retrieverMode != nil {
                let runner = SchemaRetrievalEvalRunner(options: options)
                let run = try await runner.run()
                let output = try SchemaRetrievalEvalReporter.write(run: run, options: options)

                print("Wrote retrieval eval results to \(output.directory.path)")
                print("Summary: \(output.summary.path)")
                if !run.acceptance.passed {
                    fputs(
                        "Schema retrieval acceptance failed: \(run.acceptance.messages.joined(separator: "; "))\n",
                        stderr
                    )
                    exit(1)
                }
                return
            }

            let runner = EvalRunner(options: options)
            let run = try await runner.run()
            let output = try EvalReporter.write(run: run, options: options)

            print("Wrote eval results to \(output.directory.path)")
            print("Summary: \(output.summary.path)")

            var wroteReleaseTriage = false
            if let releaseGateVersion = options.releaseGateVersion {
                let gateOutput = try TextToSQLReleaseGateReporter.write(
                    run: run,
                    evalOutput: output,
                    version: releaseGateVersion
                )
                print("Release gate summary: \(gateOutput.summary.path)")
                if let reason = gateOutput.committedDocIneligibility {
                    print(
                        "Committed release-gate doc skipped: \(reason.description)."
                    )
                }
                if options.writeReleaseTriage {
                    let triageOutput = try TextToSQLReleaseTriageReporter.write(
                        run: run,
                        evalOutput: output,
                        copyVersion: options.releaseTriageVersion
                    )
                    wroteReleaseTriage = true
                    print("Release gate triage: \(triageOutput.triage.path)")
                    if let copied = triageOutput.copiedSummary {
                        print("Copied sanitized triage summary: \(copied.path)")
                    } else if options.releaseTriageVersion != nil,
                        let reason = triageOutput.committedDocIneligibility
                    {
                        print("Skipped committed triage copy: \(reason.description).")
                    }
                }
                if !gateOutput.evaluation.passed {
                    fputs(
                        "Text-to-SQL release gate failed: \(gateOutput.evaluation.failureMessages.joined(separator: "; "))\n",
                        stderr
                    )
                    exit(1)
                }
            }
            if options.writeReleaseTriage, !wroteReleaseTriage {
                let triageOutput = try TextToSQLReleaseTriageReporter.write(
                    run: run,
                    evalOutput: output,
                    copyVersion: options.releaseTriageVersion
                )
                print("Release gate triage: \(triageOutput.triage.path)")
                if let copied = triageOutput.copiedSummary {
                    print("Copied sanitized triage summary: \(copied.path)")
                } else if options.releaseTriageVersion != nil,
                    let reason = triageOutput.committedDocIneligibility
                {
                    print("Skipped committed triage copy: \(reason.description).")
                }
            }

            if let failUnder = options.failUnder {
                let threshold = failUnder / 100
                var failedBackends: [String] = []
                for backend in options.backendMode.backends {
                    guard let summary = run.backendSummaries[backend] else { continue }
                    let passRate = options.semanticDatabase
                        ? summary.endToEndPassRate ?? 0
                        : summary.passRate
                    if passRate < threshold {
                        let formatted = String(format: "%.1f", passRate * 100)
                        failedBackends.append("\(backend.rawValue): \(formatted)%")
                    }
                }
                if !failedBackends.isEmpty {
                    let label = options.semanticDatabase
                        ? "Semantic end-to-end pass rate"
                        : "Static-shape pass rate"
                    fputs(
                        "\(label) below fail-under \(failUnder)% for \(failedBackends.joined(separator: ", "))\n",
                        stderr
                    )
                    exit(1)
                }
            }
        } catch {
            fputs("WidenEval failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

enum EvalBackendMode: String {
    case local
    case cloud
    case both

    var backends: [TextToSQLEvalBackend] {
        switch self {
        case .local:
            [.local]
        case .cloud:
            [.cloud]
        case .both:
            [.local, .cloud]
        }
    }
}

enum EvalCloudAgentMode: String {
    case legacy
    case tools
}

enum EvalExplicitOption: Hashable {
    case backendMode
    case cloudAgentMode
    case schemaAgentClarificationCorrectionMode
    case schemaAgentIntentCoverageMode
    case schemaAgentPlanConsistencyMode
    case model
    case suitePath
    case repeatCount
    case caseTimeoutSeconds
    case releaseGateVersion
    case semanticDatabase
}

struct EvalCLIOptions {
    var backendMode: EvalBackendMode = .local
    var cloudAgentMode: EvalCloudAgentMode = .legacy
    var schemaAgentClarificationCorrectionMode: SchemaToolAgentClarificationCorrectionMode =
        .diagnosticsOnly
    var schemaAgentIntentCoverageMode: SchemaToolAgentIntentCoverageMode = .diagnosticsOnly
    var schemaAgentPlanConsistencyMode: SchemaToolAgentPlanConsistencyMode =
        .correctAndRetryExperimental
    var model: String = OpenRouterCatalog.productionProfile.requestedModelID
    var suitePath: String = "Evals/suites/text-to-sql-v1.json"
    var caseID: String?
    var caseIDs: [String] = []
    var repeatCount: Int = 1
    var caseTimeoutSeconds: Double = 120
    var outputDirectory: String = ".eval-results"
    var recordPrompts = false
    var failUnder: Double?
    var releaseGateVersion: String?
    var semanticDatabase = false
    var retrieverMode: SchemaRetrievalMode?
    var schemaTools = false
    var inspectionTools = false
    var releaseTriageInputPath: String?
    var writeReleaseTriage = false
    var allowModelOverride = false
    var releaseTriageVersion: String?
    var resumeRunPath: String?
    var resumeMissing = false
    var resumeFailed = false
    var resumeCaseStatuses: Set<TextToSQLEvalCaseStatus> = []
    var maxCloudCostUSD: Decimal?
    var maxHTTPAttempts: Int?
    var maxCompletedResults: Int?
    var stopBeforeProviderLimit = false
    var checkOpenRouterCanonical = false
    var explicitOptions: Set<EvalExplicitOption> = []
    var showHelp = false

    static let helpText = """
        WidenEval

        Options:
          --backend local|cloud|both
          --cloud-agent legacy|tools
          --schema-agent-clarification-correction disabled|diagnostics|experimental
          --schema-agent-intent-coverage disabled|diagnostics|reject-only|experimental
          --schema-agent-plan-consistency disabled|diagnostics|experimental
          --model <openrouter-model-id>
          --suite <path>
          --case <case-id>
          --repeat <n>
          --case-timeout-seconds <n>
          --output <directory>
          --record-prompts
          --fail-under <percentage>
          --release-gate-version <version>
          --triage-release <run.json path>
          --write-release-triage
          --release-triage-version <version>
          --allow-model-override
          --resume-run <path-to-run-directory-or-run.json>
          --resume-missing
          --resume-failed
          --resume-case-status <status[,status...]>
          --max-cloud-cost-usd <decimal>
          --max-http-attempts <int>
          --max-completed-results <int>
          --stop-before-provider-limit
          --semantic-db
          --retriever legacy|index|both
          --schema-tools
          --inspection-tools
          --check-openrouter-canonical
          --help
        """

    static func parse(_ arguments: ArraySlice<String>) throws -> EvalCLIOptions {
        var options = EvalCLIOptions()
        var iterator = Array(arguments).makeIterator()

        func nextValue(after flag: String) throws -> String {
            guard let value = iterator.next(), !value.hasPrefix("--") else {
                throw EvalCLIError.missingValue(flag)
            }
            return value
        }

        while let argument = iterator.next() {
            switch argument {
            case "--backend":
                let value = try nextValue(after: argument)
                guard let backend = EvalBackendMode(rawValue: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.backendMode = backend
                options.explicitOptions.insert(.backendMode)
            case "--cloud-agent":
                let value = try nextValue(after: argument)
                guard let mode = EvalCloudAgentMode(rawValue: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.cloudAgentMode = mode
                options.explicitOptions.insert(.cloudAgentMode)
            case "--schema-agent-clarification-correction":
                let value = try nextValue(after: argument)
                guard let mode = Self.clarificationCorrectionMode(from: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.schemaAgentClarificationCorrectionMode = mode
                options.explicitOptions.insert(.schemaAgentClarificationCorrectionMode)
            case "--schema-agent-intent-coverage":
                let value = try nextValue(after: argument)
                guard let mode = Self.intentCoverageMode(from: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.schemaAgentIntentCoverageMode = mode
                options.explicitOptions.insert(.schemaAgentIntentCoverageMode)
            case "--schema-agent-plan-consistency":
                let value = try nextValue(after: argument)
                guard let mode = Self.planConsistencyMode(from: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.schemaAgentPlanConsistencyMode = mode
                options.explicitOptions.insert(.schemaAgentPlanConsistencyMode)
            case "--model":
                options.model = try nextValue(after: argument)
                options.explicitOptions.insert(.model)
            case "--suite":
                options.suitePath = try nextValue(after: argument)
                options.explicitOptions.insert(.suitePath)
            case "--case":
                let value = try nextValue(after: argument)
                if options.caseID == nil {
                    options.caseID = value
                }
                options.caseIDs.append(value)
            case "--repeat":
                let value = try nextValue(after: argument)
                guard let repeatCount = Int(value), repeatCount > 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.repeatCount = repeatCount
                options.explicitOptions.insert(.repeatCount)
            case "--case-timeout-seconds":
                let value = try nextValue(after: argument)
                guard let timeout = Double(value), timeout.isFinite, timeout > 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.caseTimeoutSeconds = timeout
                options.explicitOptions.insert(.caseTimeoutSeconds)
            case "--output":
                options.outputDirectory = try nextValue(after: argument)
            case "--record-prompts":
                options.recordPrompts = true
            case "--fail-under":
                let value = try nextValue(after: argument)
                guard let failUnder = Double(value), failUnder >= 0, failUnder <= 100 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.failUnder = failUnder
            case "--release-gate-version":
                options.releaseGateVersion = try nextValue(after: argument)
                options.explicitOptions.insert(.releaseGateVersion)
            case "--triage-release":
                options.releaseTriageInputPath = try nextValue(after: argument)
            case "--write-release-triage":
                options.writeReleaseTriage = true
            case "--allow-model-override":
                options.allowModelOverride = true
            case "--release-triage-version":
                options.releaseTriageVersion = try nextValue(after: argument)
            case "--resume-run":
                options.resumeRunPath = try nextValue(after: argument)
            case "--resume-missing":
                options.resumeMissing = true
            case "--resume-failed":
                options.resumeFailed = true
            case "--resume-case-status":
                let value = try nextValue(after: argument)
                let statuses = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !statuses.isEmpty else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                for status in statuses {
                    guard let parsed = TextToSQLEvalCaseStatus(rawValue: status) else {
                        throw EvalCLIError.invalidValue(argument, status)
                    }
                    options.resumeCaseStatuses.insert(parsed)
                }
            case "--max-cloud-cost-usd":
                let value = try nextValue(after: argument)
                guard let budget = Decimal(string: value), budget >= 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.maxCloudCostUSD = budget
            case "--max-http-attempts":
                let value = try nextValue(after: argument)
                guard let attempts = Int(value), attempts >= 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.maxHTTPAttempts = attempts
            case "--max-completed-results":
                let value = try nextValue(after: argument)
                guard let results = Int(value), results >= 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.maxCompletedResults = results
            case "--stop-before-provider-limit":
                options.stopBeforeProviderLimit = true
            case "--semantic-db":
                options.semanticDatabase = true
                options.explicitOptions.insert(.semanticDatabase)
            case "--retriever":
                let value = try nextValue(after: argument)
                guard let retriever = SchemaRetrievalMode(rawValue: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.retrieverMode = retriever
            case "--schema-tools":
                options.schemaTools = true
            case "--inspection-tools":
                options.inspectionTools = true
            case "--check-openrouter-canonical":
                options.checkOpenRouterCanonical = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw EvalCLIError.unknownArgument(argument)
            }
        }

        if options.resumeRunPath == nil,
            options.resumeMissing || options.resumeFailed || !options.resumeCaseStatuses.isEmpty
        {
            throw EvalCLIError.resumeSelectionWithoutRun
        }
        if options.releaseTriageVersion != nil,
            options.releaseTriageInputPath == nil,
            !options.writeReleaseTriage
        {
            throw EvalCLIError.releaseTriageVersionWithoutOutput
        }
        return options
    }

    private static func clarificationCorrectionMode(
        from value: String
    ) -> SchemaToolAgentClarificationCorrectionMode? {
        switch value {
        case "disabled":
            return .disabled
        case "diagnostics", "diagnostics-only", "diagnosticsOnly":
            return .diagnosticsOnly
        case "experimental", "correct-over-clarification-experimental",
            "correctOverClarificationExperimental":
            return .correctOverClarificationExperimental
        default:
            return nil
        }
    }

    private static func planConsistencyMode(
        from value: String
    ) -> SchemaToolAgentPlanConsistencyMode? {
        switch value {
        case "disabled":
            return .disabled
        case "diagnostics", "diagnostics-only", "diagnosticsOnly":
            return .diagnosticsOnly
        case "experimental", "correct-and-retry-experimental",
            "correctAndRetryExperimental":
            return .correctAndRetryExperimental
        default:
            return nil
        }
    }

    private static func intentCoverageMode(
        from value: String
    ) -> SchemaToolAgentIntentCoverageMode? {
        switch value {
        case "disabled":
            return .disabled
        case "diagnostics", "diagnostics-only", "diagnosticsOnly":
            return .diagnosticsOnly
        case "reject-only", "rejectOnlyExperimental", "reject-only-experimental":
            return .rejectOnlyExperimental
        case "experimental", "correct-and-retry-experimental",
            "correctAndRetryExperimental":
            return .correctAndRetryExperimental
        default:
            return nil
        }
    }
}

enum EvalCLIError: LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case resumeSelectionWithoutRun
    case releaseTriageVersionWithoutOutput

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            "Missing value for \(flag)."
        case .invalidValue(let flag, let value):
            "Invalid value for \(flag): \(value)."
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)."
        case .resumeSelectionWithoutRun:
            "Resume selection flags require --resume-run."
        case .releaseTriageVersionWithoutOutput:
            "--release-triage-version requires --write-release-triage or --triage-release."
        }
    }
}
