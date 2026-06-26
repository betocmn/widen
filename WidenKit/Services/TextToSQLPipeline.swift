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
    public var sqlVerifier: (any GeneratedSQLVerifying)?
    public var verificationConnection: PostgresConnectionHandle?

    public init(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext = SQLGenerationContext(),
        config: SQLGenerationConfig = SQLGenerationConfig(),
        allowGroundingClarification: Bool = true,
        validationRepairContext: TextToSQLRepairContext? = nil,
        eventSink: TextToSQLPipelineEventSink? = nil,
        sqlVerifier: (any GeneratedSQLVerifying)? = nil,
        verificationConnection: PostgresConnectionHandle? = nil
    ) {
        self.question = question
        self.schema = schema
        self.context = context
        self.config = config
        self.allowGroundingClarification = allowGroundingClarification
        self.validationRepairContext = validationRepairContext
        self.eventSink = eventSink
        self.sqlVerifier = sqlVerifier
        self.verificationConnection = verificationConnection
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
    case postgresVerification
    case postgresVerificationRepair
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
    case postgresVerification
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
    public var backendMetadata: OpenRouterGenerationMetadata?
    public var databaseDiagnostic: DatabaseDiagnostic?
    public var verificationStatus: SQLVerificationStatus?

    public init(
        stage: TextToSQLStage,
        category: TextToSQLFailureCategory,
        message: String,
        validationIssueIDs: [String] = [],
        openRouterFailure: OpenRouterFailureDiagnostic? = nil,
        backendMetadata: OpenRouterGenerationMetadata? = nil,
        databaseDiagnostic: DatabaseDiagnostic? = nil,
        verificationStatus: SQLVerificationStatus? = nil
    ) {
        self.stage = stage
        self.category = category
        self.message = message
        self.validationIssueIDs = validationIssueIDs
        self.openRouterFailure = openRouterFailure
        self.backendMetadata = backendMetadata
        self.databaseDiagnostic = databaseDiagnostic
        self.verificationStatus = verificationStatus
    }

    public var errorDescription: String? { message }
}

public struct TextToSQLTrace: Codable, Equatable, Sendable {
    public var stages: [TextToSQLStageResult]
    public var modelCalls: Int
    public var elapsedMs: Int
    public var schemaToolCalls: [SchemaToolCallTrace]
    public var inspectionToolCalls: [DatabaseInspectionToolCallTrace]

