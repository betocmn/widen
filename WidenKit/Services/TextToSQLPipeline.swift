import CryptoKit
import Foundation

public protocol TextToSQLRunning: Sendable {
    func run(_ request: TextToSQLRequest) async throws -> TextToSQLRun
}

public struct TextToSQLRequest: Sendable {
    public var question: String
    public var schema: DatabaseSchema
    public var context: SQLGenerationContext
    public var config: SQLGenerationConfig
    public var allowGroundingClarification: Bool
    public var validationRepairContext: TextToSQLRepairContext?
    public var eventSink: TextToSQLPipelineEventSink?

    public init(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext = SQLGenerationContext(),
        config: SQLGenerationConfig = SQLGenerationConfig(),
        allowGroundingClarification: Bool = true,
        validationRepairContext: TextToSQLRepairContext? = nil,
        eventSink: TextToSQLPipelineEventSink? = nil
    ) {
        self.question = question
        self.schema = schema
        self.context = context
        self.config = config
        self.allowGroundingClarification = allowGroundingClarification
        self.validationRepairContext = validationRepairContext
        self.eventSink = eventSink
    }
}

public struct TextToSQLRepairContext: Equatable, Sendable {
    public var question: String
    public var recentQuestions: [String]
    public var originalQuestion: String?
    public var conversationMessages: [SQLConversationMessage]

    public init(
        question: String,
        recentQuestions: [String],
        originalQuestion: String?,
        conversationMessages: [SQLConversationMessage]
    ) {
        self.question = question
        self.recentQuestions = recentQuestions
        self.originalQuestion = originalQuestion
        self.conversationMessages = conversationMessages
    }
}

public struct TextToSQLRun: Equatable, Sendable {
    public var finalDecision: TextToSQLDecision
    public var trace: TextToSQLTrace
    public var events: [TextToSQLPipelineEvent]

    public init(
        finalDecision: TextToSQLDecision,
        trace: TextToSQLTrace,
        events: [TextToSQLPipelineEvent] = []
    ) {
        self.finalDecision = finalDecision
        self.trace = trace
        self.events = events
    }
}

public enum TextToSQLDecision: Equatable, Sendable {
    case sql(SQLGenerationResult)
    case clarification(SQLGenerationResult)
    case failed(TextToSQLPipelineFailure)
}

public enum TextToSQLStage: String, Codable, Equatable, Sendable {
    case modelGeneration
    case postprocessing
    case canonicalization
    case safetyValidation
    case schemaValidation
    case validationRepair
    case finalDecision
}

public enum TextToSQLStageOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
    case skipped
}

public enum TextToSQLFailureCategory: String, Codable, Equatable, Sendable {
    case backendUnavailable
    case transport
    case contextWindow
    case structuredResponseParsing
    case modelGeneration
    case safetyValidation
    case schemaValidation
    case repeatedNoProgressRepair
    case cancellation
    case emptySQL
}

public struct TextToSQLPipelineFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    public var stage: TextToSQLStage
    public var category: TextToSQLFailureCategory
    public var message: String
    public var validationIssueIDs: [String]
    public var openRouterFailure: OpenRouterFailureDiagnostic?

    public init(
        stage: TextToSQLStage,
        category: TextToSQLFailureCategory,
        message: String,
        validationIssueIDs: [String] = [],
        openRouterFailure: OpenRouterFailureDiagnostic? = nil
    ) {
        self.stage = stage
        self.category = category
        self.message = message
        self.validationIssueIDs = validationIssueIDs
        self.openRouterFailure = openRouterFailure
    }

    public var errorDescription: String? { message }
}

public struct TextToSQLTrace: Codable, Equatable, Sendable {
    public var stages: [TextToSQLStageResult]
    public var modelCalls: Int
    public var elapsedMs: Int

    public init(stages: [TextToSQLStageResult], modelCalls: Int, elapsedMs: Int) {
        self.stages = stages
        self.modelCalls = modelCalls
        self.elapsedMs = elapsedMs
    }
}

