import Foundation

public struct TextToSQLEvalRunOptions: Sendable {
    public var backend: TextToSQLEvalBackend
    public var model: String?
    public var repeatIndex: Int
    public var defaultRowLimit: Int
    public var estimatedInitialPromptCharacters: Int?
    public var estimatedInitialPrompt: String?
    public var testOnlyDisableGroundingClarification: Bool
    public var caseTimeoutSeconds: Double?
    public var sqlVerifier: (any GeneratedSQLVerifying)?
    public var verificationConnection: PostgresConnectionHandle?

    public init(
        backend: TextToSQLEvalBackend,
        model: String? = nil,
        repeatIndex: Int = 1,
        defaultRowLimit: Int = 100,
        estimatedInitialPromptCharacters: Int? = nil,
        estimatedInitialPrompt: String? = nil,
        testOnlyDisableGroundingClarification: Bool = false,
        caseTimeoutSeconds: Double? = nil,
        sqlVerifier: (any GeneratedSQLVerifying)? = nil,
        verificationConnection: PostgresConnectionHandle? = nil
    ) {
        self.backend = backend
        self.model = model
        self.repeatIndex = repeatIndex
        self.defaultRowLimit = defaultRowLimit
        self.estimatedInitialPromptCharacters = estimatedInitialPromptCharacters
        self.estimatedInitialPrompt = estimatedInitialPrompt
        self.testOnlyDisableGroundingClarification = testOnlyDisableGroundingClarification
        self.caseTimeoutSeconds = caseTimeoutSeconds
        self.sqlVerifier = sqlVerifier
        self.verificationConnection = verificationConnection
    }
}

public enum TextToSQLEvalCaseRunner {
    private final class TimeoutCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        private var wasCancelled = false

        func set(_ handler: @escaping @Sendable () -> Void) {
            let shouldCancel: Bool
            lock.lock()
            self.handler = handler
            shouldCancel = wasCancelled
            lock.unlock()

            if shouldCancel { handler() }
        }

