import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingReviewScope: String, Codable, Equatable, Sendable {
    case all
    case unresolvedOnly = "unresolved-only"
}

public struct AIHaplotypingRunOptions: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let providerID: AIHaplotypingProviderID
    public let credentialSource: AIHaplotypingCredentialSource?
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let maxObservationsPerChunk: Int
    public let maxOutputTokens: Int
    public let temperature: Double
    public let reasoningEffort: String?
    public let maxProviderRetries: Int
    public let provenancePath: String
    public let compactKnowledgePack: Bool
    public let includeKnowledgePack: Bool
    public let chunkStartIndex: Int
    public let chunkEndIndex: Int
    public let reviewScope: AIHaplotypingReviewScope

    public init(
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        credentialSource: AIHaplotypingCredentialSource? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        maxObservationsPerChunk: Int = 1,
        maxOutputTokens: Int = 4_096,
        temperature: Double = 0,
        reasoningEffort: String? = nil,
        maxProviderRetries: Int = 2,
        provenancePath: String = "ai-haplotyping/provenance.json",
        compactKnowledgePack: Bool = false,
        includeKnowledgePack: Bool = true,
        chunkStartIndex: Int = 1,
        chunkEndIndex: Int = 0,
        reviewScope: AIHaplotypingReviewScope = .all
    ) {
        self.mode = mode
        self.providerID = providerID
        self.credentialSource = credentialSource
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.maxObservationsPerChunk = max(1, maxObservationsPerChunk)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = max(0, min(2, temperature))
        let trimmedReasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = trimmedReasoningEffort.isEmpty ? nil : trimmedReasoningEffort
        self.maxProviderRetries = max(0, maxProviderRetries)
        let trimmedProvenancePath = provenancePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provenancePath = trimmedProvenancePath.isEmpty
            ? "ai-haplotyping/provenance.json"
            : trimmedProvenancePath
        self.compactKnowledgePack = compactKnowledgePack
        self.includeKnowledgePack = includeKnowledgePack
        self.chunkStartIndex = max(1, chunkStartIndex)
        self.chunkEndIndex = max(0, chunkEndIndex)
        self.reviewScope = reviewScope
    }

    public func generationParameters(
        schemaName: String,
        evidenceEncoding: String = "full-v1",
        promptCacheRetention: String? = nil,
        promptCacheKey: String? = nil
    ) -> [String: String] {
        let parameters = [
            "chunkEndIndex": String(chunkEndIndex),
            "chunkStartIndex": String(chunkStartIndex),
            "compactKnowledgePack": compactKnowledgePack ? "true" : "false",
            "evidenceEncoding": evidenceEncoding,
            "knowledgePackMode": includeKnowledgePack ? (compactKnowledgePack ? "compact" : "full") : "disabled",
            "maxObservationsPerChunk": String(maxObservationsPerChunk),
            "maxOutputTokens": String(maxOutputTokens),
            "maxProviderRetries": String(maxProviderRetries),
            "promptCacheKey": promptCacheKey ?? "none",
            "promptCacheRetention": promptCacheRetention ?? "none",
            "reasoningEffort": reasoningEffort ?? "none",
            "reviewScope": reviewScope.rawValue,
            "schemaName": schemaName,
            "temperature": Self.formatNumber(temperature),
        ]
        return parameters
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }
}

public struct AIHaplotypingRunnerOutput: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let registry: AIHaplotypingEvidenceRegistry
    public let chunkOutputs: [AIHaplotypingChunkOutput]
    public let normalizedCalls: [AIHaplotypingValidatedCall]
    public let validatedDefinitions: [AIHaplotypingValidatedDefinition]
    public let validationReports: [AIHaplotypingValidationReport]
    public let providerAttempts: [AIProviderAttemptMetadata]

    public init(
        mode: AIHaplotypingPromptMode,
        registry: AIHaplotypingEvidenceRegistry,
        chunkOutputs: [AIHaplotypingChunkOutput],
        normalizedCalls: [AIHaplotypingValidatedCall],
        validatedDefinitions: [AIHaplotypingValidatedDefinition],
        validationReports: [AIHaplotypingValidationReport],
        providerAttempts: [AIProviderAttemptMetadata]
    ) {
        self.mode = mode
        self.registry = registry
        self.chunkOutputs = chunkOutputs
        self.normalizedCalls = normalizedCalls
        self.validatedDefinitions = validatedDefinitions
        self.validationReports = validationReports
        self.providerAttempts = providerAttempts
    }
}

public enum AIHaplotypingProgressEvent: Equatable, Sendable {
    case runStarted(chunkCount: Int, observationCount: Int)
    case chunkStarted(chunkID: String, chunkIndex: Int, chunkCount: Int, observationCount: Int)
    case providerRetry(chunkID: String, retryIndex: Int, maxRetries: Int, errorCategory: String)
    case chunkFinished(chunkID: String, chunkIndex: Int, chunkCount: Int, callCount: Int, definitionCount: Int)
    case runFinished(chunkCount: Int, callCount: Int, definitionCount: Int)
}