public struct TextToSQLStageResult: Codable, Equatable, Sendable {
    public var stage: TextToSQLStage
    public var outcome: TextToSQLStageOutcome
    public var elapsedMs: Int
    public var modelCallCount: Int?
    public var failureCategory: TextToSQLFailureCategory?
    public var validationIssueIDs: [String]
    public var canonicalizationFixes: [String]
    public var selectedTableNames: [String]
    public var schemaFingerprint: String?

    public init(
        stage: TextToSQLStage,
        outcome: TextToSQLStageOutcome,
        elapsedMs: Int,
        modelCallCount: Int? = nil,
        failureCategory: TextToSQLFailureCategory? = nil,
        validationIssueIDs: [String] = [],
        canonicalizationFixes: [String] = [],
        selectedTableNames: [String] = [],
        schemaFingerprint: String? = nil
    ) {
        self.stage = stage
        self.outcome = outcome
        self.elapsedMs = elapsedMs
        self.modelCallCount = modelCallCount
        self.failureCategory = failureCategory
        self.validationIssueIDs = validationIssueIDs
        self.canonicalizationFixes = canonicalizationFixes
        self.selectedTableNames = selectedTableNames
        self.schemaFingerprint = schemaFingerprint
    }
}

public typealias TextToSQLPipelineEventSink = @Sendable (TextToSQLPipelineEvent) async -> Void

public enum TextToSQLPipelineEventKind: String, Equatable, Sendable {
    case validationFailed
    case validationRepairStarted
    case validationRepairGenerationFailed
    case validationRepairNeedsClarification
    case validationRepairRejected
    case validationRepairMissingSQL
    case validationRepairPassedValidation
}

public struct TextToSQLPipelineEvent: Equatable, Sendable {
    public var kind: TextToSQLPipelineEventKind
    public var stage: TextToSQLStage
    public var title: String
    public var summary: String?
    public var failureCategory: TextToSQLFailureCategory?
    public var validationIssueIDs: [String]

    public init(
        kind: TextToSQLPipelineEventKind,
        stage: TextToSQLStage,
        title: String,
        summary: String? = nil,
        failureCategory: TextToSQLFailureCategory? = nil,
        validationIssueIDs: [String] = []
    ) {
        self.kind = kind
        self.stage = stage
        self.title = title
        self.summary = summary
        self.failureCategory = failureCategory
        self.validationIssueIDs = validationIssueIDs
    }
}

public struct TextToSQLPipeline: TextToSQLRunning {
    private let generator: any SQLGenerator

    public init(generator: any SQLGenerator) {
        self.generator = generator
    }

    public func run(_ request: TextToSQLRequest) async throws -> TextToSQLRun {
        let started = Date()
        var trace = TraceBuilder(schema: request.schema)
        var events: [TextToSQLPipelineEvent] = []

        let generated: SQLGenerationResult
        let modelGenerationStart = Date()
        do {
            generated = try await generator.generateSQL(
                question: request.question,
                schema: request.schema,
                context: request.context,
                config: request.config
            )
            trace.append(
                .modelGeneration,
                outcome: .success,
                since: modelGenerationStart,
                modelCallCount: generated.generationCallCount
            )
        } catch is CancellationError {
            trace.append(
                .modelGeneration,
                outcome: .failure,
                since: modelGenerationStart,
                failureCategory: .cancellation
            )
            throw CancellationError()
        } catch {
            let failure = generationFailure(error, stage: .modelGeneration)
            trace.append(
                .modelGeneration,
                outcome: .failure,
                since: modelGenerationStart,
                failureCategory: failure.category
            )
            return finished(
                decision: .failed(failure),
                trace: trace,
                events: events,
                started: started
            )
        }

        let postprocessStart = Date()
        let result = GeneratedSQLPostprocessor.enriched(
            generated,
            question: request.question,
            schema: request.schema,
            databaseContext: request.config.databaseContext,
            confirmedSemanticBindings: request.context.confirmedSemanticBindings,
            allowGroundingClarification: request.allowGroundingClarification
        )
        trace.append(
            .postprocessing,
            outcome: .success,
            since: postprocessStart,
            modelCallCount: result.generationCallCount
        )

        if result.needsClarification,
            result.clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            trace.append(.canonicalization, outcome: .skipped, since: Date())
            trace.append(.safetyValidation, outcome: .skipped, since: Date())
            trace.append(.schemaValidation, outcome: .skipped, since: Date())
            trace.append(.validationRepair, outcome: .skipped, since: Date())
            trace.append(.finalDecision, outcome: .success, since: Date())
            return finished(
                decision: .clarification(result),
                trace: trace,
                events: events,
                started: started
            )
        }

