import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class GenotypeAIHaplotypingExecutionService {
    private let operationCenter: OperationCenter
    private let settings: AppSettings
    private let keychain: KeychainSecretStorage

    init(
        operationCenter: OperationCenter = .shared,
        settings: AppSettings = .shared,
        keychain: KeychainSecretStorage = .shared
    ) {
        self.operationCenter = operationCenter
        self.settings = settings
        self.keychain = keychain
    }

    static func hasConfiguredProvider(
        settings: AppSettings = .shared,
        keychain: KeychainSecretStorage = .shared
    ) async -> Bool {
        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .openAI
        let providerOrder = ([preferred] + [AIProviderIdentifier.openAI, .anthropic])
            .filter { $0 == .anthropic || $0 == .openAI }
            .reduce(into: [AIProviderIdentifier]()) { partial, provider in
                if !partial.contains(provider) {
                    partial.append(provider)
                }
            }
        for providerID in providerOrder {
            do {
                switch providerID {
                case .anthropic:
                    if let apiKey = try await keychain.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey),
                       !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                case .openAI:
                    if let apiKey = try await keychain.retrieve(forKey: KeychainSecretStorage.openAIAPIKey),
                       !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       (try? settings.openAIEndpointConfiguration()) != nil {
                        return true
                    }
                case .gemini:
                    continue
                }
            } catch {
                continue
            }
        }
        return false
    }

    @discardableResult
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext? = nil,
        parentOperationID: UUID? = nil
    ) async throws -> AIHaplotypingRevisionPublishResult {
        let bundle = bundleURL.standardizedFileURL
        let startedAt = Date()
        let ownsOperation = parentOperationID == nil
        let operationID: UUID
        if let parentOperationID {
            operationID = parentOperationID
            operationCenter.updateWithLog(
                id: operationID,
                progress: Self.nestedProgress(0),
                detail: "Preparing \(displayName(for: mode))"
            )
        } else {
            operationID = operationCenter.start(
                title: "AI Haplotyping",
                detail: "Preparing \(displayName(for: mode))",
                operationType: .fastqOperation,
                targetBundleURL: bundle,
                cliCommand: nil,
                routeContext: routeContext
            )
        }

        do {
            let provider = try await resolveProvider()
            operationCenter.updateWithLog(
                id: operationID,
                progress: progress(0.1, ownsOperation: ownsOperation),
                detail: "Loading genotype bundle"
            )

            let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
            let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundle)
            let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
            let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
                for: result,
                bundleURL: bundle,
                sidecar: sidecar
            )
            if mode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
                throw AIHaplotypingExecutionError.refinementRequiresCurrentAnalysis
            }
            let promptSelection = AIHaplotypingPromptSelectionResolver.resolve(
                result: activeResult,
                mode: mode,
                requestedPromptTemplateID: nil,
                requestedPromptTemplateVersion: nil,
                compactKnowledgePack: AIHaplotypingExecutionDefaults.compactKnowledgePack
            )
            let argv = commandPreview(
                bundleURL: bundle,
                mode: mode,
                providerID: provider.providerID,
                modelID: provider.structuredProvider.modelId,
                promptSelection: promptSelection,
                openAIEndpointConfiguration: provider.openAIEndpointConfiguration
            )
            let cliCommand = ViralReconWorkflowCommandPreview.build(
                executableName: argv.first ?? "lungfish-gui",
                arguments: Array(argv.dropFirst())
            )
            operationCenter.log(id: operationID, level: .info, message: cliCommand)
            operationCenter.updateWithLog(
                id: operationID,
                progress: progress(0.25, ownsOperation: ownsOperation),
                detail: "Running structured AI haplotyping"
            )

            let options = AIHaplotypingRunOptions(
                mode: mode,
                providerID: provider.providerID,
                credentialSource: provider.credentialSource,
                promptTemplateID: promptSelection.promptTemplateID,
                promptTemplateVersion: promptSelection.promptTemplateVersion,
                maxObservationsPerChunk: AIHaplotypingExecutionDefaults.maxObservationsPerChunk,
                maxOutputTokens: AIHaplotypingExecutionDefaults.maxOutputTokens,
                temperature: AIHaplotypingExecutionDefaults.temperature,
                reasoningEffort: AIHaplotypingExecutionDefaults.reasoningEffort,
                maxProviderRetries: AIHaplotypingExecutionDefaults.maxProviderRetries,
                provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath,
                compactKnowledgePack: promptSelection.compactKnowledgePack,
                includeKnowledgePack: promptSelection.includeKnowledgePack
            )
            let runnerOutput = try await AIHaplotypingRunner(provider: provider.structuredProvider).run(
                result: activeResult,
                sidecar: sidecar,
                options: options
            )
            operationCenter.updateWithLog(
                id: operationID,
                progress: progress(0.75, ownsOperation: ownsOperation),
                detail: "Publishing AI haplotype revision"
            )

            var explicitOptions: [String: ParameterValue] = [
                "bundle": .file(bundle),
                "mode": .string(mode.rawValue),
                "provider": .string(provider.providerID.rawValue),
                "credentialSource": .string(provider.credentialSource.rawValue),
                "resolvedPromptTemplateID": promptSelection.promptTemplateID.map(ParameterValue.string) ?? .null,
                "resolvedPromptTemplateVersion": promptSelection.promptTemplateVersion.map(ParameterValue.string) ?? .null,
                "includeKnowledgePack": .string(promptSelection.includeKnowledgePack ? "true" : "false"),
                "resolvedCompactKnowledgePack": .string(promptSelection.compactKnowledgePack ? "true" : "false"),
            ]
            addOpenAIHostedEndpointOptions(provider.openAIEndpointConfiguration, to: &explicitOptions)

            let defaultOptions: [String: ParameterValue] = [
                "compactKnowledgePack": .string(AIHaplotypingExecutionDefaults.compactKnowledgePack ? "true" : "false"),
                "maxObservationsPerChunk": .integer(AIHaplotypingExecutionDefaults.maxObservationsPerChunk),
                "maxOutputTokens": .integer(AIHaplotypingExecutionDefaults.maxOutputTokens),
                "temperature": .number(AIHaplotypingExecutionDefaults.temperature),
                "reasoningEffort": .string(AIHaplotypingExecutionDefaults.reasoningEffort),
                "openAIModel": .string(AIHaplotypingExecutionDefaults.openAIModel),
                "maxProviderRetries": .integer(AIHaplotypingExecutionDefaults.maxProviderRetries),
                "includeKnowledgePack": .string("true"),
                "azureOpenAIEndpoint": .null,
                "azureOpenAIDeployment": .null,
            ]

            var resolvedOptions: [String: ParameterValue] = [
                "bundle": .file(bundle),
                "mode": .string(mode.rawValue),
                "provider": .string(provider.providerID.rawValue),
                "model": .string(provider.structuredProvider.modelId),
                "credentialSource": .string(provider.credentialSource.rawValue),
                "promptTemplateID": promptSelection.promptTemplateID.map(ParameterValue.string) ?? .null,
                "promptTemplateVersion": promptSelection.promptTemplateVersion.map(ParameterValue.string) ?? .null,
                "compactKnowledgePack": .string(promptSelection.compactKnowledgePack ? "true" : "false"),
                "includeKnowledgePack": .string(promptSelection.includeKnowledgePack ? "true" : "false"),
                "usesSpecialistPrompt": .string(promptSelection.usesSpecialistPrompt ? "true" : "false"),
                "maxObservationsPerChunk": .integer(AIHaplotypingExecutionDefaults.maxObservationsPerChunk),
                "maxOutputTokens": .integer(AIHaplotypingExecutionDefaults.maxOutputTokens),
                "temperature": .number(AIHaplotypingExecutionDefaults.temperature),
                "reasoningEffort": .string(AIHaplotypingExecutionDefaults.reasoningEffort),
                "maxProviderRetries": .integer(AIHaplotypingExecutionDefaults.maxProviderRetries),
            ]
            addOpenAIHostedEndpointOptions(provider.openAIEndpointConfiguration, to: &resolvedOptions)

            let context = AIHaplotypingRevisionPublishContext(
                toolName: "Lungfish Genome Explorer AI haplotyping",
                toolKind: "gui",
                argv: argv,
                explicitOptions: explicitOptions,
                defaultOptions: defaultOptions,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                startedAt: startedAt
            )
            let published = try AIHaplotypingRevisionPublisher().publish(
                AIHaplotypingRevisionPublishRequest(
                    bundleURL: bundle,
                    result: activeResult,
                    sidecarURL: sidecarURL,
                    sidecar: sidecar,
                    runnerOutput: runnerOutput,
                    context: context
                )
            )
            let analysisURL = ONTGenotypeResultBundle.resolvedURL(for: published.revision.path, in: bundle)
            if ownsOperation {
                operationCenter.complete(
                    id: operationID,
                    detail: "Created AI haplotype revision \(published.revision.id)",
                    outputURLs: [analysisURL, published.provenanceURL, sidecarURL]
                )
            } else {
                operationCenter.updateWithLog(
                    id: operationID,
                    progress: Self.nestedProgress(1),
                    detail: "Created AI haplotype revision \(published.revision.id)"
                )
            }
            return published
        } catch {
            if ownsOperation,
               operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: "AI haplotyping failed",
                    errorMessage: "AI haplotyping failed",
                    errorDetail: Self.failureDetail(for: error)
                )
            } else if !ownsOperation {
                operationCenter.log(
                    id: operationID,
                    level: .error,
                    message: "AI haplotyping failed: \(Self.failureDetail(for: error))"
                )
            }
            throw error
        }
    }

    private func progress(_ value: Double, ownsOperation: Bool) -> Double {
        ownsOperation ? value : Self.nestedProgress(value)
    }

    private static func nestedProgress(_ value: Double) -> Double {
        0.9 + (min(max(value, 0), 1) * 0.05)
    }

    private func resolveProvider() async throws -> ResolvedProvider {
        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .openAI
        let providerOrder = ([preferred] + [AIProviderIdentifier.openAI, .anthropic])
            .filter { $0 == .anthropic || $0 == .openAI }
            .reduce(into: [AIProviderIdentifier]()) { partial, provider in
                if !partial.contains(provider) {
                    partial.append(provider)
                }
            }
        for providerID in providerOrder {
            switch providerID {
            case .anthropic:
                if let apiKey = try await keychain.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey),
                   !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ResolvedProvider(
                        providerID: .anthropic,
                        credentialSource: .keychainAnthropic,
                        structuredProvider: AnthropicProvider(apiKey: apiKey, modelId: settings.anthropicModel),
                        openAIEndpointConfiguration: nil
                    )
                }
            case .openAI:
                if let apiKey = try await keychain.retrieve(forKey: KeychainSecretStorage.openAIAPIKey),
                   !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let endpointConfiguration = try settings.openAIEndpointConfiguration()
                    return ResolvedProvider(
                        providerID: .openAI,
                        credentialSource: .keychainOpenAI,
                        structuredProvider: OpenAIProvider(
                            apiKey: apiKey,
                            modelId: AIHaplotypingExecutionDefaults.openAIModel,
                            endpointConfiguration: endpointConfiguration
                        ),
                        openAIEndpointConfiguration: endpointConfiguration
                    )
                }
            case .gemini:
                continue
            }
        }
        throw AIProviderError.missingAPIKey
    }

    private func commandPreview(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        modelID: String,
        promptSelection: AIHaplotypingPromptSelection,
        openAIEndpointConfiguration: OpenAIEndpointConfiguration?
    ) -> [String] {
        var command = [
            "lungfish-cli",
            "genotype",
            "ai-haplotyping",
            "--bundle", bundleURL.path,
            "--mode", mode.commandLineArgument,
            "--provider", providerID.rawValue,
            "--model", modelID,
            "--max-observations-per-chunk", "\(AIHaplotypingExecutionDefaults.maxObservationsPerChunk)",
            "--max-output-tokens", "\(AIHaplotypingExecutionDefaults.maxOutputTokens)",
            "--temperature", Self.commandLineNumber(AIHaplotypingExecutionDefaults.temperature),
            "--reasoning-effort", AIHaplotypingExecutionDefaults.reasoningEffort,
            "--max-provider-retries", "\(AIHaplotypingExecutionDefaults.maxProviderRetries)",
        ]
        if promptSelection.compactKnowledgePack {
            command.append("--compact-knowledge-pack")
        }
        if let promptTemplateID = promptSelection.promptTemplateID {
            command += ["--prompt-template-id", promptTemplateID]
        }
        if let promptTemplateVersion = promptSelection.promptTemplateVersion {
            command += ["--prompt-template-version", promptTemplateVersion]
        }
        appendOpenAIHostedEndpointArguments(openAIEndpointConfiguration, to: &command)
        return command
    }

    private func appendOpenAIHostedEndpointArguments(
        _ configuration: OpenAIEndpointConfiguration?,
        to command: inout [String]
    ) {
        guard case .azure(let endpoint, let deployment) = configuration else {
            return
        }
        command += [
            "--azure-openai-endpoint", endpoint.absoluteString,
            "--azure-openai-deployment", deployment,
        ]
    }

    private func addOpenAIHostedEndpointOptions(
        _ configuration: OpenAIEndpointConfiguration?,
        to options: inout [String: ParameterValue]
    ) {
        guard case .azure(let endpoint, let deployment) = configuration else {
            return
        }
        options["azureOpenAIEndpoint"] = .string(endpoint.absoluteString)
        options["azureOpenAIDeployment"] = .string(deployment)
    }

    private static func commandLineNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func failureDetail(for error: Error) -> String {
        if let failure = error as? AIHaplotypingRunFailure {
            return "\(failure.sanitizedErrorCategory): \(failure.message)"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return "AI haplotyping failed before a sanitized provider result was available."
    }

    private func displayName(for mode: AIHaplotypingPromptMode) -> String {
        switch mode {
        case .aiDiscovery: return "AI Discovery"
        case .aiRefinement: return "AI Refinement"
        }
    }
}

private enum AIHaplotypingExecutionDefaults {
    static let maxObservationsPerChunk = 10_000
    static let maxOutputTokens = 16_384
    static let temperature = 0.0
    static let openAIModel = MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel
    static let reasoningEffort = MCMHaplotypingPreset.mcmMHCmiseq.aiReasoningEffort
    static let maxProviderRetries = 5
    static let compactKnowledgePack = true
}

private extension AIHaplotypingPromptMode {
    var commandLineArgument: String {
        switch self {
        case .aiDiscovery: return "ai-discovery"
        case .aiRefinement: return "ai-refinement"
        }
    }
}

private struct ResolvedProvider {
    let providerID: AIHaplotypingProviderID
    let credentialSource: AIHaplotypingCredentialSource
    let structuredProvider: any StructuredAIProvider
    let openAIEndpointConfiguration: OpenAIEndpointConfiguration?
}

private enum AIHaplotypingExecutionError: Error, LocalizedError {
    case refinementRequiresCurrentAnalysis

    var errorDescription: String? {
        switch self {
        case .refinementRequiresCurrentAnalysis:
            return "AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle."
        }
    }
}
