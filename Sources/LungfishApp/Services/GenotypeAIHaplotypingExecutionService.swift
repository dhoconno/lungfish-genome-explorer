import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Where a run reads a provider key. The app passes the login keychain and a
/// test passes an in-memory stand-in, so no test writes a credential store.
protocol AIProviderSecretLookup: Sendable {
    func retrieve(forKey key: String) async throws -> String?
}

extension KeychainSecretStorage: AIProviderSecretLookup {}

@MainActor
final class GenotypeAIHaplotypingExecutionService {
    private let operationCenter: OperationCenter
    private let settings: AppSettings
    private let keychain: any AIProviderSecretLookup
    /// Runs once on an owned run between `prepare` and `begin`, so a test can
    /// change the bundle there and reach the re-read in `currentRun`.
    var afterPrepareForTesting: (@MainActor () async -> Void)?

    init(
        operationCenter: OperationCenter = .shared,
        settings: AppSettings = .shared,
        keychain: any AIProviderSecretLookup = KeychainSecretStorage.shared
    ) {
        self.operationCenter = operationCenter
        self.settings = settings
        self.keychain = keychain
    }

    @discardableResult
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext? = nil,
        parentOperationID: UUID? = nil
    ) async throws -> AIHaplotypingRevisionPublishResult {
        let bundle = bundleURL.standardizedFileURL
        let runClock = ProvenanceRunClock()
        let ownsOperation = parentOperationID == nil
        let operationID: UUID
        var prepared: PreparedRun?
        var preparationError: Error?
        if let parentOperationID {
            operationID = parentOperationID
            _ = operationCenter.updateWithLog(
                id: operationID,
                progress: Self.nestedProgress(0),
                detail: "Preparing \(displayName(for: mode))"
            )
        } else {
            // The row records its command before `begin`, naming the provider
            // and model as resolved (2.12 L11, BIO 4). The key stays with the
            // provider and reaches no argument (Q-S10). A run that cannot
            // resolve a provider or read its bundle records no command, and
            // its row fails with the same words as before.
            do {
                prepared = try await prepare(bundle: bundle, mode: mode)
            } catch {
                preparationError = error
            }
            await afterPrepareForTesting?()
            let startResult = operationCenter.begin(
                title: "AI Haplotyping",
                detail: "Preparing \(displayName(for: mode))",
                operationType: .fastqOperation,
                targetBundleURL: bundle,
                cliCommand: prepared?.cliCommand,
                routeContext: routeContext
            )
            guard case .started(let startedID) = startResult else {
                throw AIHaplotypingExecutionError.bundleBusy
            }
            operationID = startedID
        }

        do {
            if let preparationError {
                throw preparationError
            }
            _ = operationCenter.updateWithLog(
                id: operationID,
                progress: progress(0.1, ownsOperation: ownsOperation),
                detail: "Loading genotype bundle"
            )
            let run = try await currentRun(prepared, bundle: bundle, mode: mode, operationID: operationID)
            let provider = run.provider
            let sidecarURL = run.sidecarURL
            let sidecarSnapshot = run.sidecarSnapshot
            let sidecar = sidecarSnapshot.sidecar
            let activeResult = run.activeResult
            if mode == .aiRefinement, activeResult.haplotypeAnalysis == nil {
                throw AIHaplotypingExecutionError.refinementRequiresCurrentAnalysis
            }
            let promptSelection = run.promptSelection
            let argv = run.argv
            operationCenter.log(id: operationID, level: .info, message: run.cliCommand)
            _ = operationCenter.updateWithLog(
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
            _ = operationCenter.updateWithLog(
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
                runClock: runClock
            )
            let published = try AIHaplotypingRevisionPublisher().publish(
                AIHaplotypingRevisionPublishRequest(
                    bundleURL: bundle,
                    result: activeResult,
                    sidecarURL: sidecarURL,
                    sidecar: sidecar,
                    expectedSidecarRevision: sidecarSnapshot.revision,
                    runnerOutput: runnerOutput,
                    context: context
                )
            )
            let analysisURL = ONTGenotypeResultBundle.resolvedURL(for: published.revision.path, in: bundle)
            if ownsOperation {
                _ = operationCenter.complete(
                    id: operationID,
                    detail: "Created AI haplotype revision \(published.revision.id)",
                    outputURLs: [analysisURL, published.provenanceURL, sidecarURL]
                )
            } else {
                _ = operationCenter.updateWithLog(
                    id: operationID,
                    progress: Self.nestedProgress(1),
                    detail: "Created AI haplotype revision \(published.revision.id)"
                )
            }
            return published
        } catch {
            if ownsOperation,
               operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                _ = operationCenter.fail(
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

    private static func supportedProviderOrder(
        preferred: AIProviderIdentifier
    ) -> [AIProviderIdentifier] {
        let fallbackProviders = [AIProviderIdentifier.openAI, .anthropic]
        var providers = [AIProviderIdentifier]()
        for provider in [preferred] + fallbackProviders
        where provider == .anthropic || provider == .openAI {
            if !providers.contains(provider) {
                providers.append(provider)
            }
        }
        return providers
    }

    private func progress(_ value: Double, ownsOperation: Bool) -> Double {
        ownsOperation ? value : Self.nestedProgress(value)
    }

    private static func nestedProgress(_ value: Double) -> Double {
        0.9 + (min(max(value, 0), 1) * 0.05)
    }

    private func resolveProvider() async throws -> ResolvedProvider {
        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .openAI
        let providerOrder = Self.supportedProviderOrder(preferred: preferred)
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

    /// Resolves the provider and reads the bundle, so the command names the
    /// provider, model and prompt pins this run uses.
    private func prepare(bundle: URL, mode: AIHaplotypingPromptMode) async throws -> PreparedRun {
        let provider = try await resolveProvider()
        // The state is read before anything it describes, and the sidecar is
        // loaded once for both its revision and its content, so a write that
        // lands after these reads shows in `currentRun`'s comparison.
        let manifest = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: bundle))
        let sidecarSnapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundle)
        let result = try await ONTGenotypeResultBundle.loadResultAsync(from: bundle)
        let activeResult = GenotypeHaplotypeAnalysisResolver.resultByResolvingActiveAnalysis(
            for: result,
            bundleURL: bundle,
            sidecar: sidecarSnapshot.sidecar
        )
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
        return PreparedRun(
            provider: provider,
            bundleState: PreparedRun.BundleState(manifest: manifest, sidecar: sidecarSnapshot.revision),
            activeResult: activeResult,
            sidecarURL: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundle),
            sidecarSnapshot: sidecarSnapshot,
            promptSelection: promptSelection,
            argv: argv
        )
    }

    /// The run prepared before `begin`, prepared again under the bundle lock
    /// when the manifest or sidecar changed in between, so the run never
    /// works from a read that another operation's write overtook.
    private func currentRun(
        _ prepared: PreparedRun?,
        bundle: URL,
        mode: AIHaplotypingPromptMode,
        operationID: UUID
    ) async throws -> PreparedRun {
        guard let prepared else {
            return try await prepare(bundle: bundle, mode: mode)
        }
        if try Self.bundleState(of: bundle) == prepared.bundleState {
            return prepared
        }
        let reread = try await prepare(bundle: bundle, mode: mode)
        if reread.argv != prepared.argv {
            // The row began with the first read's command, so it takes the
            // command this run uses, and the revision's argv equals it.
            operationCenter.setCommand(id: operationID, command: reread.cliCommand)
            operationCenter.log(
                id: operationID,
                level: .warning,
                message: "The bundle changed before the run started, so the row now records the command this run used."
            )
        }
        return reread
    }

    private static func bundleState(of bundle: URL) throws -> PreparedRun.BundleState {
        PreparedRun.BundleState(
            manifest: try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: bundle)),
            sidecar: try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(forBundleAt: bundle).revision
        )
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
            CLICommandIdentity.executableName,
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

/// A run with its provider resolved and its bundle read, and the command
/// that names them.
private struct PreparedRun {
    struct BundleState: Equatable {
        let manifest: Data
        let sidecar: GenotypeAnnotationSidecarRevision
    }

    let provider: ResolvedProvider
    let bundleState: BundleState
    let activeResult: ONTGenotypeResultBundleData
    let sidecarURL: URL
    let sidecarSnapshot: GenotypeAnnotationSidecarSnapshot
    let promptSelection: AIHaplotypingPromptSelection
    let argv: [String]

    var cliCommand: String {
        ViralReconWorkflowCommandPreview.build(
            executableName: argv.first ?? LungfishAppIdentity.recordedToolName,
            arguments: Array(argv.dropFirst())
        )
    }
}

private enum AIHaplotypingExecutionError: Error, LocalizedError {
    case refinementRequiresCurrentAnalysis
    case bundleBusy

    var errorDescription: String? {
        switch self {
        case .refinementRequiresCurrentAnalysis:
            return "AI refinement requires an existing deterministic, manual, or AI haplotype analysis in the bundle."
        case .bundleBusy:
            return "The genotype bundle is busy. Wait for its current operation to finish."
        }
    }
}