        let generatedSQL = result.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generatedSQL.isEmpty else {
            let failure = TextToSQLPipelineFailure(
                stage: .modelGeneration,
                category: .emptySQL,
                message: "The model did not return SQL."
            )
            trace.append(
                .canonicalization,
                outcome: .failure,
                since: Date(),
                failureCategory: .emptySQL
            )
            trace.append(
                .finalDecision,
                outcome: .failure,
                since: Date(),
                failureCategory: .emptySQL
            )
            return finished(
                decision: .failed(failure),
                trace: trace,
                events: events,
                started: started
            )
        }

        trace.append(.canonicalization, outcome: .success, since: Date())
        let validation = validate(
            sql: generatedSQL,
            schema: request.schema,
            trace: &trace
        )

        if validation.combined.isValid {
            trace.append(.validationRepair, outcome: .skipped, since: Date())
            trace.append(.finalDecision, outcome: .success, since: Date())
            return finished(
                decision: .sql(result.withPipelineSQL(generatedSQL)),
                trace: trace,
                events: events,
                started: started
            )
        }

        if let repairedSQL = GeneratedSQLValidator.repairQuotedIdentifiers(
            sql: generatedSQL,
            schema: request.schema
        ) {
            trace.append(
                .canonicalization,
                outcome: .success,
                since: Date(),
                canonicalizationFixes: ["quote-repair"]
            )
            let repairedValidation = validate(
                sql: repairedSQL,
                schema: request.schema,
                trace: &trace
            )
            if repairedValidation.combined.isValid {
                trace.append(.validationRepair, outcome: .skipped, since: Date())
                trace.append(.finalDecision, outcome: .success, since: Date())
                return finished(
                    decision: .sql(result.withPipelineSQL(repairedSQL)),
                    trace: trace,
                    events: events,
                    started: started
                )
            }
        }