    public init(
        stages: [TextToSQLStageResult],
        modelCalls: Int,
        elapsedMs: Int,
        schemaToolCalls: [SchemaToolCallTrace] = [],
        inspectionToolCalls: [DatabaseInspectionToolCallTrace] = []
    ) {
        self.stages = stages
        self.modelCalls = modelCalls
        self.elapsedMs = elapsedMs
        self.schemaToolCalls = schemaToolCalls
        self.inspectionToolCalls = inspectionToolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case stages
        case modelCalls
        case elapsedMs
        case schemaToolCalls
        case inspectionToolCalls
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decode([TextToSQLStageResult].self, forKey: .stages)
        modelCalls = try container.decode(Int.self, forKey: .modelCalls)
        elapsedMs = try container.decode(Int.self, forKey: .elapsedMs)
        schemaToolCalls = try container.decodeIfPresent(
            [SchemaToolCallTrace].self,
            forKey: .schemaToolCalls
        ) ?? []
        inspectionToolCalls = try container.decodeIfPresent(
            [DatabaseInspectionToolCallTrace].self,
            forKey: .inspectionToolCalls
        ) ?? []
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
    public var verificationStatus: SQLVerificationStatus?
    public var sqlState: String?
    public var databaseDiagnosticKind: DatabaseDiagnosticKind?
    public var verificationRepairAttempted: Bool?

    public init(
        stage: TextToSQLStage,
        outcome: TextToSQLStageOutcome,
        elapsedMs: Int,
        modelCallCount: Int? = nil,
        failureCategory: TextToSQLFailureCategory? = nil,
        validationIssueIDs: [String] = [],
        canonicalizationFixes: [String] = [],
        selectedTableNames: [String] = [],
        schemaFingerprint: String? = nil,
        verificationStatus: SQLVerificationStatus? = nil,
        sqlState: String? = nil,
        databaseDiagnosticKind: DatabaseDiagnosticKind? = nil,
        verificationRepairAttempted: Bool? = nil
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
        self.verificationStatus = verificationStatus
        self.sqlState = sqlState
        self.databaseDiagnosticKind = databaseDiagnosticKind
        self.verificationRepairAttempted = verificationRepairAttempted
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
    case postgresVerificationFailed
    case postgresVerificationRepairStarted
    case postgresVerificationRepairRejected
    case postgresVerificationRepairPassed
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

    private var usesConstrainedLocalPolicy: Bool {
        generator is any ConstrainedLocalSQLGenerator
    }

    private var repairModelCallBudget: Int {
        usesConstrainedLocalPolicy
            ? GeneratedSQLRepairSupport.constrainedLocalModelCallBudget
            : GeneratedSQLRepairSupport.localModelCallBudget
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
            trace.mergeSchemaToolCalls(generated.schemaToolCalls)
            trace.mergeInspectionToolCalls(generated.inspectionToolCalls)
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
            trace.mergeSchemaToolCalls(schemaToolCalls(from: error))
            trace.mergeInspectionToolCalls(inspectionToolCalls(from: error))
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
            trace.append(.postgresVerification, outcome: .skipped, since: Date())
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
            trace.append(.postgresVerification, outcome: .skipped, since: Date())
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
            return try await finishVerifiedSQL(
                request: request,
                generation: result.withPipelineSQL(generatedSQL),
                sql: generatedSQL,
                validation: validation.combined,
                trace: &trace,
                events: &events,
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
                return try await finishVerifiedSQL(
                    request: request,
                    generation: result.withPipelineSQL(repairedSQL),
                    sql: repairedSQL,
                    validation: repairedValidation.combined,
                    trace: &trace,
                    events: &events,
                    started: started
                )
            }
        }

        let firstError = AppError.validationFailed(validation.combined.errors).localizedDescription
        trace.append(
            .postgresVerification,
            outcome: .skipped,
            since: Date(),
            verificationStatus: .skippedStaticValidationFailed
        )
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
        if usesConstrainedLocalPolicy && validation.safety.kind.isWrite {
            let failure = TextToSQLPipelineFailure(
                stage: validationEventStage,
                category: validationFailureCategory,
                message: firstError
            )
            trace.append(.validationRepair, outcome: .skipped, since: Date())
            trace.append(
                .finalDecision,
                outcome: .failure,
                since: Date(),
                failureCategory: failure.category
            )
            return finished(
                decision: .failed(failure),
                trace: trace,
                events: events,
                started: started
            )
        }
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

    private func finishVerifiedSQL(
        request: TextToSQLRequest,
        generation: SQLGenerationResult,
        sql: String,
        validation: SQLValidationResult,
        trace: inout TraceBuilder,
        events: inout [TextToSQLPipelineEvent],
        started: Date
    ) async throws -> TextToSQLRun {
        let verification = try await verifyGeneratedSQL(
            sql: sql,
            validation: validation,
            request: request,
            trace: &trace,
            stage: .postgresVerification
        )
        if verification.passed || verification.status.isAcceptableSkip {
            trace.append(.validationRepair, outcome: .skipped, since: Date())
            trace.append(.finalDecision, outcome: .success, since: Date())
            return finished(
                decision: .sql(generation),
                trace: trace,
                events: events,
                started: started
            )
        }

        await record(
            TextToSQLPipelineEvent(
                kind: .postgresVerificationFailed,
                stage: .postgresVerification,
                title: "Generated SQL failed PostgreSQL verification.",
                summary: verification.diagnostic?.kind.rawValue ?? verification.status.rawValue,
                failureCategory: .postgresVerification
            ),
            request: request,
            events: &events
        )

        guard verification.isRepairable else {
            let failure = postgresVerificationFailure(
                stage: .postgresVerification,
                verification: verification
            )
            trace.append(
                .validationRepair,
                outcome: .skipped,
                since: Date(),
                verificationRepairAttempted: false
            )
            trace.append(
                .finalDecision,
                outcome: .failure,
                since: Date(),
                failureCategory: failure.category
            )
            return finished(
                decision: .failed(failure),
                trace: trace,
                events: events,
                started: started
            )
        }

        let repairRun = try await runPostgresVerificationRepair(
            request: request,
            startingGeneration: generation,
            startingSQL: sql,
            verification: verification,
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

    private func verifyGeneratedSQL(
        sql: String,
        validation: SQLValidationResult,
        request: TextToSQLRequest,
        trace: inout TraceBuilder,
        stage: TextToSQLStage,
        started: Date = Date(),
        modelCallCount: Int? = nil,
        repairAttempted: Bool? = nil
    ) async throws -> SQLVerificationResult {
        guard !validation.kind.isWrite else {
            let result = SQLVerificationResult.skipped(
                .skippedNonRead,
                message: "PostgreSQL verification is only run for generated read SQL."
            )
            trace.appendVerification(
                stage,
                result: result,
                outcome: .skipped,
                since: started,
                modelCallCount: modelCallCount,
                repairAttempted: repairAttempted
            )
            return result
        }
        guard let verifier = request.sqlVerifier else {
            let result = SQLVerificationResult.skipped(
                .notAvailable,
                message: "No PostgreSQL verifier is available for this pipeline run."
            )
            trace.appendVerification(
                stage,
                result: result,
                outcome: .skipped,
                since: started,
                modelCallCount: modelCallCount,
                repairAttempted: repairAttempted
            )
            return result
        }
        guard let connection = request.verificationConnection else {
            let result = SQLVerificationResult.skipped(
                .skippedNoConnection,
                message: "No live PostgreSQL connection is available for verification."
            )
            trace.appendVerification(
                stage,
                result: result,
                outcome: .skipped,
                since: started,
                modelCallCount: modelCallCount,
                repairAttempted: repairAttempted
            )
            return result
        }

        do {
            let result = try await verifier.verify(
                sql: sql,
                connection: connection,
                safetyMode: SQLSafetyMode(kind: validation.kind)
            )
            trace.appendVerification(
                stage,
                result: result,
                outcome: result.passed ? .success : (result.status.isAcceptableSkip ? .skipped : .failure),
                since: started,
                modelCallCount: modelCallCount,
                repairAttempted: repairAttempted
            )
            return result
        } catch is CancellationError {
            trace.append(
                stage,
                outcome: .failure,
                since: started,
                modelCallCount: modelCallCount,
                failureCategory: .cancellation,
                verificationRepairAttempted: repairAttempted
            )
            throw CancellationError()
        } catch {
            let result = thrownVerificationFailure(from: error, since: started)
            trace.appendVerification(
                stage,
                result: result,
                outcome: .failure,
                since: started,
                modelCallCount: modelCallCount,
                repairAttempted: repairAttempted
            )
            return result
        }
    }

    private func runPostgresVerificationRepair(
        request: TextToSQLRequest,
        startingGeneration: SQLGenerationResult,
        startingSQL: String,
        verification: SQLVerificationResult,
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
        let firstError = verificationFailureMessage(verification)
        let diagnostic = verification.diagnostic
        let allowRepairWrites =
            !usesConstrainedLocalPolicy && SQLSafetyValidator.validate(startingSQL).kind.isWrite
        let forbiddenIdentifiers = GeneratedSQLRepairSupport.forbiddenIdentifiers(
            sql: startingSQL,
            error: firstError,
            diagnostic: diagnostic,
            schema: request.schema
        )
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: startingSQL,
            firstError: firstError,
            diagnostic: diagnostic,
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: GeneratedSQLRepairSupport.repairConstraints(
                forbiddenIdentifiers: forbiddenIdentifiers,
                error: firstError
            ),
            maxModelCalls: usesConstrainedLocalPolicy
                ? GeneratedSQLRepairSupport.remainingRepairCalls(
                    after: startingGeneration,
                    modelCallBudget: repairModelCallBudget
                )
                : 1
        )

        guard let repairMode = coordinator.beginNextAttempt() else {
            let failure = postgresVerificationFailure(
                stage: .postgresVerificationRepair,
                verification: verification
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)
        }

        let stageStart = Date()
        let repairContext = coordinator.repairContext(for: repairMode)
        await record(
            TextToSQLPipelineEvent(
                kind: .postgresVerificationRepairStarted,
                stage: .postgresVerificationRepair,
                title: "PostgreSQL verification repair started.",
                summary: "Verification repair attempt started."
            ),
            request: request,
            events: &events
        )
        let context = SQLGenerationContext(
            mode: repairMode,
            recentQuestions: repairQuestionContext.recentQuestions,
            originalQuestion: repairQuestionContext.originalQuestion,
            conversationMessages: repairQuestionContext.conversationMessages,
            currentSQL: repairContext.failedSQL,
            lastRunError: coordinator.constraints.lastError,
            repairContext: repairContext,
            modelCallCount: GeneratedSQLRepairSupport.cumulativeModelCallCount(
                after: startingGeneration,
                attempt: 1
            ),
            confirmedSemanticBindings: request.context.confirmedSemanticBindings
        )

        let generation: SQLGenerationResult
        do {
            let generated = try await generator.generateSQL(
                question: repairQuestionContext.question,
                schema: request.schema,
                context: context,
                config: request.config
            )
            trace.mergeSchemaToolCalls(generated.schemaToolCalls)
            trace.mergeInspectionToolCalls(generated.inspectionToolCalls)
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
                .postgresVerificationRepair,
                outcome: .failure,
                since: stageStart,
                modelCallCount: context.modelCallCount,
                failureCategory: .cancellation,
                verificationRepairAttempted: true
            )
            throw CancellationError()
        } catch {
            trace.mergeSchemaToolCalls(schemaToolCalls(from: error))
            trace.mergeInspectionToolCalls(inspectionToolCalls(from: error))
            let failure = generationFailure(error, stage: .postgresVerificationRepair)
            trace.append(
                .postgresVerificationRepair,
                outcome: .failure,
                since: stageStart,
                modelCallCount: context.modelCallCount,
                failureCategory: failure.category,
                verificationRepairAttempted: true
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
                    category: .repeatedNoProgressRepair,
                    stage: .postgresVerificationRepair
                )
                trace.append(
                    .postgresVerificationRepair,
                    outcome: .failure,
                    since: stageStart,
                    modelCallCount: generation.generationCallCount,
                    failureCategory: failure.category,
                    verificationRepairAttempted: true
                )
                return RepairRun(decision: .failed(failure), failureCategory: failure.category)
            }
            trace.append(
                .postgresVerificationRepair,
                outcome: .success,
                since: stageStart,
                modelCallCount: generation.generationCallCount,
                verificationRepairAttempted: true
            )
            return RepairRun(decision: .clarification(generation))

        case .rejected(let reason):
            let category = failureCategory(for: reason, evaluation: evaluation)
            trace.append(
                .postgresVerificationRepair,
                outcome: .failure,
                since: stageStart,
                modelCallCount: generation.generationCallCount,
                failureCategory: category,
                verificationRepairAttempted: true
            )
            await record(
                TextToSQLPipelineEvent(
                    kind: .postgresVerificationRepairRejected,
                    stage: .postgresVerificationRepair,
                    title: "PostgreSQL verification repair was rejected.",
                    summary: "Verification repair candidate was rejected.",
                    failureCategory: category
                ),
                request: request,
                events: &events
            )
            let failure = repairFailure(
                attempts: coordinator.attempts,
                category: category,
                stage: .postgresVerificationRepair
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)

        case .accepted:
            break
        }

        guard let repairedSQL = evaluation.sql else {
            let failure = repairFailure(
                attempts: coordinator.attempts,
                category: .modelGeneration,
                stage: .postgresVerificationRepair
            )
            trace.append(
                .postgresVerificationRepair,
                outcome: .failure,
                since: stageStart,
                modelCallCount: generation.generationCallCount,
                failureCategory: failure.category,
                verificationRepairAttempted: true
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)
        }

        let repairedValidation = repairCandidateValidation(
            sql: repairedSQL,
            schema: request.schema,
            fallback: evaluation.validation
        )
        guard repairedValidation.isValid else {
            let category = failureCategory(for: repairedValidation)
            trace.append(
                .postgresVerificationRepair,
                outcome: .failure,
                since: stageStart,
                modelCallCount: generation.generationCallCount,
                failureCategory: category,
                verificationRepairAttempted: true
            )
            await record(
                TextToSQLPipelineEvent(
                    kind: .postgresVerificationRepairRejected,
                    stage: .postgresVerificationRepair,
                    title: "PostgreSQL verification repair was rejected.",
                    summary: "Verification repair candidate violated local experimental limits.",
                    failureCategory: category
                ),
                request: request,
                events: &events
            )
            let failure = TextToSQLPipelineFailure(
                stage: .postgresVerificationRepair,
                category: category,
                message: AppError.validationFailed(repairedValidation.errors).localizedDescription
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)
        }

        let repairedVerification = try await verifyGeneratedSQL(
            sql: repairedSQL,
            validation: repairedValidation,
            request: request,
            trace: &trace,
            stage: .postgresVerificationRepair,
            started: stageStart,
            modelCallCount: generation.generationCallCount,
            repairAttempted: true
        )
        guard repairedVerification.passed || repairedVerification.status.isAcceptableSkip else {
            await record(
                TextToSQLPipelineEvent(
                    kind: .postgresVerificationRepairRejected,
                    stage: .postgresVerificationRepair,
                    title: "PostgreSQL verification repair failed.",
                    summary: repairedVerification.diagnostic?.kind.rawValue
                        ?? repairedVerification.status.rawValue,
                    failureCategory: .postgresVerification
                ),
                request: request,
                events: &events
            )
            let failure = postgresVerificationFailure(
                stage: .postgresVerificationRepair,
                verification: repairedVerification
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)
        }

        await record(
            TextToSQLPipelineEvent(
                kind: .postgresVerificationRepairPassed,
                stage: .postgresVerificationRepair,
                title: "PostgreSQL verification repair passed.",
                summary: "Verification repair produced SQL accepted by PostgreSQL."
            ),
            request: request,
            events: &events
        )
        return RepairRun(decision: .sql(generation.withPipelineSQL(repairedSQL)))
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
        let allowRepairWrites =
            !usesConstrainedLocalPolicy && SQLSafetyValidator.validate(startingSQL).kind.isWrite
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
                after: startingGeneration,
                modelCallBudget: repairModelCallBudget
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
                trace.mergeSchemaToolCalls(generated.schemaToolCalls)
                trace.mergeInspectionToolCalls(generated.inspectionToolCalls)
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
                trace.mergeSchemaToolCalls(schemaToolCalls(from: error))
                trace.mergeInspectionToolCalls(inspectionToolCalls(from: error))
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

            let candidateValidation = repairCandidateValidation(
                sql: generatedSQL,
                schema: request.schema,
                fallback: evaluation.validation
            )
            guard candidateValidation.isValid else {
                let category = failureCategory(for: candidateValidation)
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
                        summary: "Validation repair candidate violated local experimental limits.",
                        failureCategory: category
                    ),
                    request: request,
                    events: &events
                )
                let failure = TextToSQLPipelineFailure(
                    stage: .validationRepair,
                    category: category,
                    message: AppError.validationFailed(candidateValidation.errors)
                        .localizedDescription
                )
                return RepairRun(decision: .failed(failure), failureCategory: failure.category)
            }
            let verification = try await verifyGeneratedSQL(
                sql: generatedSQL,
                validation: candidateValidation,
                request: request,
                trace: &trace,
                stage: .postgresVerification
            )
            if verification.passed || verification.status.isAcceptableSkip {
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

            await record(
                TextToSQLPipelineEvent(
                    kind: .postgresVerificationFailed,
                    stage: .postgresVerification,
                    title: "Repaired SQL failed PostgreSQL verification.",
                    summary: verification.diagnostic?.kind.rawValue
                        ?? verification.status.rawValue,
                    failureCategory: .postgresVerification
                ),
                request: request,
                events: &events
            )
            if verification.isRepairable {
                return try await runPostgresVerificationRepair(
                    request: request,
                    startingGeneration: generation,
                    startingSQL: generatedSQL,
                    verification: verification,
                    trace: &trace,
                    events: &events
                )
            }
            let failure = postgresVerificationFailure(
                stage: .postgresVerification,
                verification: verification
            )
            return RepairRun(decision: .failed(failure), failureCategory: failure.category)
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
        var safety = SQLSafetyValidator.validate(sql)
        let schemaStart = Date()
        var schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)

