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

    @discardableResult
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext? = nil
    ) async throws -> AIHaplotypingRevisionPublishResult {
        let bundle = bundleURL.standardizedFileURL
        let startedAt = Date()
        let operationID = operationCenter.start(
            title: "AI Haplotyping",
            detail: "Preparing \(displayName(for: mode))",
            operationType: .fastqOperation,
            targetBundleURL: bundle,
            cliCommand: nil,
            routeContext: routeContext
        )

        do {
            let provider = try await resolveProvider()
            let argv = commandPreview(
                bundleURL: bundle,
                mode: mode,
                providerID: provider.providerID,
                modelID: provider.structuredProvider.modelId
            )
            let cliCommand = ViralReconWorkflowCommandPreview.build(
                executableName: argv.first ?? "lungfish-gui",
                arguments: Array(argv.dropFirst())
            )
            operationCenter.log(id: operationID, level: .info, message: cliCommand)
            operationCenter.updateWithLog(id: operationID, progress: 0.1, detail: "Loading genotype bundle")

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
            operationCenter.updateWithLog(id: operationID, progress: 0.25, detail: "Running structured AI haplotyping")

            let options = AIHaplotypingRunOptions(
                mode: mode,
                providerID: provider.providerID,
                credentialSource: provider.credentialSource,
                maxObservationsPerChunk: 128,
                maxOutputTokens: 4096,
                temperature: 0,
                provenancePath: AIHaplotypingPatchValidator.pendingProvenancePath
            )
            let runnerOutput = try await AIHaplotypingRunner(provider: provider.structuredProvider).run(
                result: activeResult,
                sidecar: sidecar,
                options: options
            )
            operationCenter.updateWithLog(id: operationID, progress: 0.75, detail: "Publishing AI haplotype revision")

            let context = AIHaplotypingRevisionPublishContext(
                toolName: "Lungfish Genome Explorer AI haplotyping",
                toolKind: "gui",
                argv: argv,
                explicitOptions: [
                    "bundle": .file(bundle),
                    "mode": .string(mode.rawValue),
                    "provider": .string(provider.providerID.rawValue),
                    "credentialSource": .string(provider.credentialSource.rawValue),
                ],
                defaultOptions: [
                    "maxObservationsPerChunk": .integer(128),
                    "maxOutputTokens": .integer(4096),
                    "temperature": .number(0),
                ],
                resolvedOptions: [
                    "bundle": .file(bundle),
                    "mode": .string(mode.rawValue),
                    "provider": .string(provider.providerID.rawValue),
                    "model": .string(provider.structuredProvider.modelId),
                    "credentialSource": .string(provider.credentialSource.rawValue),
                    "maxObservationsPerChunk": .integer(128),
                    "maxOutputTokens": .integer(4096),
                    "temperature": .number(0),
                ],
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
            operationCenter.complete(
                id: operationID,
                detail: "Created AI haplotype revision \(published.revision.id)",
                outputURLs: [analysisURL, published.provenanceURL, sidecarURL]
            )
            return published
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: "AI haplotyping failed",
                    errorMessage: "AI haplotyping failed",
                    errorDetail: Self.failureDetail(for: error)
                )
            }
            throw error
        }
    }

    private func resolveProvider() async throws -> ResolvedProvider {
        let preferred = AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .anthropic
        let providerOrder = ([preferred] + [AIProviderIdentifier.anthropic, .openAI])
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
                        structuredProvider: AnthropicProvider(apiKey: apiKey, modelId: settings.anthropicModel)
                    )
                }
            case .openAI:
                if let apiKey = try await keychain.retrieve(forKey: KeychainSecretStorage.openAIAPIKey),
                   !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ResolvedProvider(
                        providerID: .openAI,
                        credentialSource: .keychainOpenAI,
                        structuredProvider: OpenAIProvider(apiKey: apiKey, modelId: settings.openAIModel)
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
        modelID: String
    ) -> [String] {
        [
            "lungfish-cli",
            "genotype",
            "ai-haplotyping",
            "--bundle", bundleURL.path,
            "--mode", mode.commandLineArgument,
            "--provider", providerID.rawValue,
            "--model", modelID,
        ]
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