        let firstError = AppError.validationFailed(validation.combined.errors).localizedDescription
        let validationIssueIDs = validation.safety.errors.map {
            redactedIssueID(prefix: "safety", value: $0)
        } + validation.schema.issues.map(\.traceID)
        let validationEventStage: TextToSQLStage =
            validation.safety.isValid ? .schemaValidation : .safetyValidation
        let validationFailureCategory: TextToSQLFailureCategory =
            validation.safety.isValid ? .schemaValidation : .safetyValidation
        await record(
            TextToSQLPipelineEvent(
                kind: .validationFailed,
                stage: validationEventStage,
                title: "Generated SQL failed validation.",
                summary: "Generated SQL failed local validation.",
                failureCategory: validationFailureCategory,
                validationIssueIDs: validationIssueIDs
            ),
            request: request,
            events: &events
        )
        let repairRun = try await runValidationRepair(
            request: request,
            startingGeneration: result.withPipelineSQL(generatedSQL),
            startingSQL: generatedSQL,
            firstError: firstError,
            trace: &trace,
            events: &events
        )
        trace.append(
            .finalDecision,
            outcome: repairRun.isSuccessful ? .success : .failure,
            since: Date(),
            failureCategory: repairRun.failureCategory
        )
        return finished(
            decision: repairRun.decision,
            trace: trace,
            events: events,
            started: started
        )
    }

    private func runValidationRepair(
        request: TextToSQLRequest,
        startingGeneration: SQLGenerationResult,
        startingSQL: String,
        firstError: String,
        trace: inout TraceBuilder,
        events: inout [TextToSQLPipelineEvent]
    ) async throws -> RepairRun {
        let repairQuestionContext = request.validationRepairContext
            ?? TextToSQLRepairContext(
                question: request.question,
                recentQuestions: Array(request.context.recentQuestions.suffix(3)),
                originalQuestion: request.context.originalQuestion ?? request.question,
                conversationMessages: request.context.conversationMessages
                    + [SQLConversationMessage(role: .user, text: request.question)]
            )
        let firstDiagnostic = GeneratedSQLRepairSupport.diagnostic(from: firstError)
        let allowRepairWrites = SQLSafetyValidator.validate(startingSQL).kind.isWrite
        let forbiddenIdentifiers = GeneratedSQLRepairSupport.forbiddenIdentifiers(
            sql: startingSQL,
            error: firstError,
            diagnostic: firstDiagnostic,
            schema: request.schema
        )
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: startingSQL,
            firstError: firstError,
            diagnostic: firstDiagnostic,
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: GeneratedSQLRepairSupport.repairConstraints(
                forbiddenIdentifiers: forbiddenIdentifiers,
                error: firstError
            ),
            maxModelCalls: GeneratedSQLRepairSupport.remainingRepairCalls(
                after: startingGeneration
            )
        )

        while let repairMode = coordinator.beginNextAttempt() {
            let attemptNumber = repairMode == .repair ? 1 : 2
            let repairContext = coordinator.repairContext(for: repairMode)
            let repairLabel = repairMode.activityLabel
            await record(
                TextToSQLPipelineEvent(
                    kind: .validationRepairStarted,
                    stage: .validationRepair,
                    title: "\(repairLabel) started.",
                    summary: "Validation repair attempt started."
                ),
                request: request,
                events: &events
            )
            let context = SQLGenerationContext(
                mode: repairMode,
                recentQuestions: repairMode == .repair ? repairQuestionContext.recentQuestions : [],
                originalQuestion: repairQuestionContext.originalQuestion,
                conversationMessages: repairMode == .repair
                    ? repairQuestionContext.conversationMessages : [],
                currentSQL: repairMode == .repair ? repairContext.failedSQL : nil,
                lastRunError: repairMode == .repair ? coordinator.constraints.lastError : nil,
                repairContext: repairContext,
                modelCallCount: GeneratedSQLRepairSupport.cumulativeModelCallCount(
                    after: startingGeneration,
                    attempt: attemptNumber
                ),
                confirmedSemanticBindings: request.context.confirmedSemanticBindings
            )

            let generation: SQLGenerationResult
            let stageStart = Date()
            do {
                let generated = try await generator.generateSQL(
                    question: repairQuestionContext.question,
                    schema: request.schema,
                    context: context,
                    config: request.config
                )
                generation = GeneratedSQLPostprocessor.enriched(
                    generated,
                    question: repairQuestionContext.question,
                    schema: request.schema,
                    databaseContext: request.config.databaseContext,
                    confirmedSemanticBindings: context.confirmedSemanticBindings,
                    allowGroundingClarification: request.allowGroundingClarification
                )
            } catch is CancellationError {
                trace.append(
                    .validationRepair,
                    outcome: .failure,
                    since: stageStart,
                    modelCallCount: context.modelCallCount,
                    failureCategory: .cancellation
                )
                throw CancellationError()
            } catch {
                let failure = generationFailure(error, stage: .validationRepair)
                await record(
                    TextToSQLPipelineEvent(
                        kind: .validationRepairGenerationFailed,
                        stage: .validationRepair,
                        title: "\(repairLabel) failed before producing SQL.",
                        summary: "Validation repair failed before producing SQL.",
                        failureCategory: failure.category
                    ),
                    request: request,
                    events: &events
                )
                trace.append(
                    .validationRepair,
                    outcome: .failure,
                    since: stageStart,
                    modelCallCount: context.modelCallCount,
                    failureCategory: failure.category
                )
                return RepairRun(decision: .failed(failure), failureCategory: failure.category)
            }

            let evaluation = coordinator.evaluateCandidate(
                generation,
                mode: repairMode,
                schema: request.schema,
                allowWrites: allowRepairWrites
            )

            switch evaluation.outcome {
            case .clarification:
                guard let clarification = evaluation.message,
                    !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    let failure = repairFailure(
                        attempts: coordinator.attempts,
                        category: .repeatedNoProgressRepair
                    )
                    trace.append(
                        .validationRepair,
                        outcome: .failure,
                        since: stageStart,
                        modelCallCount: generation.generationCallCount,
                        failureCategory: failure.category
                    )
                    return RepairRun(decision: .failed(failure), failureCategory: failure.category)
                }
                trace.append(
                    .validationRepair,
                    outcome: .success,
                    since: stageStart,
                    modelCallCount: generation.generationCallCount
                )
                await record(
                    TextToSQLPipelineEvent(
                        kind: .validationRepairNeedsClarification,
                        stage: .validationRepair,
                        title: "\(repairLabel) needs clarification.",
                        summary: "Validation repair needs clarification."
                    ),
                    request: request,
                    events: &events
                )
                return RepairRun(decision: .clarification(generation))

            case .rejected(let reason):
                let category = failureCategory(for: reason, evaluation: evaluation)
                trace.append(
                    .validationRepair,
                    outcome: .failure,
                    since: stageStart,
                    modelCallCount: generation.generationCallCount,
                    failureCategory: category
                )
                await record(
                    TextToSQLPipelineEvent(
                        kind: .validationRepairRejected,
                        stage: .validationRepair,
                        title: "\(repairLabel) was rejected.",
                        summary: "Validation repair candidate was rejected.",
                        failureCategory: category
                    ),
                    request: request,
                    events: &events
                )
                if reason.isZeroProgressRepair {
                    let diagnosticText = firstDiagnostic?.displayMessage ?? firstError
                    if !GeneratedSQLRepairSupport.missingColumnsCanBeResolvedByJoining(
                        sql: startingSQL,
                        error: diagnosticText,
                        schema: request.schema
                    ),
                        let clarification = SQLPromptBuilder.missingColumnClarificationQuestion(
                            for: diagnosticText,
                            question: repairQuestionContext.originalQuestion
                                ?? repairQuestionContext.question,
                            schema: request.schema
                        )
                    {
                        return RepairRun(
                            decision: .clarification(
                                SQLGenerationResult.pipelineClarification(clarification)
                            )
                        )
                    }
                    if let clarification = SQLPromptBuilder.missingRelationClarificationQuestion(
                        for: diagnosticText
                    ) {
                        return RepairRun(
                            decision: .clarification(
                                SQLGenerationResult.pipelineClarification(clarification)
                            )
                        )
                    }
                }
                if evaluation.allowsReconstruction, coordinator.canRequestAnotherModelCall {
                    continue
                }
                let failure = repairFailure(attempts: coordinator.attempts, category: category)
                return RepairRun(decision: .failed(failure), failureCategory: failure.category)

            case .accepted:
                break
            }

            guard let generatedSQL = evaluation.sql else {
                let failure = repairFailure(
                    attempts: coordinator.attempts,
                    category: .modelGeneration
                )
                trace.append(
                    .validationRepair,
                    outcome: .failure,
                    since: stageStart,
                    modelCallCount: generation.generationCallCount,
                    failureCategory: failure.category
                )
                await record(
                    TextToSQLPipelineEvent(
                        kind: .validationRepairMissingSQL,
                        stage: .validationRepair,
                        title: "\(repairLabel) did not return SQL.",
                        summary: "Validation repair did not return corrected SQL.",
                        failureCategory: failure.category
                    ),
                    request: request,
                    events: &events
                )
                return RepairRun(decision: .failed(failure), failureCategory: failure.category)
            }

            trace.append(
                .validationRepair,
                outcome: .success,
                since: stageStart,
                modelCallCount: generation.generationCallCount
            )
            await record(
                TextToSQLPipelineEvent(
                    kind: .validationRepairPassedValidation,
                    stage: .validationRepair,
                    title: "\(repairLabel) passed validation.",
                    summary: "Validation repair produced locally valid SQL."
                ),
                request: request,
                events: &events
            )
            return RepairRun(decision: .sql(generation.withPipelineSQL(generatedSQL)))
        }

        let failure = repairFailure(
            attempts: coordinator.attempts,
            category: .repeatedNoProgressRepair
        )
        trace.append(
            .validationRepair,
            outcome: .failure,
            since: Date(),
            failureCategory: failure.category
        )
        return RepairRun(decision: .failed(failure), failureCategory: failure.category)
    }

    private func record(
        _ event: TextToSQLPipelineEvent,
        request: TextToSQLRequest,
        events: inout [TextToSQLPipelineEvent]
    ) async {
        events.append(event)
        guard let sink = request.eventSink else { return }
        await sink(event)
    }

    private func validate(
        sql: String,
        schema: DatabaseSchema,
        trace: inout TraceBuilder
    ) -> (safety: SQLValidationResult, schema: SQLSchemaValidationResult, combined: SQLValidationResult) {
        let safetyStart = Date()
        let safety = SQLSafetyValidator.validate(sql)
        trace.append(
            .safetyValidation,
            outcome: safety.isValid ? .success : .failure,
            since: safetyStart,
            failureCategory: safety.isValid ? nil : .safetyValidation,
            validationIssueIDs: safety.errors.map {
                redactedIssueID(prefix: "safety", value: $0)
            }
        )

        let schemaStart = Date()
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        trace.append(
            .schemaValidation,
            outcome: schemaValidation.hasDefiniteErrors ? .failure : .success,
            since: schemaStart,
            failureCategory: schemaValidation.hasDefiniteErrors ? .schemaValidation : nil,
            validationIssueIDs: schemaValidation.issues.map(\.traceID)
        )

        return (
            safety,
            schemaValidation,
            GeneratedSQLValidator.combine(safety: safety, schemaValidation: schemaValidation)
        )
    }

    private func generationFailure(
        _ error: any Error,
        stage: TextToSQLStage
    ) -> TextToSQLPipelineFailure {
        if let failure = SQLGenerationFailure.typed(error) {
            let openRouterDiagnostic: OpenRouterFailureDiagnostic?
            if case .openRouter(let openRouterFailure) = failure {
                openRouterDiagnostic = openRouterFailure.diagnostic
            } else {
                openRouterDiagnostic = nil
            }
            return TextToSQLPipelineFailure(
                stage: stage,
                category: failure.pipelineCategory,
                message: failure.localizedDescription,
                openRouterFailure: openRouterDiagnostic
            )
        }
        return TextToSQLPipelineFailure(
            stage: stage,
            category: .modelGeneration,
            message: error.localizedDescription
        )
    }

    private func failureCategory(
        for reason: SQLRepairCandidateRejectionReason,
        evaluation: SQLRepairCandidateEvaluation
    ) -> TextToSQLFailureCategory {
        switch reason {
        case .repeatedFingerprint, .forbiddenIdentifier:
            if candidateFailsSafety(evaluation) {
                .safetyValidation
            } else {
                .repeatedNoProgressRepair
            }
        case .unsafeWrite:
            .safetyValidation
        case .validationFailure:
            if candidateFailsSafety(evaluation) {
                .safetyValidation
            } else {
                .schemaValidation
            }
        case .emptySQL:
            .modelGeneration
        }
    }

    private func candidateFailsSafety(_ evaluation: SQLRepairCandidateEvaluation) -> Bool {
        guard let sql = evaluation.sql else { return false }
        return !SQLSafetyValidator.validate(sql).isValid
    }

    private func repairFailure(
        attempts: [SQLRepairAttempt],
        category: TextToSQLFailureCategory
    ) -> TextToSQLPipelineFailure {
        TextToSQLPipelineFailure(
            stage: .validationRepair,
            category: category,
            message: GeneratedSQLRepairSupport.repairFailureMessage(
                attempts: attempts,
                mode: .validationOnly
            )
        )
    }

    private func finished(
        decision: TextToSQLDecision,
        trace: TraceBuilder,
        events: [TextToSQLPipelineEvent],
        started: Date
    ) -> TextToSQLRun {
        TextToSQLRun(
            finalDecision: decision,
            trace: TextToSQLTrace(
                stages: trace.stages,
                modelCalls: max(
                    decision.modelCallCount,
                    trace.stages.compactMap(\.modelCallCount).max() ?? 0
                ),
                elapsedMs: elapsedMilliseconds(since: started)
            ),
            events: events
        )
    }
}

