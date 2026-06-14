import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct GenotypeAIHaplotypingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai-haplotyping",
        abstract: "Run AI discovery or AI refinement haplotyping on a genotype bundle."
    )

    @Option(name: .customLong("bundle"), help: "Path to the `.lungfishgenotype` result bundle.")
    var bundle: String

    @Option(name: .customLong("mode"), help: "AI haplotyping mode: ai-discovery or ai-refinement.")
    var mode: AIHaplotypingModeArgument = .aiRefinement

    @Option(name: .customLong("provider"), help: "AI provider: openai or anthropic.")
    var provider: AIHaplotypingProviderArgument = .anthropic

    @Option(name: .customLong("model"), help: "Provider model override. Defaults to the provider's app default.")
    var model: String?

    @Option(name: .customLong("prompt-template-id"), help: "Prompt template ID to pin for this run.")
    var promptTemplateID: String?

    @Option(name: .customLong("prompt-template-version"), help: "Prompt template version to pin for this run.")
    var promptTemplateVersion: String?

    @Option(name: .customLong("max-observations-per-chunk"), help: "Maximum observation evidence records per AI request.")
    var maxObservationsPerChunk: Int = 128

    @Option(name: .customLong("max-output-tokens"), help: "Maximum provider output tokens per chunk.")
    var maxOutputTokens: Int = 4096

    @Option(name: .customLong("temperature"), help: "Provider sampling temperature.")
    var temperature: Double = 0

    func validate() throws {
        guard !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--bundle must not be empty.")
        }
        if promptTemplateID != nil && promptTemplateVersion == nil {
            throw ValidationError("--prompt-template-version is required when --prompt-template-id is supplied.")
        }
        if promptTemplateVersion != nil && promptTemplateID == nil {
            throw ValidationError("--prompt-template-id is required when --prompt-template-version is supplied.")
        }
        if maxObservationsPerChunk < 1 {
            throw ValidationError("--max-observations-per-chunk must be at least 1.")
        }
        if maxOutputTokens < 1 {
            throw ValidationError("--max-output-tokens must be at least 1.")
        }
        if temperature < 0 || temperature > 2 {
            throw ValidationError("--temperature must be between 0 and 2.")
        }
    }

    func run() async throws {
        let summary = try await runReturningSummary()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func runReturningSummary() async throws -> AIHaplotypingCLISummary {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
            for: result,
            bundleURL: bundleURL,
            sidecar: sidecar
        )
        if mode.promptMode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
            throw ValidationError("AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle.")
        }
        let credential = try resolvedCredential()
        let providerInstance = makeProvider(apiKey: credential.apiKey)
        let runOptions = AIHaplotypingRunOptions(
            mode: mode.promptMode,
            providerID: provider.providerID,
            credentialSource: credential.source,
            promptTemplateID: promptTemplateID,
            promptTemplateVersion: promptTemplateVersion,
            maxObservationsPerChunk: maxObservationsPerChunk,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath
        )
        let runnerOutput = try await AIHaplotypingRunner(provider: providerInstance).run(
            result: activeResult,
            sidecar: sidecar,
            options: runOptions
        )
        let context = AIHaplotypingRevisionPublishContext(
            toolName: "lungfish-cli genotype ai-haplotyping",
            toolKind: "cli",
            argv: Self.sanitizedCommandLineArguments(),
            explicitOptions: explicitOptions(bundleURL: bundleURL, credentialSource: credential.source.rawValue),
            defaultOptions: defaultOptions(),
            resolvedOptions: resolvedOptions(
                bundleURL: bundleURL,
                modelID: providerInstance.modelId,
                credentialSource: credential.source.rawValue
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            startedAt: startedAt
        )
        let published = try AIHaplotypingRevisionPublisher().publish(
            AIHaplotypingRevisionPublishRequest(
                bundleURL: bundleURL,
                result: activeResult,
                sidecarURL: sidecarURL,
                sidecar: sidecar,
                runnerOutput: runnerOutput,
                context: context
            )
        )
        return AIHaplotypingCLISummary(
            bundle: bundleURL.path,
            mode: mode.rawValue,
            provider: provider.providerID.rawValue,
            model: providerInstance.modelId,
            revisionID: published.revision.id,
            analysisPath: published.revision.path,
            reviewState: published.revision.reviewState.rawValue,
            callCount: runnerOutput.normalizedCalls.count,
            discoveredDefinitionCount: runnerOutput.validatedDefinitions.count,
            provenancePath: published.revision.provenancePath
        )
    }

    private func resolvedCredential() throws -> (apiKey: String, source: AIHaplotypingCredentialSource) {
        let environmentName = provider.defaultEnvironmentVariable
        let apiKey = ProcessInfo.processInfo.environment[environmentName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw ValidationError("Missing API key. Set \(environmentName) before running AI haplotyping.")
        }
        return (apiKey, provider.credentialSource)
    }

    private func makeProvider(apiKey: String) -> any StructuredAIProvider {
        switch provider {
        case .openAI:
            return OpenAIProvider(apiKey: apiKey, modelId: modelValue(default: "gpt-5-mini"))
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, modelId: modelValue(default: "claude-sonnet-4-5-20250929"))
        }
    }

    private func modelValue(default defaultModel: String) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private func explicitOptions(bundleURL: URL, credentialSource: String) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "credentialSource": .string(credentialSource),
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
        ]
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options["model"] = .string(model)
        }
        if let promptTemplateID {
            options["promptTemplateID"] = .string(promptTemplateID)
        }
        if let promptTemplateVersion {
            options["promptTemplateVersion"] = .string(promptTemplateVersion)
        }
        return options
    }

    private func defaultOptions() -> [String: ParameterValue] {
        [
            "provider": .string(AIHaplotypingProviderArgument.anthropic.providerID.rawValue),
            "openAIModel": .string("gpt-5-mini"),
            "anthropicModel": .string("claude-sonnet-4-5-20250929"),
            "maxObservationsPerChunk": .integer(128),
            "maxOutputTokens": .integer(4096),
            "temperature": .number(0),
        ]
    }

    private func resolvedOptions(
        bundleURL: URL,
        modelID: String,
        credentialSource: String
    ) -> [String: ParameterValue] {
        [
            "bundle": .file(bundleURL),
            "mode": .string(mode.promptMode.rawValue),
            "provider": .string(provider.providerID.rawValue),
            "model": .string(modelID),
            "credentialSource": .string(credentialSource),
            "promptTemplateID": promptTemplateID.map(ParameterValue.string) ?? .null,
            "promptTemplateVersion": promptTemplateVersion.map(ParameterValue.string) ?? .null,
            "maxObservationsPerChunk": .integer(maxObservationsPerChunk),
            "maxOutputTokens": .integer(maxOutputTokens),
            "temperature": .number(temperature),
        ]
    }

    private static func sanitizedCommandLineArguments() -> [String] {
        CommandLine.arguments
    }
}

enum AIHaplotypingModeArgument: String, CaseIterable, ExpressibleByArgument {
    case aiDiscovery = "ai-discovery"
    case aiRefinement = "ai-refinement"

    var promptMode: AIHaplotypingPromptMode {
        switch self {
        case .aiDiscovery: return .aiDiscovery
        case .aiRefinement: return .aiRefinement
        }
    }
}

enum AIHaplotypingProviderArgument: String, CaseIterable, ExpressibleByArgument {
    case openAI = "openai"
    case anthropic

    var providerID: AIHaplotypingProviderID {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        }
    }

    var defaultEnvironmentVariable: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var credentialSource: AIHaplotypingCredentialSource {
        switch self {
        case .openAI: return .environmentOpenAI
        case .anthropic: return .environmentAnthropic
        }
    }
}

struct AIHaplotypingCLISummary: Codable, Equatable {
    let bundle: String
    let mode: String
    let provider: String
    let model: String
    let revisionID: String
    let analysisPath: String
    let reviewState: String
    let callCount: Int
    let discoveredDefinitionCount: Int
    let provenancePath: String
}
