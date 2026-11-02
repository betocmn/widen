import Foundation

enum HTTPAttemptBudget {
    static func remaining(
        maximumHTTPAttempts: Int,
        contextModelCallCount: Int
    ) -> Int {
        let priorHTTPAttempts = max(0, contextModelCallCount - 1)
        return max(0, maximumHTTPAttempts - priorHTTPAttempts)
    }
}

public struct HTTPAttemptBudgetExhausted: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var backendMetadata: CloudGenerationMetadata?

    public init(
        message: String,
        backendMetadata: CloudGenerationMetadata? = nil
    ) {
        self.message = message
        self.backendMetadata = backendMetadata
    }

    public var errorDescription: String? {
        message
    }
}

/// Typed generation failures shared by SQL generator backends and the
/// headless text-to-SQL pipeline. The localized descriptions intentionally
/// match the previous `AppError` wording for user-facing compatibility.
public enum SQLGenerationFailure: Error, LocalizedError, Equatable, Sendable {
    case backendUnavailable(String)
    case transport(String)
    case contextWindow(String)
    case structuredResponseParsing(String)
    case generation(String)
    case cloudRequest(CloudRequestFailure)
    case httpBudgetExhausted(HTTPAttemptBudgetExhausted)
    case schemaToolAgent(SchemaToolAgentFailure)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable(let detail):
            detail
        case .transport(let detail),
            .contextWindow(let detail),
            .structuredResponseParsing(let detail),
            .generation(let detail):
            "SQL generation failed: \(detail)"
        case .cloudRequest(let failure):
            failure.localizedDescription
        case .httpBudgetExhausted(let failure):
            failure.localizedDescription
        case .schemaToolAgent(let failure):
            failure.localizedDescription
        }
    }

    public var detail: String {
        switch self {
        case .backendUnavailable(let detail),
            .transport(let detail),
            .contextWindow(let detail),
            .structuredResponseParsing(let detail),
            .generation(let detail):
            detail
        case .cloudRequest(let failure):
            failure.message
        case .httpBudgetExhausted(let failure):
            failure.message
        case .schemaToolAgent(let failure):
            failure.message
        }
    }

    var pipelineCategory: TextToSQLFailureCategory {
        switch self {
        case .backendUnavailable:
            .backendUnavailable
        case .transport:
            .transport
        case .contextWindow:
            .contextWindow
        case .structuredResponseParsing:
            .structuredResponseParsing
        case .generation:
            .modelGeneration
        case .cloudRequest(let failure):
            failure.pipelineCategory
        case .httpBudgetExhausted:
            .httpBudgetExhausted
        case .schemaToolAgent(let failure):
            failure.pipelineCategory
        }
    }

    public static func typed(_ error: any Error) -> SQLGenerationFailure? {
        if let failure = error as? SQLGenerationFailure {
            return failure
        }
        if let failure = error as? CloudRequestFailure {
            return .cloudRequest(failure)
        }
        if let failure = error as? HTTPAttemptBudgetExhausted {
            return .httpBudgetExhausted(failure)
        }
        if let failure = error as? SchemaToolAgentFailure {
            return .schemaToolAgent(failure)
        }
        if let appError = error as? AppError {
            switch appError {
            case .modelUnavailable(let message):
                return .backendUnavailable(message)
            case .modelGenerationFailed(let message):
                return .generation(message)
            default:
                return nil
            }
        }
        return nil
    }
}