private struct RepairRun {
    var decision: TextToSQLDecision
    var failureCategory: TextToSQLFailureCategory?

    var isSuccessful: Bool {
        switch decision {
        case .sql, .clarification:
            true
        case .failed:
            false
        }
    }
}

private struct TraceBuilder {
    private let schemaFingerprint: String
    var stages: [TextToSQLStageResult] = []

    init(schema: DatabaseSchema) {
        self.schemaFingerprint = Self.fingerprint(schema)
    }

    mutating func append(
        _ stage: TextToSQLStage,
        outcome: TextToSQLStageOutcome,
        since started: Date,
        modelCallCount: Int? = nil,
        failureCategory: TextToSQLFailureCategory? = nil,
        validationIssueIDs: [String] = [],
        canonicalizationFixes: [String] = [],
        selectedTableNames: [String] = []
    ) {
        stages.append(
            TextToSQLStageResult(
                stage: stage,
                outcome: outcome,
                elapsedMs: elapsedMilliseconds(since: started),
                modelCallCount: modelCallCount,
                failureCategory: failureCategory,
                validationIssueIDs: validationIssueIDs,
                canonicalizationFixes: canonicalizationFixes,
                selectedTableNames: selectedTableNames,
                schemaFingerprint: schemaFingerprint
            )
        )
    }