        func cancel() {
            let handler: (@Sendable () -> Void)?
            lock.lock()
            wasCancelled = true
            handler = self.handler
            lock.unlock()

            handler?()
        }
    }

    private final class TimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<TextToSQLEvalResult, Never>?
        private var pipelineTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var cancelPipelineWhenSet = false
        private var cancelTimeoutWhenSet = false

        init(continuation: CheckedContinuation<TextToSQLEvalResult, Never>) {
            self.continuation = continuation
        }

        func setTasks(pipelineTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            let shouldCancelPipeline: Bool
            let shouldCancelTimeout: Bool
            lock.lock()
            if !finished {
                self.pipelineTask = pipelineTask
                self.timeoutTask = timeoutTask
            }
            shouldCancelPipeline = cancelPipelineWhenSet
            shouldCancelTimeout = cancelTimeoutWhenSet
            lock.unlock()

            if shouldCancelPipeline { pipelineTask.cancel() }
            if shouldCancelTimeout { timeoutTask.cancel() }
        }

        func finish(
            _ result: TextToSQLEvalResult,
            cancelPipeline: Bool,
            cancelTimeout: Bool
        ) {
            let continuation: CheckedContinuation<TextToSQLEvalResult, Never>?
            let pipelineTask: Task<Void, Never>?
            let timeoutTask: Task<Void, Never>?

            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            continuation = self.continuation
            self.continuation = nil
            pipelineTask = self.pipelineTask
            timeoutTask = self.timeoutTask
            self.pipelineTask = nil
            self.timeoutTask = nil
            if cancelPipeline, pipelineTask == nil {
                cancelPipelineWhenSet = true
            }
            if cancelTimeout, timeoutTask == nil {
                cancelTimeoutWhenSet = true
            }
            lock.unlock()

            if cancelPipeline { pipelineTask?.cancel() }
            if cancelTimeout { timeoutTask?.cancel() }
            continuation?.resume(returning: result)
        }
    }

    public static func run(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generator: any SQLGenerator,
        options: TextToSQLEvalRunOptions
    ) async -> TextToSQLEvalResult {
        guard let caseTimeoutSeconds = options.caseTimeoutSeconds else {
            return await runPipeline(
                evalCase: evalCase,
                schema: schema,
                generator: generator,
                options: options,
                started: Date()
            )
        }
        return await runWithTimeout(
            evalCase: evalCase,
            schema: schema,
            generator: generator,
            options: options,
            timeoutSeconds: caseTimeoutSeconds
        )
    }

    private static func runWithTimeout(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generator: any SQLGenerator,
        options: TextToSQLEvalRunOptions,
        timeoutSeconds: Double
    ) async -> TextToSQLEvalResult {
        let started = Date()
        let timeoutDuration = timeoutDuration(for: timeoutSeconds)
        let cancellation = TimeoutCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let race = TimeoutRace(continuation: continuation)
                let pipelineTask = Task {
                    let result = await runPipeline(
                        evalCase: evalCase,
                        schema: schema,
                        generator: generator,
                        options: options,
                        started: started
                    )
                    race.finish(result, cancelPipeline: false, cancelTimeout: true)
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutDuration.nanoseconds)
                    } catch {
                        race.finish(
                            cancellationResult(
                                evalCase: evalCase,
                                options: options,
                                latencyMs: elapsedMilliseconds(since: started)
                            ),
                            cancelPipeline: true,
                            cancelTimeout: false
                        )
                        return
                    }
                    race.finish(
                        timeoutResult(
                            evalCase: evalCase,
                            options: options,
                            timeoutSeconds: timeoutDuration.seconds,
                            latencyMs: elapsedMilliseconds(since: started)
                        ),
                        cancelPipeline: true,
                        cancelTimeout: false
                    )
                }
                race.setTasks(pipelineTask: pipelineTask, timeoutTask: timeoutTask)
                cancellation.set {
                    race.finish(
                        cancellationResult(
                            evalCase: evalCase,
                            options: options,
                            latencyMs: elapsedMilliseconds(since: started)
                        ),
                        cancelPipeline: true,
                        cancelTimeout: true
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func timeoutDuration(for timeoutSeconds: Double) -> (
        seconds: Double, nanoseconds: UInt64
    ) {
        let seconds = timeoutSeconds.isFinite && timeoutSeconds > 0 ? timeoutSeconds : 120
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return (seconds, UInt64.max)
        }
        return (seconds, UInt64(max(1.0, nanoseconds)))
    }

    private static func runPipeline(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generator: any SQLGenerator,
        options: TextToSQLEvalRunOptions,
        started: Date
    ) async -> TextToSQLEvalResult {
        do {
            let run = try await TextToSQLPipeline(generator: generator).run(
                TextToSQLRequest(
                    question: evalCase.question,
                    schema: schema,
                    config: SQLGenerationConfig(
                        defaultRowLimit: options.defaultRowLimit,
                        databaseContext: evalCase.databaseContext ?? ""
                    ),
                    allowGroundingClarification: !options.testOnlyDisableGroundingClarification,
                    sqlVerifier: options.sqlVerifier,
                    verificationConnection: options.verificationConnection
                )
            )
            switch run.finalDecision {
            case .sql(let generation), .clarification(let generation):
                return TextToSQLEvalScorer.score(
                    evalCase: evalCase,
                    schema: schema,
                    generation: generation,
                    options: options,
                    latencyMs: elapsedMilliseconds(since: started),
                    trace: run.trace
                )
            case .failed(let failure):
                return pipelineFailureResult(
                    evalCase: evalCase,
                    options: options,
                    failure: failure,
                    latencyMs: elapsedMilliseconds(since: started),
                    trace: run.trace
                )
            }
        } catch is CancellationError {
            return cancellationResult(
                evalCase: evalCase,
                options: options,
                latencyMs: elapsedMilliseconds(since: started)
            )
        } catch {
            return failureResult(
                evalCase: evalCase,
                options: options,
                error: error,
                latencyMs: elapsedMilliseconds(since: started)
            )
        }
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    private static func timeoutResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        timeoutSeconds: Double,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: .evalTimeout,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: true,
                structuredResponseParsed: false,
                decisionMatches: false,
                latencyMs: latencyMs,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
            ),
            diagnostics: TextToSQLEvalDiagnostics(
                errorMessage:
                    "Eval case \(evalCase.id) timed out after \(timeoutSeconds) seconds."
            ),
            estimatedInitialPrompt: options.estimatedInitialPrompt
        )
    }

    private static func cancellationResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: .generationFailure,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: true,
                structuredResponseParsed: false,
                decisionMatches: false,
                latencyMs: latencyMs,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters
            ),
            diagnostics: TextToSQLEvalDiagnostics(
                errorMessage: "Eval case \(evalCase.id) was cancelled."
            ),
            estimatedInitialPrompt: options.estimatedInitialPrompt
        )
    }

    private static func failureResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        error: any Error,
        latencyMs: Int
    ) -> TextToSQLEvalResult {
        let typed = SQLGenerationFailure.typed(error)
        let status = typed.map(status(for:)) ?? .transportFailure
        let backendAvailable = typed.map { $0.pipelineCategory != .backendUnavailable } ?? true
        let transportSuccess = typed.map {
            $0.pipelineCategory != .transport
                && $0.pipelineCategory != .backendUnavailable
        } ?? false
        let openRouterDiagnostic: OpenRouterFailureDiagnostic?
        if let typed, case .openRouter(let failure) = typed {
            openRouterDiagnostic = failure.diagnostic
        } else {
            openRouterDiagnostic = nil
        }
        let structuredParsed = false
        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: backendAvailable,
                transportSuccess: transportSuccess,
                structuredResponseParsed: structuredParsed,
                decisionMatches: false,
                latencyMs: latencyMs,
                modelCallCount: openRouterDiagnostic?.attemptCount,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                openRouterRetryCount: openRouterDiagnostic.map { max(0, $0.attemptCount - 1) },
                openRouterRequestedModelID: openRouterDiagnostic?.requestedModelID,
                openRouterReturnedModelID: openRouterDiagnostic?.returnedModelID,
                openRouterProviderName: openRouterDiagnostic?.providerName
            ),
            diagnostics: TextToSQLEvalDiagnostics(
                errorMessage: error.localizedDescription,
                openRouterFailure: openRouterDiagnostic
            ),
            estimatedInitialPrompt: options.estimatedInitialPrompt
        )
    }

    private static func pipelineFailureResult(
        evalCase: TextToSQLEvalCase,
        options: TextToSQLEvalRunOptions,
        failure: TextToSQLPipelineFailure,
        latencyMs: Int,
        trace: TextToSQLTrace
    ) -> TextToSQLEvalResult {
        let backendMetadata = failure.backendMetadata
        let verificationSnapshot = TextToSQLEvalScorer.postgresVerificationSnapshot(from: trace)
        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status(for: failure.category),
            metrics: TextToSQLEvalMetrics(
                backendAvailable: failure.category != .backendUnavailable,
                transportSuccess: failure.category != .transport
                    && failure.category != .backendUnavailable,
                structuredResponseParsed: structuredResponseParsed(for: failure.category),
                decisionMatches: false,
                safetyValid: failure.category == .safetyValidation
                    ? false
                    : failure.category == .postgresVerification ? true : nil,
                schemaValid: (
                    failure.category == .schemaValidation
                        || failure.category == .repeatedNoProgressRepair
                )
                    ? false
                    : failure.category == .postgresVerification ? true : nil,
                latencyMs: latencyMs,
                modelCallCount: failureModelCallCount(
                    trace: trace,
                    openRouterFailure: failure.openRouterFailure,
                    backendMetadata: backendMetadata
                ),
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                tokenUsage: backendMetadata?.totalTokens,
                estimatedCloudCostUSD: backendMetadata?.costUSD,
                openRouterStructuredOutputMode: backendMetadata?.structuredOutputMode.rawValue,
                openRouterRetryCount: backendMetadata?.retryCount
                    ?? failure.openRouterFailure.map { max(0, $0.attemptCount - 1) },
                openRouterRequestedModelID: backendMetadata?.requestedModelID
                    ?? failure.openRouterFailure?.requestedModelID,
                openRouterReturnedModelID: backendMetadata?.returnedModelID
                    ?? failure.openRouterFailure?.returnedModelID,
                openRouterProviderName: backendMetadata?.providerName
                    ?? failure.openRouterFailure?.providerName
            ).withOpenRouterAgentMetadata(backendMetadata, trace: trace)
                .withPostgresVerification(verificationSnapshot),
            diagnostics: TextToSQLEvalDiagnostics(
                errorMessage: failure.localizedDescription,
                openRouterFailure: failure.openRouterFailure,
                postgresVerificationDiagnostic: failure.databaseDiagnostic
            ),
            estimatedInitialPrompt: options.estimatedInitialPrompt,
            trace: trace
        )
    }

    private static func failureModelCallCount(
        trace: TextToSQLTrace,
        openRouterFailure: OpenRouterFailureDiagnostic?,
        backendMetadata: OpenRouterGenerationMetadata? = nil
    ) -> Int? {
        if let agentAttemptCount = backendMetadata?.agentHTTPAttemptCount ?? backendMetadata?.requestCount {
            guard trace.modelCalls > 0 else { return agentAttemptCount }
            return trace.modelCalls + max(0, agentAttemptCount - 1)
        }
        guard let attemptCount = openRouterFailure?.attemptCount else {
            return trace.modelCalls == 0 ? nil : trace.modelCalls
        }
        guard trace.modelCalls > 0 else { return attemptCount }
        return trace.modelCalls + max(0, attemptCount - 1)
    }

    private static func status(for failure: SQLGenerationFailure) -> TextToSQLEvalCaseStatus {
        status(for: failure.pipelineCategory)
    }

    private static func status(for category: TextToSQLFailureCategory) -> TextToSQLEvalCaseStatus {
        switch category {
        case .backendUnavailable:
            .backendUnavailable
        case .transport:
            .transportFailure
        case .contextWindow:
            .contextWindowFailure
        case .structuredResponseParsing:
            .parseFailure
        case .modelGeneration, .cancellation, .emptySQL:
            .generationFailure
        case .safetyValidation, .postgresVerification:
            .invalidSQL
        case .schemaValidation, .repeatedNoProgressRepair:
            .wrongSchemaObjects
        }
    }

    private static func structuredResponseParsed(for category: TextToSQLFailureCategory) -> Bool {
        switch category {
        case .safetyValidation, .schemaValidation, .postgresVerification,
            .repeatedNoProgressRepair, .emptySQL:
            true
        case .backendUnavailable, .transport, .contextWindow, .structuredResponseParsing,
            .modelGeneration, .cancellation:
            false
        }
    }
}

