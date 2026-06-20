import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingPromptPreviewRequest: Sendable {
    public let result: ONTGenotypeResultBundleData
    public let sidecar: GenotypeAnnotationSidecar?
    public let mode: AIHaplotypingPromptMode
    public let providerID: AIHaplotypingProviderID
    public let modelID: String
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

    public init(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        mode: AIHaplotypingPromptMode,
        providerID: AIHaplotypingProviderID,
        modelID: String,
        credentialSource: AIHaplotypingCredentialSource? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        maxObservationsPerChunk: Int = 1,
        maxOutputTokens: Int = 4096,
        temperature: Double = 0,
        reasoningEffort: String? = nil,
        maxProviderRetries: Int = 2,
        provenancePath: String = AIHaplotypingPatchValidator.pendingProvenancePath,
        compactKnowledgePack: Bool = false,
        includeKnowledgePack: Bool = true
    ) {
        self.result = result
        self.sidecar = sidecar
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.credentialSource = credentialSource
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.maxObservationsPerChunk = max(1, maxObservationsPerChunk)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = max(0, min(2, temperature))
        let trimmedReasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = trimmedReasoningEffort.isEmpty ? nil : trimmedReasoningEffort
        self.maxProviderRetries = max(0, maxProviderRetries)
        self.provenancePath = provenancePath
        self.compactKnowledgePack = compactKnowledgePack
        self.includeKnowledgePack = includeKnowledgePack
    }
}

public struct AIHaplotypingPromptPreview: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let promptTemplate: AIHaplotypingPromptPreviewTemplateSummary
    public let knowledgePack: AIHaplotypingPromptPreviewKnowledgePackSummary?
    public let runContext: AIHaplotypingRunContext
    public let chunkCount: Int
    public let observationCount: Int
    public let chunks: [AIHaplotypingPromptPreviewChunk]

    public init(
        mode: AIHaplotypingPromptMode,
        promptTemplate: AIHaplotypingPromptPreviewTemplateSummary,
        knowledgePack: AIHaplotypingPromptPreviewKnowledgePackSummary?,
        runContext: AIHaplotypingRunContext,
        chunkCount: Int,
        observationCount: Int,
        chunks: [AIHaplotypingPromptPreviewChunk]
    ) {
        self.mode = mode
        self.promptTemplate = promptTemplate
        self.knowledgePack = knowledgePack
        self.runContext = runContext
        self.chunkCount = chunkCount
        self.observationCount = observationCount
        self.chunks = chunks
    }
}

public struct AIHaplotypingPromptPreviewTemplateSummary: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let hash: String

    public init(id: String, version: String, hash: String) {
        self.id = id
        self.version = version
        self.hash = hash
    }
}

public struct AIHaplotypingPromptPreviewKnowledgePackSummary: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let digest: String
    public let populationProfileCount: Int
    public let alleleRecordCount: Int
    public let haplotypeBlockDefinitionCount: Int

    public init(
        id: String,
        version: String,
        digest: String,
        populationProfileCount: Int,
        alleleRecordCount: Int,
        haplotypeBlockDefinitionCount: Int
    ) {
        self.id = id
        self.version = version
        self.digest = digest
        self.populationProfileCount = populationProfileCount
        self.alleleRecordCount = alleleRecordCount
        self.haplotypeBlockDefinitionCount = haplotypeBlockDefinitionCount
    }
}

public struct AIHaplotypingPromptPreviewChunk: Codable, Equatable, Sendable {
    public let chunkID: String
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let promptMetadata: AIHaplotypingPromptMetadata
    public let systemPrompt: String
    public let userPrompt: String
    public let evidenceRegistry: AIHaplotypingEvidenceRegistry

    public init(
        chunkID: String,
        registryDigest: String,
        inputSnapshotDigest: String,
        promptMetadata: AIHaplotypingPromptMetadata,
        systemPrompt: String,
        userPrompt: String,
        evidenceRegistry: AIHaplotypingEvidenceRegistry
    ) {
        self.chunkID = chunkID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.promptMetadata = promptMetadata
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.evidenceRegistry = evidenceRegistry
    }
}

public struct AIHaplotypingPromptPreviewBuilder: Sendable {
    private let promptRegistry: AIHaplotypingPromptRegistry

    public init(promptRegistry: AIHaplotypingPromptRegistry = .builtIn) {
        self.promptRegistry = promptRegistry
    }

    public func build(_ request: AIHaplotypingPromptPreviewRequest) throws -> AIHaplotypingPromptPreview {
        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: request.result,
            sidecar: request.sidecar,
            mode: request.mode,
            parentRevisionID: request.result.manifest.activeHaplotypeAnalysisRevisionID
                ?? request.result.haplotypeAnalysis?.analysisRevisionID
        )
        let chunks = try AIHaplotypingEvidenceChunker(
            maxObservationsPerChunk: request.maxObservationsPerChunk
        ).chunks(from: registry)
        let template = try promptTemplate(
            id: request.promptTemplateID,
            version: request.promptTemplateVersion,
            mode: request.mode
        )
        let runContext = AIHaplotypingRunContext.infer(from: request.result)
        let knowledgePack = request.includeKnowledgePack
            ? try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
            : nil
        let options = AIHaplotypingRunOptions(
            mode: request.mode,
            providerID: request.providerID,
            credentialSource: request.credentialSource,
            promptTemplateID: request.promptTemplateID,
            promptTemplateVersion: request.promptTemplateVersion,
            maxObservationsPerChunk: request.maxObservationsPerChunk,
            maxOutputTokens: request.maxOutputTokens,
            temperature: request.temperature,
            reasoningEffort: request.reasoningEffort,
            maxProviderRetries: request.maxProviderRetries,
            provenancePath: request.provenancePath,
            compactKnowledgePack: request.compactKnowledgePack,
            includeKnowledgePack: request.includeKnowledgePack
        )

