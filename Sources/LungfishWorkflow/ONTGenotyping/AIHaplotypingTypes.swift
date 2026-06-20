import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingMode: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case deterministic
    case ai
}

public enum AIHaplotypingPromptMode: String, Codable, CaseIterable, Equatable, Sendable {
    case aiDiscovery
    case aiRefinement
}

public enum AIHaplotypingProviderID: String, Codable, CaseIterable, Equatable, Sendable {
    case openAI = "openai"
    case anthropic
}

public enum AIHaplotypingCredentialSource: String, Codable, CaseIterable, Equatable, Sendable {
    case environmentOpenAI = "environment:OPENAI_API_KEY"
    case environmentAzureOpenAI = "environment:AZURE_OPENAI_API_KEY"
    case environmentAnthropic = "environment:ANTHROPIC_API_KEY"
    case keychainOpenAI = "keychain:ai.openai.apiKey"
    case keychainAnthropic = "keychain:ai.anthropic.apiKey"
}

public struct AIHaplotypingPromptTemplate: Codable, Equatable, Sendable {
    public let id: String
    public let mode: AIHaplotypingPromptMode
    public let version: String
    public let evidenceSchemaVersion: Int
    public let systemPrompt: String
    public let userPromptTemplate: String

    public init(
        id: String,
        mode: AIHaplotypingPromptMode,
        version: String,
        evidenceSchemaVersion: Int,
        systemPrompt: String,
        userPromptTemplate: String
    ) {
        self.id = id
        self.mode = mode
        self.version = version
        self.evidenceSchemaVersion = evidenceSchemaVersion
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
    }

    public var promptHash: String {
        AIHaplotypingCanonicalJSON.sha256Digest(of: CanonicalPromptTemplate(
            id: id,
            mode: mode.rawValue,
            version: version,
            evidenceSchemaVersion: evidenceSchemaVersion,
            systemPrompt: systemPrompt,
            userPromptTemplate: userPromptTemplate
        ))
    }

    public var hash: String { promptHash }

    public func render(evidenceRegistryJSON: String) -> String {
        render(promptInputJSON: evidenceRegistryJSON, evidenceRegistryJSON: evidenceRegistryJSON)
    }

    public func render(promptInputJSON: String, evidenceRegistryJSON: String) -> String {
        let evidenceReplacement = userPromptTemplate.contains("{{prompt_input_json}}")
            ? evidenceRegistryJSON
            : promptInputJSON
        return userPromptTemplate
            .replacingOccurrences(of: "{{prompt_input_json}}", with: promptInputJSON)
            .replacingOccurrences(of: "{{evidence_registry_json}}", with: evidenceReplacement)
    }

    public func metadata(
        registryDigest: String,
        inputSnapshotDigest: String,
        evidenceSnapshotPath: String,
        knowledgePack: AIHaplotypingKnowledgePack? = nil
    ) -> AIHaplotypingPromptMetadata {
        AIHaplotypingPromptMetadata(
            promptTemplateID: id,
            promptTemplateVersion: version,
            promptHash: promptHash,
            evidenceSchemaVersion: evidenceSchemaVersion,
            registryDigest: registryDigest,
            inputSnapshotDigest: inputSnapshotDigest,
            evidenceSnapshotPath: evidenceSnapshotPath,
            knowledgePackID: knowledgePack?.id,
            knowledgePackVersion: knowledgePack?.version,
            knowledgePackDigest: knowledgePack?.digest
        )
    }

    struct CanonicalPromptTemplate: Encodable {
        let id: String
        let mode: String
        let version: String
        let evidenceSchemaVersion: Int
        let systemPrompt: String
        let userPromptTemplate: String
    }
}

public struct AIHaplotypingPromptMetadata: Codable, Equatable, Sendable {
    public let promptTemplateID: String
    public let promptTemplateVersion: String
    public let promptHash: String
    public let evidenceSchemaVersion: Int
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let evidenceSnapshotPath: String
    public let knowledgePackID: String?
    public let knowledgePackVersion: String?
    public let knowledgePackDigest: String?