public struct AIHaplotypingChunkOutput: Codable, Equatable, Sendable {
    public let chunkID: String
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let promptMetadata: AIHaplotypingPromptMetadata
    public let payloadDigest: String
    public let validationReport: AIHaplotypingValidationReport
    public let providerAttempt: AIProviderAttemptMetadata

    public init(
        chunkID: String,
        registryDigest: String,
        inputSnapshotDigest: String,
        promptMetadata: AIHaplotypingPromptMetadata,
        payloadDigest: String,
        validationReport: AIHaplotypingValidationReport,
        providerAttempt: AIProviderAttemptMetadata
    ) {
        self.chunkID = chunkID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.promptMetadata = promptMetadata
        self.payloadDigest = payloadDigest
        self.validationReport = validationReport
        self.providerAttempt = providerAttempt
    }
}

public enum AIHaplotypingRunFailureStage: String, Codable, Equatable, Sendable {
    case evidence
    case prompt
    case provider
    case decoding
    case runMetadata
    case validation
}

public struct AIHaplotypingRunFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    public let stage: AIHaplotypingRunFailureStage
    public let sanitizedErrorCategory: String
    public let message: String
    public let attemptMetadata: AIProviderAttemptMetadata?
    public let validationReport: AIHaplotypingValidationReport?

    public init(
        stage: AIHaplotypingRunFailureStage,
        sanitizedErrorCategory: String,
        message: String,
        attemptMetadata: AIProviderAttemptMetadata? = nil,
        validationReport: AIHaplotypingValidationReport? = nil
    ) {
        self.stage = stage
        self.sanitizedErrorCategory = sanitizedErrorCategory
        self.message = message
        self.attemptMetadata = attemptMetadata
        self.validationReport = validationReport
    }

    public var errorDescription: String? { message }
}

public struct AIHaplotypingRunner: Sendable {
    public static let schemaName = "lungfish_ai_haplotyping_result"
    public static let minimalMCMSchemaName = "lungfish_mcm_miseq_haplotyping_calls"

    private let provider: any StructuredAIProvider
    private let promptRegistry: AIHaplotypingPromptRegistry
    private let progressHandler: (@Sendable (AIHaplotypingProgressEvent) -> Void)?

    public init(
        provider: any StructuredAIProvider,
        promptRegistry: AIHaplotypingPromptRegistry = .builtIn,
        progressHandler: (@Sendable (AIHaplotypingProgressEvent) -> Void)? = nil
    ) {
        self.provider = provider
        self.promptRegistry = promptRegistry
        self.progressHandler = progressHandler
    }

    public func run(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        options: AIHaplotypingRunOptions
    ) async throws -> AIHaplotypingRunnerOutput {
        let fullRegistry: AIHaplotypingEvidenceRegistry
        do {
            fullRegistry = try AIHaplotypingEvidenceBuilder.build(
                result: result,
                sidecar: sidecar,
                mode: options.mode,
                parentRevisionID: result.manifest.activeHaplotypeAnalysisRevisionID
                    ?? result.haplotypeAnalysis?.analysisRevisionID
            )
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .evidence,
                sanitizedErrorCategory: "evidence_build_failed",
                message: error.localizedDescription
            )
        }
        let registry = Self.registry(fullRegistry, filteredFor: options.reviewScope, result: result)