        let previewChunks = try chunks.map { chunk in
            let promptKnowledgePack = knowledgePack.map { pack in
                request.compactKnowledgePack
                    ? AIHaplotypingKnowledgePackRetriever.compact(
                        pack,
                        for: chunk.registry,
                        runContext: runContext
                    )
                    : pack
            }
            let compactMCMEvidence = AIHaplotypingPromptSelectionResolver.isMCMSpecialistPrompt(
                id: template.id,
                version: template.version,
                mode: request.mode
            )
            let expectedRun = AIHaplotypingRunMetadata(
                mode: request.mode,
                promptTemplateID: template.id,
                promptTemplateVersion: template.version,
                promptHash: template.promptHash,
                provider: request.providerID.rawValue,
                model: request.modelID,
                generationParameters: options.generationParameters(
                    schemaName: AIHaplotypingRunner.schemaName,
                    evidenceEncoding: compactMCMEvidence
                        ? AIHaplotypingPromptInputEncoder.compactMCMEncoding
                        : AIHaplotypingPromptInputEncoder.fullEncoding,
                    promptCacheRetention: Self.promptCacheRetention(
                        template: template,
                        request: request
                    ),
                    promptCacheKey: Self.promptCacheKey(
                        template: template,
                        request: request
                    )
                ),
                parentRevisionID: chunk.registry.parentRevisionID,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest
            )
            let promptMetadata = template.metadata(
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                evidenceSnapshotPath: "ai-haplotyping/evidence/\(chunk.id).json",
                knowledgePack: knowledgePack
            )
            let promptInputPayload = try AIHaplotypingPromptInputEncoder.payload(
                chunk: chunk,
                expectedRun: expectedRun,
                runContext: runContext,
                knowledgePack: promptKnowledgePack,
                compactMCMEvidence: compactMCMEvidence
            )
            return AIHaplotypingPromptPreviewChunk(
                chunkID: chunk.id,
                registryDigest: chunk.registry.digest,
                inputSnapshotDigest: chunk.registry.inputSnapshotDigest,
                promptMetadata: promptMetadata,
                systemPrompt: template.systemPrompt,
                userPrompt: template.render(
                    promptInputJSON: promptInputPayload.json,
                    evidenceRegistryJSON: chunk.registry.canonicalJSONString()
                ),
                evidenceRegistry: chunk.registry
            )
        }

        return AIHaplotypingPromptPreview(
            mode: request.mode,
            promptTemplate: AIHaplotypingPromptPreviewTemplateSummary(
                id: template.id,
                version: template.version,
                hash: template.promptHash
            ),
            knowledgePack: knowledgePack.map {
                AIHaplotypingPromptPreviewKnowledgePackSummary(
                    id: $0.id,
                    version: $0.version,
                    digest: $0.digest,
                    populationProfileCount: $0.populationProfiles.count,
                    alleleRecordCount: $0.alleleRecords.count,
                    haplotypeBlockDefinitionCount: $0.haplotypeBlockDefinitions.count
                )
            },
            runContext: runContext,
            chunkCount: previewChunks.count,
            observationCount: registry.observations.count,
            chunks: previewChunks
        )
    }

    private func promptTemplate(
        id: String?,
        version: String?,
        mode: AIHaplotypingPromptMode
    ) throws -> AIHaplotypingPromptTemplate {
        if let id, let version {
            return try promptRegistry.template(id: id, version: version)
        }
        return try promptRegistry.currentTemplate(for: mode)
    }

    private static func promptCacheRetention(
        template: AIHaplotypingPromptTemplate,
        request: AIHaplotypingPromptPreviewRequest
    ) -> String? {
        guard request.providerID == .openAI,
              request.reasoningEffort != nil,
              request.modelID.lowercased() == "gpt-5.5",
              AIHaplotypingPromptSelectionResolver.isMCMSpecialistPrompt(
                id: template.id,
                version: template.version,
                mode: request.mode
              ) else {
            return nil
        }
        return "24h"
    }

    private static func promptCacheKey(
        template: AIHaplotypingPromptTemplate,
        request: AIHaplotypingPromptPreviewRequest
    ) -> String? {
        guard request.providerID == .openAI,
              AIHaplotypingPromptSelectionResolver.isMCMSpecialistPrompt(
                id: template.id,
                version: template.version,
                mode: request.mode
              ) else {
            return nil
        }
        return "mcm-mhc-miseq-specialist-\(template.version.replacingOccurrences(of: ".", with: "-"))"
    }
}