    public init(
        promptTemplateID: String,
        promptTemplateVersion: String,
        promptHash: String,
        evidenceSchemaVersion: Int,
        registryDigest: String,
        inputSnapshotDigest: String,
        evidenceSnapshotPath: String,
        knowledgePackID: String? = nil,
        knowledgePackVersion: String? = nil,
        knowledgePackDigest: String? = nil
    ) {
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.promptHash = promptHash
        self.evidenceSchemaVersion = evidenceSchemaVersion
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.evidenceSnapshotPath = evidenceSnapshotPath
        self.knowledgePackID = knowledgePackID
        self.knowledgePackVersion = knowledgePackVersion
        self.knowledgePackDigest = knowledgePackDigest
    }
}

public enum AIHaplotypingEvidenceClass: String, Codable, CaseIterable, Equatable, Sendable {
    case directObservation = "direct_observation"
    case coverageSummary = "coverage_summary"
    case cohortRecurrence = "cohort_recurrence"
    case dropoutSignal = "dropout_signal"
    case overcallSignal = "overcall_signal"
    case deterministicCall = "deterministic_call"
    case manualReview = "manual_review"
    case currentAICall = "current_ai_call"
}

public struct SampleEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let sample: String

    public init(id: String, sample: String) {
        self.id = id
        self.sample = sample
    }
}

public struct LocusEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let locus: String

    public init(id: String, locus: String) {
        self.id = id
        self.locus = locus
    }
}

public struct ObservationEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let evidenceClass: AIHaplotypingEvidenceClass
    public let sampleID: String
    public let locusID: String
    public let genotype: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleUniqueRetainedReads: Int?

    public init(
        id: String,
        evidenceClass: AIHaplotypingEvidenceClass,
        sampleID: String,
        locusID: String,
        genotype: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleUniqueRetainedReads: Int?
    ) {
        self.id = id
        self.evidenceClass = evidenceClass
        self.sampleID = sampleID
        self.locusID = locusID
        self.genotype = genotype
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleUniqueRetainedReads = sampleUniqueRetainedReads
    }
}

public struct CurrentCallEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let sample: String
    public let locus: String
    public let slot: String
    public let haplotypeLabel: String
    public let source: GenotypeHaplotypeAnalysisSource
    public let parentRevisionID: String?

    public init(
        id: String,
        sample: String,
        locus: String,
        slot: String,
        haplotypeLabel: String,
        source: GenotypeHaplotypeAnalysisSource,
        parentRevisionID: String?
    ) {
        self.id = id
        self.sample = sample
        self.locus = locus
        self.slot = slot
        self.haplotypeLabel = haplotypeLabel
        self.source = source
        self.parentRevisionID = parentRevisionID
    }

    public init(
        id: String,
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        haplotypeLabel: String,
        source: GenotypeHaplotypeAnalysisSource,
        parentRevisionID: String?
    ) {
        self.init(
            id: id,
            sample: sample,
            locus: locus,
            slot: slot.rawValue,
            haplotypeLabel: haplotypeLabel,
            source: source,
            parentRevisionID: parentRevisionID
        )
    }
}

public struct ManualReviewEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let sample: String
    public let locus: String
    public let slot: String
    public let overrideCall: String
    public let rationale: String

    public init(
        id: String,
        sample: String,
        locus: String,
        slot: String,
        overrideCall: String,
        rationale: String
    ) {
        self.id = id
        self.sample = sample
        self.locus = locus
        self.slot = slot
        self.overrideCall = overrideCall
        self.rationale = rationale
    }

    public init(
        id: String,
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        overrideCall: String,
        rationale: String
    ) {
        self.init(
            id: id,
            sample: sample,
            locus: locus,
            slot: slot.rawValue,
            overrideCall: overrideCall,
            rationale: rationale
        )
    }
}

