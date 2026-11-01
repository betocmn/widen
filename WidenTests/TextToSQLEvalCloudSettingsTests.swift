import Foundation
import Testing

@testable import WidenKit

@Suite("Text-to-SQL eval cloud settings")
struct TextToSQLEvalCloudSettingsTests {
    @Test func particleModelRunsOnParticleWithItsOwnKeyVariable() throws {
        let settings = try TextToSQLEvalCloudSettings(requestedModelID: "particle-1")

        #expect(settings.profile == .particle)
        #expect(settings.reasoningEffortOverride == nil)
        #expect(settings.provider == "particle")
        #expect(settings.endpointHost == "api.particle.ai")
        #expect(settings.reasoningEffort(for: .agentTurn) == "high")
        #expect(settings.reasoningEffort(for: .oneShotSQL) == "high")
        #expect(settings.missingAPIKeyMessage == "WIDEN_EVAL_PARTICLE_API_KEY is not set.")
    }

    @Test func openRouterModelRunsOnOpenRouterWithItsOwnKeyVariable() throws {
        let settings = try TextToSQLEvalCloudSettings(requestedModelID: "openai/gpt-5.5")

        #expect(settings.profile.provider == .openRouter)
        #expect(settings.profile.requestedModelID == "openai/gpt-5.5")
        #expect(settings.profile.expectedReturnedModelID == "openai/gpt-5.5-20260423")
        #expect(settings.provider == "openrouter")
        #expect(settings.endpointHost == "openrouter.ai")
        #expect(settings.reasoningEffort(for: .agentTurn) == nil)
        #expect(settings.reasoningEffort(for: .oneShotSQL) == nil)
        #expect(settings.missingAPIKeyMessage == "WIDEN_EVAL_OPENROUTER_API_KEY is not set.")
    }

    @Test func eachRunReadsOnlyItsOwnProvidersKey() throws {
        let particle = try TextToSQLEvalCloudSettings(requestedModelID: "particle-1")
        let openRouter = try TextToSQLEvalCloudSettings(requestedModelID: "vendor/other-model")
        let onlyOpenRouter = ["WIDEN_EVAL_OPENROUTER_API_KEY": "sk-or-v1-test"]
        let onlyParticle = ["WIDEN_EVAL_PARTICLE_API_KEY": "pai-test"]
        let both = onlyOpenRouter.merging(onlyParticle) { current, _ in current }

        #expect(particle.apiKey(in: onlyOpenRouter) == nil)
        #expect(particle.apiKey(in: both) == "pai-test")
        #expect(openRouter.apiKey(in: onlyParticle) == nil)
        #expect(openRouter.apiKey(in: both) == "sk-or-v1-test")
        #expect(particle.apiKey(in: ["WIDEN_EVAL_PARTICLE_API_KEY": "  pai-test \n"]) == "pai-test")
        #expect(particle.apiKey(in: ["WIDEN_EVAL_PARTICLE_API_KEY": " \n"]) == nil)
        #expect(particle.apiKey(in: [:]) == nil)
    }