public enum TextToSQLEvalScorer {
    public static func score(
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema,
        generation: SQLGenerationResult,
        options: TextToSQLEvalRunOptions,
        latencyMs: Int,
        trace: TextToSQLTrace? = nil
    ) -> TextToSQLEvalResult {
        let expected = evalCase.expected
        let actualDecision: TextToSQLEvalDecision =
            generation.needsClarification ? .clarify : .sql
        let decisionMatches = actualDecision == expected.decision
        let modelCallCount = trace?.modelCalls == 0
            ? generation.generationCallCount
            : (trace?.modelCalls ?? generation.generationCallCount)
        let backendMetadata = generation.backendMetadata
        let verificationSnapshot = postgresVerificationSnapshot(from: trace)

        if expected.decision == .clarify {
            let quality = clarificationQuality(
                generation.clarificationQuestion,
                mustMentionAny: expected.clarificationMustMentionAny
            )
            let status: TextToSQLEvalCaseStatus = decisionMatches && quality ? .passed : .wrongDecision
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: status,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: decisionMatches,
                    clarificationQuality: quality,
                    latencyMs: latencyMs,
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                    tokenUsage: backendMetadata?.totalTokens,
                    estimatedCloudCostUSD: backendMetadata?.costUSD,
                    openRouterStructuredOutputMode: backendMetadata?.structuredOutputMode.rawValue,
                    openRouterRetryCount: backendMetadata?.retryCount,
                    openRouterRequestedModelID: backendMetadata?.requestedModelID,
                    openRouterReturnedModelID: backendMetadata?.returnedModelID,
                    openRouterProviderName: backendMetadata?.providerName
                ).withOpenRouterAgentMetadata(backendMetadata, trace: trace)
                    .withPostgresVerification(verificationSnapshot),
                diagnostics: TextToSQLEvalDiagnostics(),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
            )
        }

        guard decisionMatches else {
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: .wrongDecision,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: false,
                    clarificationQuality: clarificationQuality(
                        generation.clarificationQuestion,
                        mustMentionAny: expected.clarificationMustMentionAny
                    ),
                    latencyMs: latencyMs,
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                    tokenUsage: backendMetadata?.totalTokens,
                    estimatedCloudCostUSD: backendMetadata?.costUSD,
                    openRouterStructuredOutputMode: backendMetadata?.structuredOutputMode.rawValue,
                    openRouterRetryCount: backendMetadata?.retryCount,
                    openRouterRequestedModelID: backendMetadata?.requestedModelID,
                    openRouterReturnedModelID: backendMetadata?.returnedModelID,
                    openRouterProviderName: backendMetadata?.providerName
                ).withOpenRouterAgentMetadata(backendMetadata, trace: trace)
                    .withPostgresVerification(verificationSnapshot),
                generatedSQL: generation.sql.nilIfBlank,
                clarificationQuestion: generation.clarificationQuestion,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
            )
        }

        let safety = SQLSafetyValidator.validate(generation.sql)
        guard safety.isValid else {
            return TextToSQLEvalResult(
                caseID: evalCase.id,
                backend: options.backend,
                model: options.model,
                repeatIndex: options.repeatIndex,
                status: .invalidSQL,
                metrics: TextToSQLEvalMetrics(
                    backendAvailable: true,
                    transportSuccess: true,
                    structuredResponseParsed: true,
                    decisionMatches: true,
                    safetyValid: false,
                    schemaValid: nil,
                    latencyMs: latencyMs,
                    modelCallCount: modelCallCount,
                    estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                    tokenUsage: backendMetadata?.totalTokens,
                    estimatedCloudCostUSD: backendMetadata?.costUSD,
                    openRouterStructuredOutputMode: backendMetadata?.structuredOutputMode.rawValue,
                    openRouterRetryCount: backendMetadata?.retryCount,
                    openRouterRequestedModelID: backendMetadata?.requestedModelID,
                    openRouterReturnedModelID: backendMetadata?.returnedModelID,
                    openRouterProviderName: backendMetadata?.providerName
                ).withOpenRouterAgentMetadata(backendMetadata, trace: trace)
                    .withPostgresVerification(verificationSnapshot),
                diagnostics: TextToSQLEvalDiagnostics(safetyErrors: safety.errors),
                generatedSQL: generation.sql.nilIfBlank,
                referencedTables: generation.referencedTables,
                estimatedInitialPrompt: options.estimatedInitialPrompt,
                trace: trace
            )
        }

        let schemaValidation = SQLSchemaValidator.validate(sql: generation.sql, against: schema)
        let referencedTables = Set(schemaValidation.referencedTables.map(normalizeBinding))
        let missingTables = expected.requiredTables.filter {
            !referencedTables.contains(normalizeBinding($0))
        }
        let referencedColumnBindings = referencedColumns(in: generation.sql, schema: schema)
        let referencedColumnSet = Set(referencedColumnBindings.map(normalizeBinding))
        let missingColumnBindings = expected.requiredColumnBindings.filter {
            !referencedColumnSet.contains(normalizeBinding($0))
        }
        let forbiddenBindingViolations = expected.forbiddenColumnBindings.filter {
            referencedColumnSet.contains(normalizeBinding($0))
        }
        let operations = detectedOperations(in: generation.sql)
        let missingOperations = missingOperations(
            for: expected,
            detected: operations,
            sql: generation.sql,
            schema: schema
        )

        let tableCoverage = coverage(
            total: expected.requiredTables.count,
            missing: missingTables.count
        )
        let columnCoverage = coverage(
            total: expected.requiredColumnBindings.count,
            missing: missingColumnBindings.count
        )
        let schemaValid = !schemaValidation.hasDefiniteErrors
        let status: TextToSQLEvalCaseStatus
        if !schemaValid {
            status = .wrongSchemaObjects
        } else if missingTables.isEmpty,
            missingColumnBindings.isEmpty,
            forbiddenBindingViolations.isEmpty,
            missingOperations.isEmpty
        {
            status = .passed
        } else {
            status = .wrongSchemaObjects
        }

        return TextToSQLEvalResult(
            caseID: evalCase.id,
            backend: options.backend,
            model: options.model,
            repeatIndex: options.repeatIndex,
            status: status,
            metrics: TextToSQLEvalMetrics(
                backendAvailable: true,
                transportSuccess: true,
                structuredResponseParsed: true,
                decisionMatches: true,
                safetyValid: true,
                schemaValid: schemaValid,
                requiredTableCoverage: tableCoverage,
                requiredColumnBindingCoverage: columnCoverage,
                forbiddenBindingViolations: forbiddenBindingViolations,
                latencyMs: latencyMs,
                modelCallCount: modelCallCount,
                estimatedInitialPromptCharacters: options.estimatedInitialPromptCharacters,
                tokenUsage: backendMetadata?.totalTokens,
                estimatedCloudCostUSD: backendMetadata?.costUSD,
                openRouterStructuredOutputMode: backendMetadata?.structuredOutputMode.rawValue,
                openRouterRetryCount: backendMetadata?.retryCount,
                openRouterRequestedModelID: backendMetadata?.requestedModelID,
                openRouterReturnedModelID: backendMetadata?.returnedModelID,
                openRouterProviderName: backendMetadata?.providerName
            ).withOpenRouterAgentMetadata(backendMetadata, trace: trace)
                    .withPostgresVerification(verificationSnapshot),
            diagnostics: TextToSQLEvalDiagnostics(
                missingTables: missingTables,
                missingColumnBindings: missingColumnBindings,
                missingOperations: missingOperations,
                schemaErrors: schemaValidation.errors
            ),
            generatedSQL: generation.sql.nilIfBlank,
            clarificationQuestion: generation.clarificationQuestion,
            referencedTables: schemaValidation.referencedTables,
            referencedColumnBindings: referencedColumnBindings,
            estimatedInitialPrompt: options.estimatedInitialPrompt,
            trace: trace
        )
    }

    fileprivate static func postgresVerificationSnapshot(
        from trace: TextToSQLTrace?
    ) -> EvalPostgresVerificationSnapshot? {
        let stages = trace?.stages.filter { $0.verificationStatus != nil } ?? []
        guard let final = stages.last, let status = final.verificationStatus else { return nil }
        return EvalPostgresVerificationSnapshot(
            status: status,
            sqlState: final.sqlState,
            diagnosticKind: final.databaseDiagnosticKind,
            elapsedMs: final.elapsedMs,
            repairAttempted: stages.contains {
                $0.verificationRepairAttempted == true
                    || $0.stage == .postgresVerificationRepair
            }
        )
    }

    private static func coverage(total: Int, missing: Int) -> Double {
        guard total > 0 else { return 1 }
        return Double(total - missing) / Double(total)
    }

    private static func clarificationQuality(
        _ value: String?,
        mustMentionAny configuredConcepts: [String]
    ) -> Bool {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return false }
        let candidateTokens = Set(normalizedTokens(in: text))
        guard !candidateTokens.isEmpty else { return false }
        let mentionsExpectedConcept = configuredConcepts.contains { concept in
            let conceptTokens = normalizedTokens(in: concept)
            return !conceptTokens.isEmpty && conceptTokens.contains { candidateTokens.contains($0) }
        }
        guard mentionsExpectedConcept else { return false }
        return !candidateTokens.isDisjoint(with: databaseDecisionTokens)
            || containsSchemaIdentifierEvidence(text, candidateTokens: candidateTokens)
            || containsBusinessMetricAlternative(candidateTokens, configuredConcepts: configuredConcepts)
    }

    private static let databaseDecisionTokens: Set<String> = [
        "metric", "measure", "performance", "definition", "define", "count", "counting",
        "sum", "average", "relationship", "join", "path", "status", "filter", "value",
        "time", "date", "field", "column", "table", "event", "occurrence", "row",
        "rows", "window", "priority", "impact", "frequency", "usage", "null", "nonnull",
    ]

    private static func containsSchemaIdentifierEvidence(
        _ value: String,
        candidateTokens: Set<String>
    ) -> Bool {
        guard !candidateTokens.isDisjoint(with: schemaIdentifierDecisionTokens) else { return false }
        if value.range(
            of: #"\b[a-z][a-z0-9]*_[a-z0-9_]*\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        let qualifiedIdentifierPattern = #"\b[a-z][a-z0-9]*\.[a-z][a-z0-9_]*\b"#
        return value.range(
            of: qualifiedIdentifierPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static let schemaIdentifierDecisionTokens: Set<String> = [
        "should", "use", "uses", "using", "define", "defines", "count", "counting",
        "where", "whether", "which", "null", "nonnull", "non", "status", "filter",
        "relationship", "join", "path", "field", "column",
    ]

    private static func containsBusinessMetricAlternative(
        _ candidateTokens: Set<String>,
        configuredConcepts: [String]
    ) -> Bool {
        let configuredTokens = Set(configuredConcepts.flatMap { normalizedTokens(in: $0) })
        let matched = candidateTokens.intersection(configuredTokens)
        guard matched.count >= 2 else { return false }
        return !candidateTokens.isDisjoint(with: ["mean", "means", "or", "should"])
    }

    private static func normalizedTokens(in value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func detectedOperations(in sql: String) -> Set<TextToSQLEvalOperation> {
        let lower = sql.lowercased()
        var result = Set<TextToSQLEvalOperation>()
        if matches(#"\bcount\s*\("#, in: lower) {
            result.insert(.count)
        }
        if matches(#"\bavg\s*\("#, in: lower) {
            result.insert(.average)
        }
        if matches(#"\bsum\s*\("#, in: lower) {
            result.insert(.sum)
        }
        if matches(#"\bgroup\s+by\b"#, in: lower) {
            result.insert(.group)
        }
        if matches(#"\bjoin\b"#, in: lower) {
            result.insert(.join)
        }
        if matches(#"\bleft\s+(outer\s+)?join\b"#, in: lower) {
            result.insert(.leftJoin)
            result.insert(.join)
        }
        if matches(#"\bnot\s+exists\b"#, in: lower) {
            result.insert(.notExists)
        }
        if matches(#"\bis\s+null\b"#, in: lower) {
            result.insert(.nullFilter)
        }
        if matches(#"\border\s+by\b"#, in: lower), matches(#"\bdesc\b"#, in: lower) {
            result.insert(.descendingOrder)
        }
        if matches(#"\blimit\s+\d+\b"#, in: lower)
            || matches(#"\bfetch\s+(first|next)(\s+\d+)?\s+rows?\s+only\b"#, in: lower)
        {
            result.insert(.limit)
        }
        if matches(#"\binterval\b"#, in: lower)
            || matches(#"\bcurrent_date\b"#, in: lower)
            || matches(#"\bcurrent_timestamp\b"#, in: lower)
            || lower.contains("now()")
        {
            result.insert(.relativeTimeFilter)
        }
        return result
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func missingOperations(
        for expected: TextToSQLEvalExpectation,
        detected operations: Set<TextToSQLEvalOperation>,
        sql: String,
        schema: DatabaseSchema
    ) -> [TextToSQLEvalOperation] {
        expected.requiredOperations.filter {
            !operationSatisfied(
                $0,
                expected: expected,
                detected: operations,
                sql: sql,
                schema: schema
            )
        }
    }

    private static func operationSatisfied(
        _ operation: TextToSQLEvalOperation,
        expected: TextToSQLEvalExpectation,
        detected operations: Set<TextToSQLEvalOperation>,
        sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let expectsAntiJoin =
            expected.requiredOperations.contains(.leftJoin)
            && expected.requiredOperations.contains(.nullFilter)
        if expectsAntiJoin, operations.contains(.notExists) {
            if operation == .leftJoin || operation == .nullFilter {
                return true
            }
        }

        if operation == .nullFilter,
            expected.requiredOperations.contains(.leftJoin),
            operations.contains(.leftJoin)
        {
            return nullFilterTargetsLeftJoinedRelation(in: sql, schema: schema)
        }

        return operations.contains(operation)
    }

    private static func nullFilterTargetsLeftJoinedRelation(
        in sql: String,
        schema: DatabaseSchema
    ) -> Bool {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let leftJoinedTables = leftJoinedTableKeys(analysis: analysis, sql: sql, schema: schema)
        guard !leftJoinedTables.isEmpty else { return false }

        let relationAliases = relationAliasMap(analysis: analysis, schema: schema)
        let referencedTables = SQLSchemaValidator.validate(sql: sql, against: schema)
            .referencedTables
        let referencedTableInfos = schema.tables.filter { table in
            referencedTables.contains(table.qualifiedName)
        }

        return analysis.columns.contains { column in
            columnIsNullFiltered(column, in: sql)
                && resolvedTables(
                    for: column,
                    relationAliases: relationAliases,
                    referencedTables: referencedTableInfos
                )
                .contains {
                    leftJoinedTables.contains(normalizeBinding($0.qualifiedName))
                }
        }
    }

    private static func leftJoinedTableKeys(
        analysis: SQLReferenceAnalysis,
        sql: String,
        schema: DatabaseSchema
    ) -> Set<String> {
        var keys = Set<String>()
        for relation in analysis.relations where !relation.isDerived {
            guard let offset = relation.startOffset,
                relationHasLeftJoinPrefix(offset: offset, in: sql),
                let table = table(for: relation, in: schema)
            else { continue }
            keys.insert(normalizeBinding(table.qualifiedName))
        }
        return keys
    }

    private static func relationHasLeftJoinPrefix(offset: Int, in sql: String) -> Bool {
        let characters = Array(sql)
        guard offset >= 0, offset <= characters.count else { return false }
        let lowerBound = max(0, offset - 80)
        let prefix = String(characters[lowerBound..<offset])
        return matches(#"(?is)\bleft\s+(outer\s+)?join\s*$"#, in: prefix)
    }

    private static func columnIsNullFiltered(_ column: SQLColumnReference, in sql: String) -> Bool {
        guard let endOffset = column.endOffset else { return false }
        let characters = Array(sql)
        guard endOffset >= 0, endOffset <= characters.count else { return false }
        let lookaheadEnd = min(characters.count, endOffset + 32)
        let suffix = String(characters[endOffset..<lookaheadEnd])
        return matches(#"(?is)^\s+is\s+null\b"#, in: suffix)
    }

    private static func resolvedTables(
        for column: SQLColumnReference,
        relationAliases: [String: TableInfo],
        referencedTables: [TableInfo]
    ) -> [TableInfo] {
        if let qualifier = column.qualifier,
            let table = relationAliases[normalizeBinding(qualifier)]
        {
            return [table]
        }
        if let qualifier = column.qualifier,
            let table = tableMatchingQualifier(qualifier, in: referencedTables)
        {
            return [table]
        }
        guard column.qualifier == nil else { return [] }
        let matches = referencedTables.filter {
            columnNamed(column.name, isQuoted: column.isQuoted, existsIn: $0)
        }
        return matches.count == 1 ? matches : []
    }

    private static func referencedColumns(in sql: String, schema: DatabaseSchema) -> [String] {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let relationAliases = relationAliasMap(analysis: analysis, schema: schema)
        let referencedTables = SQLSchemaValidator.validate(sql: sql, against: schema)
            .referencedTables
        let referencedTableInfos = schema.tables.filter { table in
            referencedTables.contains(table.qualifiedName)
        }
        var bindings: [String] = []

        for column in analysis.columns {
            if column.name == "*" {
                appendStarBindings(
                    qualifier: column.qualifier,
                    relationAliases: relationAliases,
                    referencedTables: referencedTableInfos,
                    into: &bindings
                )
            } else if let qualifier = column.qualifier,
                let table = relationAliases[normalizeBinding(qualifier)]
            {
                appendBinding(for: column, table: table, into: &bindings)
            } else if let qualifier = column.qualifier,
                let table = tableMatchingQualifier(qualifier, in: referencedTableInfos)
            {
                appendBinding(for: column, table: table, into: &bindings)
            } else if column.qualifier == nil {
                let matches = referencedTableInfos.filter {
                    columnNamed(column.name, isQuoted: column.isQuoted, existsIn: $0)
                }
                if matches.count == 1, let table = matches.first {
                    appendBinding(for: column, table: table, into: &bindings)
                }
            }
        }
        if containsUnqualifiedSelectStar(sql) {
            for table in referencedTableInfos {
                appendAllBindings(for: table, into: &bindings)
            }
        }

        var seen = Set<String>()
        return bindings.filter { seen.insert(normalizeBinding($0)).inserted }.sorted()
    }

    private static func appendStarBindings(
        qualifier: String?,
        relationAliases: [String: TableInfo],
        referencedTables: [TableInfo],
        into bindings: inout [String]
    ) {
        if let qualifier,
            let table = relationAliases[normalizeBinding(qualifier)]
        {
            appendAllBindings(for: table, into: &bindings)
            return
        }

        for table in referencedTables {
            appendAllBindings(for: table, into: &bindings)
        }
    }

    private static func relationAliasMap(
        analysis: SQLReferenceAnalysis,
        schema: DatabaseSchema
    ) -> [String: TableInfo] {
        var result: [String: TableInfo] = [:]
        for relation in analysis.relations where !relation.isDerived {
            guard let table = table(for: relation, in: schema) else { continue }
            result[normalizeBinding(table.name)] = table
            result[normalizeBinding(table.qualifiedName)] = table
            if let alias = relation.alias {
                result[normalizeBinding(alias)] = table
            }
        }
        return result
    }

    private static func table(for relation: SQLRelationReference, in schema: DatabaseSchema) -> TableInfo? {
        schema.tables.first { table in
            let schemaMatches =
                relation.schema == nil
                || normalizeBinding(relation.schema ?? "") == normalizeBinding(table.schema)
            return schemaMatches && normalizeBinding(relation.name) == normalizeBinding(table.name)
        }
    }

    private static func tableMatchingQualifier(
        _ qualifier: String,
        in tables: [TableInfo]
    ) -> TableInfo? {
        let normalized = normalizeBinding(qualifier)
        return tables.first {
            normalizeBinding($0.name) == normalized || normalizeBinding($0.qualifiedName) == normalized
        }
    }

    private static func appendBinding(
        for column: SQLColumnReference,
        table: TableInfo,
        into bindings: inout [String]
    ) {
        guard let actual = table.columns.first(where: {
            columnMatches(column.name, isQuoted: column.isQuoted, actualName: $0.name)
        }) else { return }
        bindings.append("\(table.qualifiedName).\(actual.name)")
    }

    private static func appendAllBindings(for table: TableInfo, into bindings: inout [String]) {
        for column in table.columns {
            bindings.append("\(table.qualifiedName).\(column.name)")
        }
    }

    private static func containsUnqualifiedSelectStar(_ sql: String) -> Bool {
        matches(#"(?is)\bselect\s+(distinct\s+)?\*\s+\bfrom\b"#, in: sql)
    }

    private static func columnNamed(
        _ name: String,
        isQuoted: Bool,
        existsIn table: TableInfo
    ) -> Bool {
        table.columns.contains { columnMatches(name, isQuoted: isQuoted, actualName: $0.name) }
    }

    private static func columnMatches(
        _ reference: String,
        isQuoted: Bool,
        actualName: String
    ) -> Bool {
        if isQuoted {
            return reference == actualName
        }
        return reference.lowercased() == actualName.lowercased()
    }

    private static func normalizeBinding(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct EvalPostgresVerificationSnapshot {
    var status: SQLVerificationStatus
    var sqlState: String?
    var diagnosticKind: DatabaseDiagnosticKind?
    var elapsedMs: Int
    var repairAttempted: Bool
}

private extension TextToSQLEvalMetrics {
    func withOpenRouterAgentMetadata(
        _ metadata: OpenRouterGenerationMetadata?,
        trace: TextToSQLTrace?
    ) -> TextToSQLEvalMetrics {
        var copy = self
        copy.openRouterAgentSelectionReason = metadata?.agentSelectionReason
        copy.openRouterAgentLogicalTurnCount = metadata?.agentLogicalTurnCount
        copy.openRouterAgentHTTPAttemptCount = metadata?.agentHTTPAttemptCount
        copy.openRouterSchemaToolCallCount = trace?.schemaToolCalls.nonEmptyCount
            ?? metadata?.agentSchemaToolCallCount
        copy.openRouterInspectionToolCallCount = trace?.inspectionToolCalls.nonEmptyCount
            ?? metadata?.agentInspectionToolCallCount
        copy.openRouterAgentTerminalOutcome = metadata?.agentTerminalOutcome
        copy.openRouterAgentDiagnostics = metadata?.agentDiagnostics
        return copy
    }

    func withPostgresVerification(
        _ snapshot: EvalPostgresVerificationSnapshot?
    ) -> TextToSQLEvalMetrics {
        guard let snapshot else { return self }
        var copy = self
        copy.postgresVerificationStatus = snapshot.status
        copy.postgresVerificationSQLState = snapshot.sqlState
        copy.postgresVerificationDiagnosticKind = snapshot.diagnosticKind
        copy.postgresVerificationElapsedMs = snapshot.elapsedMs
        copy.postgresVerificationRepairAttempted = snapshot.repairAttempted
        return copy
    }
}

private extension Array where Element == SchemaToolCallTrace {
    var nonEmptyCount: Int? {
        isEmpty ? nil : count
    }
}

private extension Array where Element == DatabaseInspectionToolCallTrace {
    var nonEmptyCount: Int? {
        isEmpty ? nil : count
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