    private static func fingerprint(_ schema: DatabaseSchema) -> String {
        let text = schema.tables
            .sorted { $0.qualifiedName < $1.qualifiedName }
            .map { table in
                let columns = table.columns
                    .sorted { $0.ordinalPosition < $1.ordinalPosition }
                    .map { "\($0.name):\($0.dataType)" }
                    .joined(separator: ",")
                return "\(table.qualifiedName)(\(columns))"
            }
            .joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension SQLGenerationMode {
    var activityLabel: String {
        switch self {
        case .repair:
            "Focused repair"
        case .reconstructAfterFailedRepair:
            "Reconstruction"
        case .initial:
            "Initial generation"
        case .followUp:
            "Follow-up generation"
        }
    }
}

private extension SQLGenerationResult {
    func withPipelineSQL(_ sql: String) -> SQLGenerationResult {
        var copy = self
        copy.sql = sql
        return copy
    }

    static func pipelineClarification(_ question: String) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "",
            explanation: question,
            assumptions: [],
            referencedTables: [],
            confidence: 0.2,
            riskLevel: .medium,
            needsClarification: true,
            clarificationQuestion: question
        )
    }
}

private extension SQLSchemaValidationIssue {
    var traceID: String {
        let severity =
            switch severity {
            case .error: "error"
            case .warning: "warning"
            }
        return "schema:\(severity):\(kind.traceID)"
    }
}

private extension SQLSchemaValidationIssue.Kind {
    var traceID: String {
        switch self {
        case .missingRelation:
            "missingRelation"
        case .unresolvedQualifier:
            "unresolvedQualifier"
        case .missingColumn:
            "missingColumn"
        case .missingBaseColumn:
            "missingBaseColumn"
        case .missingDerivedColumn:
            "missingDerivedColumn"
        case .columnNotProjectedByCTE:
            "columnNotProjectedByCTE"
        case .ambiguousColumn:
            "ambiguousColumn"
        case .requiresQuotedIdentifier:
            "requiresQuotedIdentifier"
        case .invalidTemporalComparison:
            "invalidTemporalComparison"
        case .analysisIncomplete:
            "analysisIncomplete"
        case .other:
            "other"
        }
    }
}

private extension TextToSQLDecision {
    var modelCallCount: Int {
        switch self {
        case .sql(let generation), .clarification(let generation):
            return generation.generationCallCount ?? 0
        case .failed:
            return 0
        }
    }
}

private func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
}

private func redactedIssueID(prefix: String, value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "\(prefix):\(digest.prefix(16))"
}
