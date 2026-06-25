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

            await GenerationLog.shared.setEnabled(options.recordPrompts)

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

struct EvalCLIOptions {
    var backendMode: EvalBackendMode = .local
    var model: String = "openai/gpt-5.5"
    var suitePath: String = "Evals/suites/text-to-sql-v1.json"
    var caseID: String?
    var repeatCount: Int = 1
    var caseTimeoutSeconds: Double = 120
    var outputDirectory: String = ".eval-results"
    var recordPrompts = false
    var failUnder: Double?
    var semanticDatabase = false
    var retrieverMode: SchemaRetrievalMode?
    var schemaTools = false
    var showHelp = false

    static let helpText = """
        WidenEval

        Options:
          --backend local|cloud|both
          --model <openrouter-model-id>
          --suite <path>
          --case <case-id>
          --repeat <n>
          --case-timeout-seconds <n>
          --output <directory>
          --record-prompts
          --fail-under <percentage>
          --semantic-db
          --retriever legacy|index|both
          --schema-tools
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
            case "--model":
                options.model = try nextValue(after: argument)
            case "--suite":
                options.suitePath = try nextValue(after: argument)
            case "--case":
                options.caseID = try nextValue(after: argument)
            case "--repeat":
                let value = try nextValue(after: argument)
                guard let repeatCount = Int(value), repeatCount > 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.repeatCount = repeatCount
            case "--case-timeout-seconds":
                let value = try nextValue(after: argument)
                guard let timeout = Double(value), timeout.isFinite, timeout > 0 else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.caseTimeoutSeconds = timeout
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
            case "--semantic-db":
                options.semanticDatabase = true
            case "--retriever":
                let value = try nextValue(after: argument)
                guard let retriever = SchemaRetrievalMode(rawValue: value) else {
                    throw EvalCLIError.invalidValue(argument, value)
                }
                options.retrieverMode = retriever
            case "--schema-tools":
                options.schemaTools = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw EvalCLIError.unknownArgument(argument)
            }
        }

        return options
    }
}

enum EvalCLIError: LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            "Missing value for \(flag)."
        case .invalidValue(let flag, let value):
            "Invalid value for \(flag): \(value)."
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)."
        }
    }
}