        let chunks: [AIHaplotypingEvidenceChunk]
        do {
            chunks = try AIHaplotypingEvidenceChunker(
                maxObservationsPerChunk: options.maxObservationsPerChunk
            ).chunks(from: registry)
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .evidence,
                sanitizedErrorCategory: "evidence_chunk_failed",
                message: error.localizedDescription
            )
        }

        let template: AIHaplotypingPromptTemplate
        do {
            if let promptTemplateID = options.promptTemplateID,
               let promptTemplateVersion = options.promptTemplateVersion {
                template = try promptRegistry.template(id: promptTemplateID, version: promptTemplateVersion)
            } else {
                template = try promptRegistry.currentTemplate(for: options.mode)
            }
        } catch {
            throw AIHaplotypingRunFailure(
                stage: .prompt,
                sanitizedErrorCategory: "prompt_template_missing",
                message: error.localizedDescription
            )
        }

        let runContext = AIHaplotypingRunContext.infer(from: result)
        let knowledgePack: AIHaplotypingKnowledgePack?
        if options.includeKnowledgePack {
            do {
                knowledgePack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .prompt,
                    sanitizedErrorCategory: "knowledge_pack_load_failed",
                    message: error.localizedDescription
                )
            }
        } else {
            knowledgePack = nil
        }

        var chunkOutputs: [AIHaplotypingChunkOutput] = []
        var normalizedCalls: [AIHaplotypingValidatedCall] = []
        var validatedDefinitions: [AIHaplotypingValidatedDefinition] = []
        var validationReports: [AIHaplotypingValidationReport] = []
        var providerAttempts: [AIProviderAttemptMetadata] = []
        var seenDefinitionIDs: Set<String> = []
        var seenDefinitionKeys: Set<String> = []

        let selectedChunks = selectedChunkOffsets(from: chunks, options: options)
        let selectedObservationCount = selectedChunks.reduce(0) { total, item in
            total + item.chunk.registry.observations.count
        }
        emit(.runStarted(chunkCount: selectedChunks.count, observationCount: selectedObservationCount))
        for (offset, chunk) in selectedChunks {
            let chunkIndex = offset + 1
            emit(.chunkStarted(
                chunkID: chunk.id,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                observationCount: chunk.registry.observations.count
            ))
            let promptKnowledgePack = knowledgePack.map { pack in
                options.compactKnowledgePack
                    ? AIHaplotypingKnowledgePackRetriever.compact(
                        pack,
                        for: chunk.registry,
                        runContext: runContext
                    )
                    : pack
            }
            let promptMetadata = template.metadata(
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                evidenceSnapshotPath: "ai-haplotyping/evidence/\(chunk.id).json",
                knowledgePack: knowledgePack
            )
            let compactMCMEvidence = Self.usesCompactMCMEvidence(template: template, mode: options.mode)
            let promptCacheRetention = Self.promptCacheRetention(
                template: template,
                options: options,
                provider: provider
            )
            let promptCacheKey = Self.promptCacheKey(
                template: template,
                options: options
            )
            let promptInputPayload: AIHaplotypingPromptInputPayload
            let responseSchemaName = compactMCMEvidence ? Self.minimalMCMSchemaName : Self.schemaName
            let responseSchema = compactMCMEvidence
                ? AIHaplotypingResultSchema.minimalMCMCallSchema()
                : AIHaplotypingResultSchema.jsonSchema()
            let generationParameters = options.generationParameters(
                schemaName: responseSchemaName,
                evidenceEncoding: compactMCMEvidence
                    ? AIHaplotypingPromptInputEncoder.compactMCMEncoding
                    : AIHaplotypingPromptInputEncoder.fullEncoding,
                promptCacheRetention: promptCacheRetention,
                promptCacheKey: promptCacheKey
            )
            let expectedRun = AIHaplotypingRunMetadata(
                mode: options.mode,
                promptTemplateID: template.id,
                promptTemplateVersion: template.version,
                promptHash: template.promptHash,
                provider: options.providerID.rawValue,
                model: provider.modelId,
                generationParameters: generationParameters,
                parentRevisionID: chunk.registry.parentRevisionID,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest
            )
            let request: AIStructuredRequest
            do {
                promptInputPayload = try AIHaplotypingPromptInputEncoder.payload(
                    chunk: chunk,
                    expectedRun: expectedRun,
                    runContext: runContext,
                    knowledgePack: promptKnowledgePack,
                    compactMCMEvidence: compactMCMEvidence
                )
                request = AIStructuredRequest(
                    systemPrompt: template.systemPrompt,
                    userPrompt: template.render(
                        promptInputJSON: promptInputPayload.json,
                        evidenceRegistryJSON: chunk.registry.canonicalJSONString()
                    ),
                    schemaName: responseSchemaName,
                    schema: responseSchema,
                    maxOutputTokens: options.maxOutputTokens,
                    temperature: options.temperature,
                    reasoningEffort: options.reasoningEffort,
                    promptCacheRetention: promptCacheRetention,
                    promptCacheKey: promptCacheKey,
                    attemptIndex: offset,
                    fallbackIndex: 0,
                    credentialSource: options.credentialSource?.rawValue
                )
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .prompt,
                    sanitizedErrorCategory: "prompt_render_failed",
                    message: error.localizedDescription
                )
            }

            let accepted = try await requestValidatedStructuredResultWithRetries(
                request,
                chunk: chunk,
                provider: provider,
                options: options,
                expectedRun: expectedRun,
                evidenceReferenceMap: promptInputPayload.evidenceReferenceMap,
                minimalMCMOutput: compactMCMEvidence
            )
            let response = accepted.response
            let report = accepted.report
            providerAttempts.append(contentsOf: accepted.providerAttempts)
            for definition in report.validatedDefinitions {
                if !seenDefinitionIDs.insert(definition.definitionID).inserted {
                    let reducerReport = reducerRejectedReport(
                        from: report,
                        error: .duplicateDiscoveredDefinition(definition.definitionID)
                    )
                    throw AIHaplotypingRunFailure(
                        stage: .validation,
                        sanitizedErrorCategory: "validation_rejected",
                        message: reducerReport.errors[0].message,
                        attemptMetadata: response.attemptMetadata,
                        validationReport: reducerReport
                    )
                }
                let definitionKey = "\(definition.locus):\(definition.proposedLabel)"
                if !seenDefinitionKeys.insert(definitionKey).inserted {
                    let reducerReport = reducerRejectedReport(
                        from: report,
                        error: .provisionalDefinitionCollision(definitionKey)
                    )
                    throw AIHaplotypingRunFailure(
                        stage: .validation,
                        sanitizedErrorCategory: "validation_rejected",
                        message: reducerReport.errors[0].message,
                        attemptMetadata: response.attemptMetadata,
                        validationReport: reducerReport
                    )
                }
            }

            let payloadDigest = AIHaplotypingCanonicalJSON.sha256Digest(of: response.payload)
            let output = AIHaplotypingChunkOutput(
                chunkID: chunk.id,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                promptMetadata: promptMetadata,
                payloadDigest: payloadDigest,
                validationReport: report,
                providerAttempt: response.attemptMetadata
            )
            chunkOutputs.append(output)
            validationReports.append(report)
            normalizedCalls.append(contentsOf: report.normalizedCalls)
            validatedDefinitions.append(contentsOf: report.validatedDefinitions)
            emit(.chunkFinished(
                chunkID: chunk.id,
                chunkIndex: chunkIndex,
                chunkCount: chunks.count,
                callCount: report.normalizedCalls.count,
                definitionCount: report.validatedDefinitions.count
            ))
        }

        emit(.runFinished(
            chunkCount: selectedChunks.count,
            callCount: normalizedCalls.count,
            definitionCount: validatedDefinitions.count
        ))
        return AIHaplotypingRunnerOutput(
            mode: options.mode,
            registry: registry,
            chunkOutputs: chunkOutputs,
            normalizedCalls: normalizedCalls,
            validatedDefinitions: validatedDefinitions,
            validationReports: validationReports,
            providerAttempts: providerAttempts
        )
    }

    private static func registry(
        _ registry: AIHaplotypingEvidenceRegistry,
        filteredFor scope: AIHaplotypingReviewScope,
        result: ONTGenotypeResultBundleData
    ) -> AIHaplotypingEvidenceRegistry {
        guard scope == .unresolvedOnly, registry.mode == .aiRefinement else {
            return registry
        }
        let targetPairs = unresolvedRefinementPairs(in: result.haplotypeAnalysis)
        guard !targetPairs.isEmpty else {
            return AIHaplotypingEvidenceRegistry(
                schemaVersion: registry.schemaVersion,
                mode: registry.mode,
                parentRevisionID: registry.parentRevisionID,
                inputSnapshotDigest: registry.inputSnapshotDigest,
                samples: [],
                loci: [],
                observations: [],
                currentCalls: [],
                manualReviews: []
            )
        }

        let observations = registry.observations.filter {
            targetPairs.contains(EvidencePair(sampleID: $0.sampleID, locusID: $0.locusID))
        }
        let retainedPairs = Set(observations.map { EvidencePair(sampleID: $0.sampleID, locusID: $0.locusID) })
        let sampleIDs = Set(observations.map(\.sampleID))
        let locusIDs = Set(observations.map(\.locusID))
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: registry.schemaVersion,
            mode: registry.mode,
            parentRevisionID: registry.parentRevisionID,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            samples: registry.samples.filter { sampleIDs.contains($0.id) },
            loci: registry.loci.filter { locusIDs.contains($0.id) },
            observations: observations,
            currentCalls: registry.currentCalls.filter {
                retainedPairs.contains(EvidencePair(sampleID: sampleID(for: $0.sample), locusID: locusID(for: $0.locus)))
            },
            manualReviews: registry.manualReviews.filter {
                retainedPairs.contains(EvidencePair(sampleID: sampleID(for: $0.sample), locusID: locusID(for: $0.locus)))
            }
        )
    }

    private static func unresolvedRefinementPairs(
        in analysis: GenotypeHaplotypeAnalysis?
    ) -> Set<EvidencePair> {
        guard let analysis else { return [] }
        var pairs: Set<EvidencePair> = []
        for sampleAnalysis in analysis.samples {
            let sample = sampleAnalysis.sample.trimmingCharacters(in: .whitespacesAndNewlines)
            for call in sampleAnalysis.calls where callNeedsReview(call) {
                let locus = GenotypeHaplotypeLocusResolver.haplotypeEvidenceLocusName(call.locus)
                pairs.insert(EvidencePair(sampleID: sampleID(for: sample), locusID: locusID(for: locus)))
            }
        }
        return pairs
    }

    private static func callNeedsReview(_ call: GenotypeHaplotypeLocusCall) -> Bool {
        guard call.observedGenotypeCount > 0, call.status != .notAssayed else {
            return false
        }
        if call.status != .called {
            return true
        }
        return labelNeedsReview(call.haplotype1) || labelNeedsReview(call.haplotype2)
    }

    private static func labelNeedsReview(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "-" { return true }
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("err:")
            || lowercased.contains("err:")
            || lowercased == "unresolved"
            || lowercased == "no haplotype"
    }

    private static func sampleID(for sample: String) -> String {
        "sample:\(sample)"
    }

    private static func locusID(for locus: String) -> String {
        "locus:\(locus)"
    }

    private struct EvidencePair: Hashable {
        let sampleID: String
        let locusID: String
    }

    private func selectedChunkOffsets(
        from chunks: [AIHaplotypingEvidenceChunk],
        options: AIHaplotypingRunOptions
    ) -> [(offset: Int, chunk: AIHaplotypingEvidenceChunk)] {
        let start = max(1, options.chunkStartIndex)
        let end = options.chunkEndIndex == 0 ? chunks.count : min(options.chunkEndIndex, chunks.count)
        guard start <= end else {
            return []
        }
        return chunks.enumerated().compactMap { offset, chunk in
            let oneBasedIndex = offset + 1
            guard oneBasedIndex >= start && oneBasedIndex <= end else {
                return nil
            }
            return (offset, chunk)
        }
    }

    private static func usesCompactMCMEvidence(
        template: AIHaplotypingPromptTemplate,
        mode: AIHaplotypingPromptMode
    ) -> Bool {
        AIHaplotypingPromptSelectionResolver.isMCMSpecialistPrompt(
            id: template.id,
            version: template.version,
            mode: mode
        )
    }

    private static func promptCacheRetention(
        template: AIHaplotypingPromptTemplate,
        options: AIHaplotypingRunOptions,
        provider: any StructuredAIProvider
    ) -> String? {
        guard options.providerID == .openAI,
              options.reasoningEffort != nil,
              provider.modelId.lowercased() == "gpt-5.5",
              usesCompactMCMEvidence(template: template, mode: options.mode) else {
            return nil
        }
        return "24h"
    }

    private static func promptCacheKey(
        template: AIHaplotypingPromptTemplate,
        options: AIHaplotypingRunOptions
    ) -> String? {
        guard options.providerID == .openAI,
              usesCompactMCMEvidence(template: template, mode: options.mode) else {
            return nil
        }
        return "mcm-mhc-miseq-specialist-\(template.version.replacingOccurrences(of: ".", with: "-"))"
    }

    private func isRunMetadataFailure(_ report: AIHaplotypingValidationReport) -> Bool {
        guard let firstError = report.errors.first else {
            return false
        }
        switch firstError {
        case .runMetadataMismatch, .chunkIDMismatch, .registryDigestMismatch, .inputSnapshotDigestMismatch:
            return true
        default:
            return false
        }
    }

    private func reducerRejectedReport(
        from acceptedReport: AIHaplotypingValidationReport,
        error: AIHaplotypingValidationError
    ) -> AIHaplotypingValidationReport {
        AIHaplotypingValidationReport(
            accepted: false,
            run: acceptedReport.run,
            chunkID: acceptedReport.chunkID,
            registryDigest: acceptedReport.registryDigest,
            inputSnapshotDigest: acceptedReport.inputSnapshotDigest,
            normalizedCalls: [],
            validatedDefinitions: [],
            warnings: acceptedReport.warnings,
            errors: [error]
        )
    }

    private func providerAttemptMismatch(
        _ attempt: AIProviderAttemptMetadata,
        expectedProvider: String,
        expectedModel: String
    ) -> String? {
        if attempt.provider != expectedProvider {
            return "provider"
        }
        if attempt.model != expectedModel {
            return "model"
        }
        return nil
    }

    private func requestStructuredResultWithRetries(
        _ request: AIStructuredRequest,
        chunkID: String,
        provider: any StructuredAIProvider,
        maxRetries: Int
    ) async throws -> AIStructuredResponse {
        var retriesRemaining = max(0, maxRetries)
        var retryIndex = 0
        while true {
            do {
                return try await provider.requestStructuredResult(request)
            } catch {
                guard retriesRemaining > 0, shouldRetryProviderError(error) else {
                    throw error
                }
                retriesRemaining -= 1
                retryIndex += 1
                emit(.providerRetry(
                    chunkID: chunkID,
                    retryIndex: retryIndex,
                    maxRetries: max(0, maxRetries),
                    errorCategory: sanitizedProviderErrorCategory(error)
                ))
                let delay = retryDelay(for: error)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private func requestValidatedStructuredResultWithRetries(
        _ request: AIStructuredRequest,
        chunk: AIHaplotypingEvidenceChunk,
        provider: any StructuredAIProvider,
        options: AIHaplotypingRunOptions,
        expectedRun: AIHaplotypingRunMetadata,
        evidenceReferenceMap: [String: String],
        minimalMCMOutput: Bool
    ) async throws -> ValidatedStructuredResponse {
        var retriesRemaining = max(0, options.maxProviderRetries)
        var retryIndex = 0
        var providerAttempts: [AIProviderAttemptMetadata] = []

        while true {
            let response: AIStructuredResponse
            do {
                response = try await requestStructuredResultWithRetries(
                    request,
                    chunkID: chunk.id,
                    provider: provider,
                    maxRetries: options.maxProviderRetries
                )
            } catch {
                throw AIHaplotypingRunFailure(
                    stage: .provider,
                    sanitizedErrorCategory: sanitizedProviderErrorCategory(error),
                    message: "AI provider request for \(chunk.id) failed: \(sanitizedProviderFailureMessage(error))"
                )
            }
            providerAttempts.append(response.attemptMetadata)

            if let mismatch = providerAttemptMismatch(
                response.attemptMetadata,
                expectedProvider: options.providerID.rawValue,
                expectedModel: provider.modelId
            ) {
                let report = AIHaplotypingValidationReport(
                    accepted: false,
                    run: expectedRun,
                    chunkID: chunk.id,
                    registryDigest: chunk.registry.digest,
                    inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                    normalizedCalls: [],
                    validatedDefinitions: [],
                    warnings: [],
                    errors: [.runMetadataMismatch(mismatch)]
                )
                if retriesRemaining > 0 {
                    retriesRemaining -= 1
                    retryIndex += 1
                    emit(.providerRetry(
                        chunkID: chunk.id,
                        retryIndex: retryIndex,
                        maxRetries: max(0, options.maxProviderRetries),
                        errorCategory: "provider_attempt_mismatch"
                    ))
                    continue
                }
                throw AIHaplotypingRunFailure(
                    stage: .runMetadata,
                    sanitizedErrorCategory: "provider_attempt_mismatch",
                    message: "AI provider attempt metadata did not match the configured AI haplotyping provider.",
                    attemptMetadata: response.attemptMetadata,
                    validationReport: report
                )
            }

            let structuredResult: AIHaplotypingStructuredResult
            do {
                let data = try JSONEncoder().encode(response.payload)
                if minimalMCMOutput {
                    let minimalResult = try JSONDecoder().decode(AIHaplotypingMinimalMCMResult.self, from: data)
                    structuredResult = self.structuredResult(
                        from: minimalResult,
                        chunk: chunk,
                        expectedRun: expectedRun
                    )
                } else {
                    structuredResult = try JSONDecoder().decode(AIHaplotypingStructuredResult.self, from: data)
                }
            } catch {
                if retriesRemaining > 0 {
                    retriesRemaining -= 1
                    retryIndex += 1
                    emit(.providerRetry(
                        chunkID: chunk.id,
                        retryIndex: retryIndex,
                        maxRetries: max(0, options.maxProviderRetries),
                        errorCategory: "decode_structured_result"
                    ))
                    continue
                }
                throw AIHaplotypingRunFailure(
                    stage: .decoding,
                    sanitizedErrorCategory: "decode_structured_result",
                    message: "AI structured result for \(chunk.id) could not be decoded: \(Self.decodingErrorDescription(error))",
                    attemptMetadata: response.attemptMetadata
                )
            }

            let stampedResult = structuredResultByStampingExpectedRun(
                structuredResult,
                expectedRun: expectedRun
            )
            let validationResult = structuredResultByMappingEvidenceReferences(
                stampedResult,
                evidenceReferenceMap: evidenceReferenceMap
            )
            let report = AIHaplotypingPatchValidator(
                registry: chunk.registry,
                expectedRun: expectedRun,
                expectedChunkID: chunk.id,
                provenancePath: options.provenancePath
            ).validate(validationResult)
            if report.accepted {
                return ValidatedStructuredResponse(
                    response: response,
                    report: report,
                    providerAttempts: providerAttempts
                )
            }

            let stage: AIHaplotypingRunFailureStage
            let category: String
            if isRunMetadataFailure(report) {
                stage = .runMetadata
                category = "run_metadata_mismatch"
            } else {
                stage = .validation
                category = "validation_rejected"
            }
            if retriesRemaining > 0, shouldRetryValidationReport(report) {
                retriesRemaining -= 1
                retryIndex += 1
                emit(.providerRetry(
                    chunkID: chunk.id,
                    retryIndex: retryIndex,
                    maxRetries: max(0, options.maxProviderRetries),
                    errorCategory: category
                ))
                continue
            }
            throw AIHaplotypingRunFailure(
                stage: stage,
                sanitizedErrorCategory: category,
                message: report.errors.first?.message ?? "AI haplotyping structured result was rejected.",
                attemptMetadata: response.attemptMetadata,
                validationReport: report
            )
        }
    }

    private func shouldRetryValidationReport(_ report: AIHaplotypingValidationReport) -> Bool {
        guard let firstError = report.errors.first else { return false }
        switch firstError {
        case .runMetadataMismatch,
             .chunkIDMismatch,
             .registryDigestMismatch,
             .inputSnapshotDigestMismatch,
             .unknownEvidenceID,
             .duplicatePatchOpID,
             .duplicateCallTarget,
             .unsupportedClaim:
            return true
        default:
            return false
        }
    }

    private func structuredResultByStampingExpectedRun(
        _ result: AIHaplotypingStructuredResult,
        expectedRun: AIHaplotypingRunMetadata
    ) -> AIHaplotypingStructuredResult {
        AIHaplotypingStructuredResult(
            schemaVersion: result.schemaVersion,
            run: expectedRun,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            chunkID: result.chunkID,
            discoveredDefinitions: result.discoveredDefinitions,
            calls: result.calls,
            warnings: result.warnings
        )
    }

    private func structuredResult(
        from minimalResult: AIHaplotypingMinimalMCMResult,
        chunk: AIHaplotypingEvidenceChunk,
        expectedRun: AIHaplotypingRunMetadata
    ) -> AIHaplotypingStructuredResult {
        let calls = minimalResult.calls.flatMap { call in
            [
                structuredCall(
                    from: call,
                    slot: "h1",
                    label: call.h1,
                    chunkID: chunk.id,
                    registry: chunk.registry
                ),
                structuredCall(
                    from: call,
                    slot: "h2",
                    label: call.h2,
                    chunkID: chunk.id,
                    registry: chunk.registry
                ),
            ]
        }
        return AIHaplotypingStructuredResult(
            schemaVersion: 1,
            run: expectedRun,
            registryDigest: expectedRun.registryDigest,
            inputSnapshotDigest: expectedRun.inputSnapshotDigest,
            chunkID: chunk.id,
            discoveredDefinitions: [],
            calls: calls,
            warnings: []
        )
    }

    private func structuredCall(
        from call: AIHaplotypingMinimalMCMCall,
        slot: String,
        label: String,
        chunkID: String,
        registry: AIHaplotypingEvidenceRegistry
    ) -> AIHaplotypingStructuredCall {
        let sample = call.sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let locus = call.locus.trimmingCharacters(in: .whitespacesAndNewlines)
        let haplotypeLabel = normalizedMinimalHaplotypeLabel(label)
        let support = isUnresolvedMinimalHaplotypeLabel(haplotypeLabel)
            ? []
            : supportEvidenceReferences(sample: sample, locus: locus, registry: registry)
        let isCalled = !isUnresolvedMinimalHaplotypeLabel(haplotypeLabel) && !support.isEmpty
        let counter = counterevidenceReferences(sample: sample, locus: locus, registry: registry)
        let rationaleCode = isCalled ? "minimal_call" : "minimal_unresolved"
        let rationale = isCalled
            ? (call.h1 == call.h2 ? "Local expansion of minimal LLM call; single haplotype." : "Local expansion of minimal LLM call.")
            : "Local expansion of minimal LLM unresolved slot."
        return AIHaplotypingStructuredCall(
            patchOpID: "patch:\(chunkID):\(sample):\(locus):\(slot):v1",
            sample: sample,
            locus: locus,
            slot: slot,
            haplotypeLabel: haplotypeLabel,
            normalizedFamily: nil,
            source: .ai,
            sourceState: .raw,
            reviewState: .needsReview,
            callState: isCalled ? .called : .unresolved,
            confidenceTier: isCalled ? .medium : .low,
            supportEvidenceRefs: isCalled ? support : [],
            counterevidenceRefs: counter,
            alternates: [],
            rationaleCode: rationaleCode,
            rationale: rationale
        )
    }

    private func normalizedMinimalHaplotypeLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : trimmed
    }

    private func isUnresolvedMinimalHaplotypeLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "?" || trimmed == "-"
    }

    private func supportEvidenceReferences(
        sample: String,
        locus: String,
        registry: AIHaplotypingEvidenceRegistry
    ) -> [String] {
        let samplesByID = Dictionary(uniqueKeysWithValues: registry.samples.map { ($0.id, $0.sample) })
        let lociByID = Dictionary(uniqueKeysWithValues: registry.loci.map { ($0.id, $0.locus) })
        let direct = registry.observations.filter {
            samplesByID[$0.sampleID] == sample && lociByID[$0.locusID] == locus
        }.map(\.id)
        if !direct.isEmpty { return direct }
        return registry.observations.filter {
            samplesByID[$0.sampleID] == sample
                && GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus(lociByID[$0.locusID] ?? "")
        }.map(\.id)
    }

    private func counterevidenceReferences(
        sample: String,
        locus: String,
        registry: AIHaplotypingEvidenceRegistry
    ) -> [String] {
        if let sampleID = registry.samples.first(where: { $0.sample == sample })?.id {
            return [sampleID]
        }
        if let locusID = registry.loci.first(where: { $0.locus == locus })?.id {
            return [locusID]
        }
        return []
    }

    private func structuredResultByMappingEvidenceReferences(
        _ result: AIHaplotypingStructuredResult,
        evidenceReferenceMap: [String: String]
    ) -> AIHaplotypingStructuredResult {
        guard !evidenceReferenceMap.isEmpty else { return result }
        let definitions = result.discoveredDefinitions.map { definition in
            AIHaplotypingDiscoveredDefinition(
                definitionID: definition.definitionID,
                locus: definition.locus,
                proposedLabel: definition.proposedLabel,
                normalizedFamily: definition.normalizedFamily,
                supportEvidenceRefs: mapEvidenceReferences(definition.supportEvidenceRefs, using: evidenceReferenceMap),
                counterevidenceRefs: mapEvidenceReferences(definition.counterevidenceRefs, using: evidenceReferenceMap),
                confidenceTier: definition.confidenceTier,
                rationaleCode: definition.rationaleCode,
                rationale: definition.rationale
            )
        }
        let calls = result.calls.map { call in
            AIHaplotypingStructuredCall(
                patchOpID: call.patchOpID,
                sample: call.sample,
                locus: call.locus,
                slot: call.slot,
                haplotypeLabel: call.haplotypeLabel,
                normalizedFamily: call.normalizedFamily,
                source: call.source,
                sourceState: call.sourceState,
                reviewState: call.reviewState,
                callState: call.callState,
                confidenceTier: call.confidenceTier,
                supportEvidenceRefs: mapEvidenceReferences(call.supportEvidenceRefs, using: evidenceReferenceMap),
                counterevidenceRefs: mapEvidenceReferences(call.counterevidenceRefs, using: evidenceReferenceMap),
                alternates: call.alternates,
                rationaleCode: call.rationaleCode,
                rationale: call.rationale
            )
        }
        return AIHaplotypingStructuredResult(
            schemaVersion: result.schemaVersion,
            run: result.run,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            chunkID: result.chunkID,
            discoveredDefinitions: definitions,
            calls: calls,
            warnings: result.warnings
        )
    }

    private func mapEvidenceReferences(
        _ references: [String],
        using evidenceReferenceMap: [String: String]
    ) -> [String] {
        references.map { evidenceReferenceMap[$0] ?? $0 }
    }

    private func emit(_ event: AIHaplotypingProgressEvent) {
        progressHandler?(event)
    }

    private func shouldRetryProviderError(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else {
            return false
        }
        switch providerError {
        case .networkError, .rateLimited, .invalidResponse:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500 && statusCode < 600
        case .missingAPIKey,
             .quotaExceeded,
             .modelNotAvailable,
             .contextTooLong,
             .decodingError:
            return false
        }
    }

    private func retryDelay(for error: Error) -> UInt64 {
        guard let providerError = error as? AIProviderError else {
            return 0
        }
        guard case .rateLimited(let retryAfter) = providerError,
              let retryAfter,
              retryAfter > 0 else {
            return 0
        }
        let cappedSeconds = min(retryAfter, 5)
        return UInt64(cappedSeconds * 1_000_000_000)
    }

    private func sanitizedProviderErrorCategory(_ error: Error) -> String {
        guard let providerError = error as? AIProviderError else {
            return "provider_error"
        }
        switch providerError {
        case .missingAPIKey:
            return "missing_api_key"
        case .invalidResponse:
            return "invalid_response"
        case .httpError:
            return "http_error"
        case .rateLimited:
            return "rate_limited"
        case .quotaExceeded:
            return "quota_exceeded"
        case .modelNotAvailable:
            return "model_not_available"
        case .contextTooLong:
            return "context_too_long"
        case .networkError:
            return "network_error"
        case .decodingError:
            return "decoding_error"
        }
    }

    private func sanitizedProviderFailureMessage(_ error: Error) -> String {
        guard let providerError = error as? AIProviderError else {
            return "AI provider request failed."
        }
        switch providerError {
        case .missingAPIKey:
            return "AI provider API key is not configured."
        case .invalidResponse(let detail):
            return "AI provider returned an invalid structured response: \(detail)"
        case .httpError:
            return "AI provider returned an HTTP error."
        case .rateLimited:
            return "Rate limited by AI provider. Try again later."
        case .quotaExceeded:
            return "AI provider quota is exhausted. Check provider billing or use another configured provider."
        case .modelNotAvailable:
            return "Configured AI model is not available."
        case .contextTooLong:
            return "AI haplotyping prompt exceeded the provider context limit."
        case .networkError(let detail):
            return "AI provider network request failed: \(detail)"
        case .decodingError:
            return "AI provider response could not be decoded."
        }
    }

    private static func decodingErrorDescription(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ codingPath: [CodingKey]) -> String {
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "<root>" : value
        }
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing key at \(path(context.codingPath + [key])): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "data corrupted at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private struct ValidatedStructuredResponse {
        let response: AIStructuredResponse
        let report: AIHaplotypingValidationReport
        let providerAttempts: [AIProviderAttemptMetadata]
    }
}
