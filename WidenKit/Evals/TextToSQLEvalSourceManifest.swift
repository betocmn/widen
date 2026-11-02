import CryptoKit
import Foundation

/// Repository-relative source files whose contents are hashed into an eval run
/// manifest, so a resumed run is rejected when scoring or generation code changed.
/// Renaming or deleting a listed file must update this list in the same change;
/// hashing fails instead of silently accepting a stale run.
public enum TextToSQLEvalSourceManifest {
    public static func scorerSourcePaths(includesSchemaToolAgent: Bool) -> [String] {
        [
            "WidenKit/Evals/TextToSQLEvalCase.swift",
            "WidenKit/Evals/TextToSQLEvalScorer.swift",
            "WidenKit/Evals/TextToSQLEvalResult.swift",
            "WidenKit/Evals/TextToSQLEvalRunPlanning.swift",
            "WidenKit/Evals/TextToSQLEvalSourceManifest.swift",
            "WidenKit/Evals/TextToSQLEvalCloudSettings.swift",
            "WidenKit/Evals/TextToSQLEvalWithheldSQL.swift",
            "WidenKit/Evals/TextToSQLEvalGroundingJudge.swift",
            "WidenEval/EvalRunner.swift",
            "WidenKit/Models/SQLGenerationResult.swift",
            "WidenKit/Services/TextToSQLPipeline.swift",
            "WidenKit/Services/SQLGenerator.swift",
            "WidenKit/Services/SQLGenerationFailure.swift",
            "WidenKit/Services/SQLPromptBuilder.swift",
            "WidenKit/Services/SQLReferenceAnalyzer.swift",
            "WidenKit/Services/SQLSafetyValidator.swift",
            "WidenKit/Services/SQLSchemaValidator.swift",
            "WidenKit/Services/SchemaPromptPackager.swift",
            "WidenKit/Services/GeneratedSQLRepairCoordinator.swift",
            "WidenKit/Services/GeneratedSQLRepairSupport.swift",
            "WidenKit/Services/GeneratedSQLVerifier.swift",
            "WidenKit/Services/DatabaseInspectionTypes.swift",
            "WidenKit/Services/PostgresErrorMapper.swift",
            "WidenKit/Services/PostgresService.swift",
            "WidenKit/Models/CloudModelProfile.swift",
            "WidenKit/Services/HTTPTransport.swift",
            "WidenKit/Services/CloudSQLGenerator.swift",
            "WidenKit/Services/ChatCompletionsCore.swift",
            "WidenKit/Services/SchemaToolAgentDiagnostics.swift",
            "WidenKit/Services/OpenRouterEvalSupport.swift",
        ] + (includesSchemaToolAgent ? [
            "WidenKit/Services/SchemaToolSQLAgent.swift",
            "WidenKit/Services/ChatToolProtocol.swift",
            "WidenKit/Services/SchemaToolAgentClarificationPolicy.swift",
            "WidenKit/Services/SchemaToolAgentCritic.swift",
            "WidenKit/Services/SchemaToolAgentGroundingJudge.swift",
            "WidenKit/Services/SchemaToolAgentPlanConsistencyPolicy.swift",
            "WidenKit/Services/SchemaToolAgentSQLIntentCoveragePolicy.swift",
            "WidenKit/Services/SchemaToolRuntime.swift",
            "WidenKit/Services/SchemaToolSession.swift",
        ] : [])
    }

    public static let semanticComparatorSourcePaths = [
        "WidenKit/Evals/TextToSQLSemanticComparator.swift",
        "WidenKit/Evals/TextToSQLSemanticDatabase.swift",
    ]

    /// Hashes each path and its contents in sorted path order, so the result does
    /// not depend on list order. Throws when a listed file cannot be read.
    public static func sourceHash(
        relativePaths: [String],
        relativeTo directory: URL
    ) throws -> String {
        var data = Data()
        for path in relativePaths.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            let url = directory.appendingPathComponent(path)
            guard let fileData = try? Data(contentsOf: url) else {
                throw TextToSQLEvalSourceHashError(missingPath: path)
            }
            data.append(fileData)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TextToSQLEvalSourceHashError: Error, LocalizedError, Equatable, Sendable {
    public var missingPath: String

    public init(missingPath: String) {
        self.missingPath = missingPath
    }

    public var errorDescription: String? {
        "Eval source file \(missingPath) is missing or unreadable. Update TextToSQLEvalSourceManifest when a listed source file is renamed or removed."
    }
}