        if usesConstrainedLocalPolicy {
            ConstrainedLocalSQLPolicy.apply(
                safety: &safety,
                schemaValidation: &schemaValidation
            )
        }

        trace.append(
            .safetyValidation,
            outcome: safety.isValid ? .success : .failure,
            since: safetyStart,
            failureCategory: safety.isValid ? nil : .safetyValidation,
            validationIssueIDs: safety.errors.map {
                redactedIssueID(prefix: "safety", value: $0)
            }
        )

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

    private func repairCandidateValidation(
        sql: String,
        schema: DatabaseSchema,
        fallback: SQLValidationResult?
    ) -> SQLValidationResult {
        guard usesConstrainedLocalPolicy else {
            return fallback ?? GeneratedSQLValidator.validate(sql: sql, schema: schema)
        }
        var safety = SQLSafetyValidator.validate(sql)
        var schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        ConstrainedLocalSQLPolicy.apply(
            safety: &safety,
            schemaValidation: &schemaValidation
        )
        return GeneratedSQLValidator.combine(safety: safety, schemaValidation: schemaValidation)
    }

    private func failureCategory(for validation: SQLValidationResult) -> TextToSQLFailureCategory {
        validation.safetyIssueKinds.contains { $0.isUnsafeExecutionRisk }
            ? .safetyValidation
            : .schemaValidation
    }