    @Test func unknownModelsFailWithAClearMessage() {
        for junk in ["junk", "", "gpt-5.5", "particle-ai/particle-1", "openai/"] {
            #expect(throws: TextToSQLEvalCloudSettingsError.unknownModel(junk)) {
                try TextToSQLEvalCloudSettings(requestedModelID: junk)
            }
        }
        let message = TextToSQLEvalCloudSettingsError.unknownModel("junk").localizedDescription
        #expect(message.contains("\"junk\""))
        #expect(message.contains("particle-1"))
        #expect(message.contains("vendor/model"))
    }

    @Test func reasoningEffortOverrideReachesAgentAndOneShotRequests() throws {
        let settings = try TextToSQLEvalCloudSettings(
            requestedModelID: "particle-1",
            reasoningEffortOverride: .low
        )
        #expect(settings.reasoningEffortOverride == .low)
        #expect(settings.reasoningEffort(for: .agentTurn) == "low")
        #expect(settings.reasoningEffort(for: .oneShotSQL) == "low")
        #expect(settings.profile.policy(for: .connectivityProbe).reasoningEffort == ReasoningEffort.none)
        guard case .staticCapabilities(let capabilities) = settings.profile.capabilityResolution else {
            Issue.record("Particle capabilities must be static")
            return
        }

        let agentTurn = try ChatToolRequestBuilder(profile: settings.profile).build(
            apiKey: "pai-test",
            messages: [ChatToolMessage(role: .user, content: "question")],
            tools: [],
            capabilities: capabilities
        )
        #expect(try Self.body(agentTurn.request)["reasoning_effort"] as? String == "low")

        let oneShot = try ChatCompletionRequestBuilder(profile: settings.profile).build(
            apiKey: "pai-test",
            instructions: "instructions",
            prompt: "prompt",
            capabilities: capabilities
        )
        #expect(try Self.body(oneShot.request)["reasoning_effort"] as? String == "low")
        #expect(oneShot.reasoningEffort == "low")
    }

    @Test func everyReasoningEffortTheCLIAcceptsWorksOnParticle() throws {
        #expect(
            ReasoningEffort.allCases.map(\.rawValue)
                == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
        for effort in ReasoningEffort.allCases {
            let settings = try TextToSQLEvalCloudSettings(
                requestedModelID: "particle-1",
                reasoningEffortOverride: effort
            )
            #expect(settings.reasoningEffort(for: .agentTurn) == effort.rawValue)
        }
        #expect(ReasoningEffort(rawValue: "HIGH") == nil)
        #expect(ReasoningEffort(rawValue: "off") == nil)
    }

    @Test func reasoningEffortOverrideIsRejectedWithoutReasoningSupport() {
        #expect(
            throws: TextToSQLEvalCloudSettingsError.reasoningEffortUnsupported(
                model: "openai/gpt-5.5",
                provider: "OpenRouter"
            )
        ) {
            try TextToSQLEvalCloudSettings(
                requestedModelID: "openai/gpt-5.5",
                reasoningEffortOverride: .high
            )
        }
        let message = TextToSQLEvalCloudSettingsError.reasoningEffortUnsupported(
            model: "openai/gpt-5.5",
            provider: "OpenRouter"
        ).localizedDescription
        #expect(message.contains("--reasoning-effort"))
        #expect(message.contains("particle-1"))
    }

    @Test func manifestsWithoutAProviderResolveToOpenRouterForCloudRuns() {
        #expect(TextToSQLEvalCloudSettings.manifestName(for: .particle) == "particle")
        #expect(TextToSQLEvalCloudSettings.manifestName(for: .openRouter) == "openrouter")
        #expect(
            TextToSQLEvalCloudSettings.resolvedManifestProvider(nil, backendMode: "cloud")
                == "openrouter"
        )
        #expect(
            TextToSQLEvalCloudSettings.resolvedManifestProvider(nil, backendMode: "both")
                == "openrouter"
        )
        #expect(TextToSQLEvalCloudSettings.resolvedManifestProvider(nil, backendMode: "local") == nil)
        #expect(
            TextToSQLEvalCloudSettings.resolvedManifestProvider("particle", backendMode: "cloud")
                == "particle"
        )
    }

    @Test func resumedRunsInheritOnlyANonDefaultReasoningEffort() throws {
        func inherited(_ previous: String?, model: String = "particle-1") throws -> ReasoningEffort? {
            try TextToSQLEvalCloudSettings.resumedReasoningEffortOverride(
                previousReasoningEffort: previous,
                requestedModelID: model,
                callSite: .agentTurn
            )
        }

        #expect(try inherited(nil) == nil)
        // Particle's own default is not an override, so a resumed default
        // run passes the release gate without --allow-model-override.
        #expect(try inherited("high") == nil)
        #expect(try inherited("low") == .low)
        #expect(try inherited("none") == ReasoningEffort.none)
        // A profile that sends no effort inherits none; resume compatibility
        // then reports the provider and effort mismatch.
        #expect(try inherited("low", model: "openai/gpt-5.5") == nil)
        #expect(throws: TextToSQLEvalCloudSettingsError.unknownReasoningEffort("extreme")) {
            try inherited("extreme")
        }
    }

    @Test func caseTimeoutOutlastsEveryAgentInvocationInOneCase() {
        let agent = SchemaToolSQLAgentConfiguration.default
        let policy = TextToSQLRepairPolicy.default
        let repairs = policy.maximumValidationRepairs + policy.maximumVerificationRepairs
        let margin: TimeInterval = 60

        #expect(TextToSQLEvalDefaults.caseTimeoutSeconds == 1_200)
        // The first generation, then every repair the policy allows, each
        // bounded by the repair wall clock.
        #expect(
            TextToSQLEvalDefaults.caseTimeoutSeconds
                > agent.wallClockTimeoutSeconds
                    + agent.repairWallClockTimeoutSeconds * Double(repairs) + margin
        )
        // No repair starts after the cutoff, so the last one ends within one
        // repair wall clock of it.
        #expect(
            TextToSQLEvalDefaults.caseTimeoutSeconds
                > policy.repairStartCutoffSeconds + agent.repairWallClockTimeoutSeconds + margin
        )
    }

    @Test func defaultEvalModelIsParticle() throws {
        #expect(TextToSQLEvalDefaults.requestedModelID == "particle-1")
        let settings = try TextToSQLEvalCloudSettings(
            requestedModelID: TextToSQLEvalDefaults.requestedModelID
        )
        #expect(settings.profile == .particle)
    }

    @Test func agentReportsItsBudgetsForTheRunManifest() {
        #expect(
            SchemaToolSQLAgentConfiguration.default.reportedSettings == [
                "maximumModelTurns": "12",
                "maximumSchemaToolCalls": "12",
                "maximumRepairSchemaToolCalls": "4",
                "maximumHTTPAttempts": "30",
                "maximumMalformedTerminalCorrections": "2",
                "maximumRepeatedToolCorrections": "2",
                "maximumInvalidTerminalSQLCorrections": "2",
                "maximumOverClarificationCorrections": "1",
                "maximumIntentCoverageCorrections": "1",
                "maximumPlanConsistencyCorrections": "1",
                "maximumTerminalRequiredCorrections": "1",
                "wallClockTimeoutSeconds": "180",
                "repairWallClockTimeoutSeconds": "120",
                "forcedTerminalMode": "terminalToolOnly",
                "maximumForcedTerminalRequests": "2",
                "forcedTerminalTimeReserveSeconds": "45",
                "criticMode": "enabled",
                "maximumCriticRevisions": "2",
                "maximumCriticHTTPAttempts": "2",
                "criticMinimumRemainingSeconds": "30",
                "criticRevisionMinimumRemainingSeconds": "60",
            ]
        )
        var configuration = SchemaToolSQLAgentConfiguration.default
        configuration.wallClockTimeoutSeconds = 90.5
        configuration.criticMode = .disabled
        #expect(configuration.reportedSettings["wallClockTimeoutSeconds"] == "90.5")
        #expect(
            configuration.reportedSettings[TextToSQLEvalSchemaAgentCritic.reportedSettingsKey]
                == "disabled"
        )
    }

    @Test func widenEvalSelectsTheProfileFromTheModelAndReadsOnlyItsKey() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/WidenEvalMain.swift"),
            encoding: .utf8
        )
        let runner = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/EvalRunner.swift"),
            encoding: .utf8
        )

        // CLI defaults: Particle-1, the tools agent, and the shared timeout.
        #expect(main.contains("var model: String = TextToSQLEvalDefaults.requestedModelID"))
        #expect(main.contains("var cloudAgentMode: EvalCloudAgentMode = .tools"))
        #expect(main.contains("var caseTimeoutSeconds: Double = TextToSQLEvalDefaults.caseTimeoutSeconds"))
        #expect(!main.contains("--provider "), "the provider is inferred from --model")

        let effortStart = try #require(main.range(of: #"case "--reasoning-effort":"#))
        let effortCase = String(main[effortStart.upperBound...].prefix(400))
        #expect(effortCase.contains("guard let effort = ReasoningEffort(rawValue: value) else {"))
        #expect(effortCase.contains("throw EvalCLIError.invalidValue(argument, value)"))
        #expect(effortCase.contains("options.explicitOptions.insert(.reasoningEffort)"))
        #expect(
            main.contains(
                #"--reasoning-effort \(ReasoningEffort.allCases.map(\.rawValue).joined(separator: "|"))"#
            )
        )

        // The runner resolves one profile from the model, checks the gate
        // with the effort override, and reads the key only through it.
        let runStart = try #require(runner.range(of: "func run() async throws -> EvalRun {"))
        let runText = String(runner[runStart.upperBound...].prefix(1_200))
        let gateCheck = try #require(runText.range(of: "TextToSQLReleaseGateModelPolicy.validate("))
        let effortArgument = try #require(
            runText.range(of: "reasoningEffortOverride: runner.options.reasoningEffort,")
        )
        let settings = try #require(runText.range(of: "try TextToSQLEvalCloudSettings("))
        #expect(gateCheck.lowerBound < effortArgument.lowerBound)
        #expect(effortArgument.lowerBound < settings.lowerBound)
        #expect(runner.contains("cloud.apiKey(in: ProcessInfo.processInfo.environment)"))
        #expect(runner.contains("cloud.missingAPIKeyMessage"))
        #expect(!runner.contains("WIDEN_EVAL_OPENROUTER_API_KEY"))
        #expect(!runner.contains("WIDEN_EVAL_PARTICLE_API_KEY"))
        #expect(!runner.contains("CloudModelProfile.openRouter("))
    }

    @Test func committedDocChecksReadTheRecordedReasoningEffort() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reporter = try String(
            contentsOf: repoRoot.appendingPathComponent("WidenEval/ReleaseGateReporter.swift"),
            encoding: .utf8
        )

        // Sink-time eligibility, used by every gate and triage write, checks
        // the effort the manifest recorded for the run's call site.
        let eligibilityStart = try #require(
            reporter.range(of: "var committedDocIneligibility: TextToSQLReleaseGateModelPolicy.CommittedDocIneligibility? {")
        )
        let eligibility = String(reporter[eligibilityStart.upperBound...].prefix(1_200))
        #expect(eligibility.contains("reasoningEffort: manifest.reasoningEffort,"))
        #expect(eligibility.contains("callSite: manifest.cloudCallSite,"))
        #expect(
            reporter.contains(
                "cloudAgentMode == EvalCloudAgentMode.tools.rawValue ? .agentTurn : .oneShotSQL"
            )
        )

        // Offline re-triage derives the override from the manifest, so a
        // non-default-effort run needs --allow-model-override as when it ran.
        let retriageStart = try #require(reporter.range(of: "static func writeExisting("))
        let retriage = String(reporter[retriageStart.upperBound...].prefix(2_000))
        let override = try #require(
            retriage.range(of: "try TextToSQLEvalCloudSettings.resumedReasoningEffortOverride(")
        )
        let recorded = try #require(
            retriage.range(of: "previousReasoningEffort: runFile.manifest.reasoningEffort,")
        )
        let gateCheck = try #require(retriage.range(of: "try TextToSQLReleaseGateModelPolicy.validate("))
        let overrideArgument = try #require(
            retriage.range(of: "reasoningEffortOverride: reasoningEffortOverride,")
        )
        #expect(retriage.contains("callSite: runFile.manifest.cloudCallSite"))
        #expect(override.lowerBound < recorded.lowerBound)
        #expect(recorded.lowerBound < gateCheck.lowerBound)
        #expect(gateCheck.lowerBound < overrideArgument.lowerBound)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