public struct AIHaplotypingEvidenceRegistry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mode: AIHaplotypingPromptMode
    public let parentRevisionID: String?
    public let digest: String
    public let inputSnapshotDigest: String
    public let samples: [SampleEvidence]
    public let loci: [LocusEvidence]
    public let observations: [ObservationEvidence]
    public let currentCalls: [CurrentCallEvidence]
    public let manualReviews: [ManualReviewEvidence]

    public init(
        schemaVersion: Int = 1,
        mode: AIHaplotypingPromptMode,
        parentRevisionID: String?,
        inputSnapshotDigest: String,
        samples: [SampleEvidence],
        loci: [LocusEvidence],
        observations: [ObservationEvidence],
        currentCalls: [CurrentCallEvidence] = [],
        manualReviews: [ManualReviewEvidence] = [],
        digest: String? = nil
    ) {
        let sortedSamples = samples.sorted { $0.id < $1.id }
        let sortedLoci = loci.sorted { $0.id < $1.id }
        let sortedObservations = observations.sorted { $0.id < $1.id }
        let sortedCurrentCalls = currentCalls.sorted { $0.id < $1.id }
        let sortedManualReviews = manualReviews.sorted { $0.id < $1.id }

        self.schemaVersion = schemaVersion
        self.mode = mode
        self.parentRevisionID = parentRevisionID
        self.inputSnapshotDigest = inputSnapshotDigest
        self.samples = sortedSamples
        self.loci = sortedLoci
        self.observations = sortedObservations
        self.currentCalls = sortedCurrentCalls
        self.manualReviews = sortedManualReviews
        self.digest = digest ?? Self.computeDigest(
            schemaVersion: schemaVersion,
            mode: mode,
            parentRevisionID: parentRevisionID,
            inputSnapshotDigest: inputSnapshotDigest,
            samples: sortedSamples,
            loci: sortedLoci,
            observations: sortedObservations,
            currentCalls: sortedCurrentCalls,
            manualReviews: sortedManualReviews
        )
    }

    public static func computeDigest(
        schemaVersion: Int,
        mode: AIHaplotypingPromptMode,
        parentRevisionID: String?,
        inputSnapshotDigest: String,
        samples: [SampleEvidence],
        loci: [LocusEvidence],
        observations: [ObservationEvidence],
        currentCalls: [CurrentCallEvidence],
        manualReviews: [ManualReviewEvidence]
    ) -> String {
        AIHaplotypingCanonicalJSON.sha256Digest(of: DigestPayload(
            schemaVersion: schemaVersion,
            mode: mode,
            parentRevisionID: parentRevisionID,
            inputSnapshotDigest: inputSnapshotDigest,
            samples: samples,
            loci: loci,
            observations: observations,
            currentCalls: currentCalls,
            manualReviews: manualReviews
        ))
    }

    private struct DigestPayload: Encodable {
        let schemaVersion: Int
        let mode: AIHaplotypingPromptMode
        let parentRevisionID: String?
        let inputSnapshotDigest: String
        let samples: [SampleEvidence]
        let loci: [LocusEvidence]
        let observations: [ObservationEvidence]
        let currentCalls: [CurrentCallEvidence]
        let manualReviews: [ManualReviewEvidence]
    }
}

public struct AIHaplotypingEvidenceChunk: Codable, Equatable, Sendable {
    public let id: String
    public let registry: AIHaplotypingEvidenceRegistry
    public let allowedEvidenceIDs: [String]

    public init(
        id: String,
        registry: AIHaplotypingEvidenceRegistry,
        allowedEvidenceIDs: Set<String>
    ) {
        self.id = id
        self.registry = registry
        self.allowedEvidenceIDs = allowedEvidenceIDs.sorted()
    }

    public init(
        id: String,
        registry: AIHaplotypingEvidenceRegistry,
        allowedEvidenceIDs: [String]
    ) {
        self.init(id: id, registry: registry, allowedEvidenceIDs: Set(allowedEvidenceIDs))
    }
}

enum AIHaplotypingCanonicalJSON {
    static func sha256Digest<T: Encodable>(of value: T) -> String {
        "sha256:\(sha256Hex(canonicalData(of: value)))"
    }

    static func canonicalData<T: Encodable>(of value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            preconditionFailure("Failed to encode canonical AI haplotyping JSON: \(error)")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension AIHaplotypingEvidenceRegistry {
    func canonicalJSONString() -> String {
        String(data: AIHaplotypingCanonicalJSON.canonicalData(of: self), encoding: .utf8) ?? "{}"
    }

    var evidenceIDs: [String] {
        (
            samples.map(\.id)
                + loci.map(\.id)
                + observations.map(\.id)
                + currentCalls.map(\.id)
                + manualReviews.map(\.id)
        ).sorted()
    }
}