    private func postgresVerificationFailure(
        stage: TextToSQLStage,
        verification: SQLVerificationResult
    ) -> TextToSQLPipelineFailure {
        TextToSQLPipelineFailure(
            stage: stage,
            category: .postgresVerification,
            message: verificationFailureMessage(verification),
            databaseDiagnostic: verification.diagnostic,
            verificationStatus: verification.status
        )
    }

    private func verificationFailureMessage(_ verification: SQLVerificationResult) -> String {
        if let diagnostic = verification.diagnostic {
            return "PostgreSQL verification failed: \(diagnostic.displayMessage)"
        }
        if let message = verification.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return "PostgreSQL verification failed: \(message)"
        }
        return "PostgreSQL verification failed."
    }

    private func thrownVerificationFailure(
        from error: any Error,
        since started: Date
    ) -> SQLVerificationResult {
        if let appError = error as? AppError,
            case .databaseFailed(let diagnostic) = appError
        {
            return .failed(
                diagnostic: diagnostic,
                elapsedMs: elapsedMilliseconds(since: started),
                stage: .transaction,
                message: diagnostic.displayMessage
            )
        }
        return .failed(
            diagnostic: nil,
            elapsedMs: elapsedMilliseconds(since: started),
            stage: .transaction,
            message: error.localizedDescription
        )
    }

    private func generationFailure(
        _ error: any Error,
        stage: TextToSQLStage
    ) -> TextToSQLPipelineFailure {
        if let failure = SQLGenerationFailure.typed(error) {
            let openRouterDiagnostic: OpenRouterFailureDiagnostic?
            let backendMetadata: OpenRouterGenerationMetadata?
            if case .openRouter(let openRouterFailure) = failure {
                openRouterDiagnostic = openRouterFailure.diagnostic
                backendMetadata = nil
            } else if case .schemaToolAgent(let agentFailure) = failure,
                let openRouterFailure = agentFailure.openRouterFailure
            {
                openRouterDiagnostic = openRouterFailure.diagnostic
                backendMetadata = agentFailure.backendMetadata
            } else if case .schemaToolAgent(let agentFailure) = failure {
                openRouterDiagnostic = nil
                backendMetadata = agentFailure.backendMetadata
            } else {
                openRouterDiagnostic = nil
                backendMetadata = nil
            }
            return TextToSQLPipelineFailure(
                stage: stage,
                category: failure.pipelineCategory,
                message: failure.localizedDescription,
                openRouterFailure: openRouterDiagnostic,
                backendMetadata: backendMetadata
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
        category: TextToSQLFailureCategory,
        stage: TextToSQLStage = .validationRepair
    ) -> TextToSQLPipelineFailure {
        TextToSQLPipelineFailure(
            stage: stage,
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
                elapsedMs: elapsedMilliseconds(since: started),
                schemaToolCalls: trace.schemaToolCalls,
                inspectionToolCalls: trace.inspectionToolCalls
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
    var schemaToolCalls: [SchemaToolCallTrace] = []
    var inspectionToolCalls: [DatabaseInspectionToolCallTrace] = []

    init(schema: DatabaseSchema) {
        self.schemaFingerprint = Self.fingerprint(schema)
    }

    mutating func append(
        _ stage: TextToSQLStage,
        outcome: TextToSQLStageOutcome,
        since started: Date,
        elapsedMs: Int? = nil,
        modelCallCount: Int? = nil,
        failureCategory: TextToSQLFailureCategory? = nil,
        validationIssueIDs: [String] = [],
        canonicalizationFixes: [String] = [],
        selectedTableNames: [String] = [],
        verificationStatus: SQLVerificationStatus? = nil,
        sqlState: String? = nil,
        databaseDiagnosticKind: DatabaseDiagnosticKind? = nil,
        verificationRepairAttempted: Bool? = nil
    ) {
        stages.append(
            TextToSQLStageResult(
                stage: stage,
                outcome: outcome,
                elapsedMs: elapsedMs ?? elapsedMilliseconds(since: started),
                modelCallCount: modelCallCount,
                failureCategory: failureCategory,
                validationIssueIDs: validationIssueIDs,
                canonicalizationFixes: canonicalizationFixes,
                selectedTableNames: selectedTableNames,
                schemaFingerprint: schemaFingerprint,
                verificationStatus: verificationStatus,
                sqlState: sqlState,
                databaseDiagnosticKind: databaseDiagnosticKind,
                verificationRepairAttempted: verificationRepairAttempted
            )
        )
    }

    mutating func mergeSchemaToolCalls(_ traces: [SchemaToolCallTrace]) {
        guard !traces.isEmpty else { return }
        schemaToolCalls.append(contentsOf: traces)
    }

    mutating func mergeInspectionToolCalls(_ traces: [DatabaseInspectionToolCallTrace]) {
        guard !traces.isEmpty else { return }
        inspectionToolCalls.append(contentsOf: traces)
    }

    mutating func appendVerification(
        _ stage: TextToSQLStage,
        result: SQLVerificationResult,
        outcome: TextToSQLStageOutcome,
        since started: Date,
        modelCallCount: Int? = nil,
        repairAttempted: Bool? = nil
    ) {
        append(
            stage,
            outcome: outcome,
            since: started,
            elapsedMs: result.elapsedMs,
            modelCallCount: modelCallCount,
            failureCategory: outcome == .failure ? .postgresVerification : nil,
            verificationStatus: result.status,
            sqlState: result.diagnostic?.sqlState,
            databaseDiagnosticKind: result.diagnostic?.kind,
            verificationRepairAttempted: repairAttempted
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

private func schemaToolCalls(from error: any Error) -> [SchemaToolCallTrace] {
    if let failure = error as? OpenRouterSchemaToolAgentFailure {
        return failure.schemaToolCalls
    }
    if case .schemaToolAgent(let failure)? = SQLGenerationFailure.typed(error) {
        return failure.schemaToolCalls
    }
    return []
}

private func inspectionToolCalls(from error: any Error) -> [DatabaseInspectionToolCallTrace] {
    if let failure = error as? OpenRouterSchemaToolAgentFailure {
        return failure.inspectionToolCalls
    }
    if case .schemaToolAgent(let failure)? = SQLGenerationFailure.typed(error) {
        return failure.inspectionToolCalls
    }
    return []
}

enum ConstrainedLocalSQLPolicy {
    private static let maxBaseTables = 3
    private static let maxCTEs = 2

    static func apply(
        safety: inout SQLValidationResult,
        schemaValidation: inout SQLSchemaValidationResult
    ) {
        if safety.kind.isWrite {
            safety.isValid = false
            safety.errors.append(
                "On-device experimental mode only supports SELECT queries. Use Cloud or write SQL manually for data changes."
            )
            safety.safetyIssueKinds.append(.unsupportedStatement)
        }

        if schemaValidation.referencedTables.count > maxBaseTables {
            schemaValidation.issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message:
                        "On-device experimental mode supports at most \(maxBaseTables) base tables. This query references \(schemaValidation.referencedTables.count). Use Cloud for broader requests.",
                    kind: .other
                )
            )
        }

        if schemaValidation.analysis.cteNames.count > maxCTEs {
            schemaValidation.issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message:
                        "On-device experimental mode supports simple CTEs only. Use Cloud for deeply nested or multi-step SQL.",
                    kind: .other
                )
            )
        }
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

private extension SQLVerificationStatus {
    var isAcceptableSkip: Bool {
        switch self {
        case .notAvailable, .skippedNoConnection, .skippedNonRead:
            return true
        case .skippedStaticValidationFailed, .passed, .failed:
            return false
        }
    }
}

private extension SQLVerificationResult {
    var isRepairable: Bool {
        guard status == .failed, let diagnostic else { return false }
        switch diagnostic.kind {
        case .missingRelation, .missingColumn, .ambiguousColumn, .syntaxError,
            .groupingError, .datatypeMismatch, .undefinedFunction,
            .invalidTextRepresentation:
            return true
        case .insufficientPrivilege, .timedOut, .cancelled, .other:
            return false
        }
    }
}
