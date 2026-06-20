import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingRunMetadata: Codable, Equatable, Sendable {
    public let mode: AIHaplotypingPromptMode
    public let promptTemplateID: String
    public let promptTemplateVersion: String
    public let promptHash: String
    public let provider: String
    public let model: String
    public let generationParameters: [String: String]
    public let parentRevisionID: String?
    public let registryDigest: String
    public let inputSnapshotDigest: String

    public init(
        mode: AIHaplotypingPromptMode,
        promptTemplateID: String,
        promptTemplateVersion: String,
        promptHash: String,
        provider: String,
        model: String,
        generationParameters: [String: String],
        parentRevisionID: String?,
        registryDigest: String,
        inputSnapshotDigest: String
    ) {
        self.mode = mode
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.promptHash = promptHash
        self.provider = provider
        self.model = model
        self.generationParameters = generationParameters
        self.parentRevisionID = parentRevisionID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
    }
}

public struct AIHaplotypingStructuredResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let run: AIHaplotypingRunMetadata
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let chunkID: String?
    public let discoveredDefinitions: [AIHaplotypingDiscoveredDefinition]
    public let calls: [AIHaplotypingStructuredCall]
    public let warnings: [String]

    public init(
        schemaVersion: Int,
        run: AIHaplotypingRunMetadata,
        registryDigest: String,
        inputSnapshotDigest: String,
        chunkID: String?,
        discoveredDefinitions: [AIHaplotypingDiscoveredDefinition],
        calls: [AIHaplotypingStructuredCall],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.run = run
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.chunkID = chunkID
        self.discoveredDefinitions = discoveredDefinitions
        self.calls = calls
        self.warnings = warnings
    }
}

public struct AIHaplotypingStructuredCall: Codable, Equatable, Sendable {
    public let patchOpID: String
    public let sample: String
    public let locus: String
    public let slot: String
    public let haplotypeLabel: String
    public let normalizedFamily: String?
    public let source: GenotypeHaplotypeAnalysisSource
    public let sourceState: GenotypeHaplotypeAICallSourceState
    public let reviewState: GenotypeHaplotypeAICallReviewState
    public let callState: GenotypeHaplotypeAICallState
    public let confidenceTier: GenotypeHaplotypeAIConfidenceTier
    public let supportEvidenceRefs: [String]
    public let counterevidenceRefs: [String]
    public let alternates: [String]
    public let rationaleCode: String
    public let rationale: String

    public init(
        patchOpID: String,
        sample: String,
        locus: String,
        slot: String,
        haplotypeLabel: String,
        normalizedFamily: String?,
        source: GenotypeHaplotypeAnalysisSource,
        sourceState: GenotypeHaplotypeAICallSourceState,
        reviewState: GenotypeHaplotypeAICallReviewState,
        callState: GenotypeHaplotypeAICallState,
        confidenceTier: GenotypeHaplotypeAIConfidenceTier,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String],
        alternates: [String],
        rationaleCode: String,
        rationale: String
    ) {
        self.patchOpID = patchOpID
        self.sample = sample
        self.locus = locus
        self.slot = slot
        self.haplotypeLabel = haplotypeLabel
        self.normalizedFamily = normalizedFamily
        self.source = source
        self.sourceState = sourceState
        self.reviewState = reviewState
        self.callState = callState
        self.confidenceTier = confidenceTier
        self.supportEvidenceRefs = supportEvidenceRefs
        self.counterevidenceRefs = counterevidenceRefs
        self.alternates = alternates
        self.rationaleCode = rationaleCode
        self.rationale = rationale
    }
}

public struct AIHaplotypingDiscoveredDefinition: Codable, Equatable, Sendable {
    public let definitionID: String
    public let locus: String
    public let proposedLabel: String
    public let normalizedFamily: String?
    public let supportEvidenceRefs: [String]
    public let counterevidenceRefs: [String]
    public let confidenceTier: GenotypeHaplotypeAIConfidenceTier
    public let rationaleCode: String
    public let rationale: String

    public init(
        definitionID: String,
        locus: String,
        proposedLabel: String,
        normalizedFamily: String?,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String],
        confidenceTier: GenotypeHaplotypeAIConfidenceTier,
        rationaleCode: String,
        rationale: String
    ) {
        self.definitionID = definitionID
        self.locus = locus
        self.proposedLabel = proposedLabel
        self.normalizedFamily = normalizedFamily
        self.supportEvidenceRefs = supportEvidenceRefs
        self.counterevidenceRefs = counterevidenceRefs
        self.confidenceTier = confidenceTier
        self.rationaleCode = rationaleCode
        self.rationale = rationale
    }
}

public struct AIHaplotypingValidatedCall: Codable, Equatable, Sendable {
    public let patchOpID: String
    public let sample: String
    public let locus: String
    public let slot: String
    public let status: GenotypeHaplotypeCallStatus
    public let primaryHaplotypeLabel: String?
    public let proposedHaplotypeLabel: String
    public let aiMetadata: GenotypeHaplotypeAICallMetadata
    public let supportEvidenceRefs: [String]
    public let counterevidenceRefs: [String]

    public init(
        patchOpID: String,
        sample: String,
        locus: String,
        slot: String,
        status: GenotypeHaplotypeCallStatus,
        primaryHaplotypeLabel: String?,
        proposedHaplotypeLabel: String,
        aiMetadata: GenotypeHaplotypeAICallMetadata,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String]
    ) {
        self.patchOpID = patchOpID
        self.sample = sample
        self.locus = locus
        self.slot = slot
        self.status = status
        self.primaryHaplotypeLabel = primaryHaplotypeLabel
        self.proposedHaplotypeLabel = proposedHaplotypeLabel
        self.aiMetadata = aiMetadata
        self.supportEvidenceRefs = supportEvidenceRefs
        self.counterevidenceRefs = counterevidenceRefs
    }
}

public struct AIHaplotypingValidatedDefinition: Codable, Equatable, Sendable {
    public let definitionID: String
    public let locus: String
    public let proposedLabel: String
    public let normalizedFamily: String?
    public let supportEvidenceRefs: [String]
    public let counterevidenceRefs: [String]
    public let confidenceTier: GenotypeHaplotypeAIConfidenceTier

    public init(
        definitionID: String,
        locus: String,
        proposedLabel: String,
        normalizedFamily: String?,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String],
        confidenceTier: GenotypeHaplotypeAIConfidenceTier
    ) {
        self.definitionID = definitionID
        self.locus = locus
        self.proposedLabel = proposedLabel
        self.normalizedFamily = normalizedFamily
        self.supportEvidenceRefs = supportEvidenceRefs
        self.counterevidenceRefs = counterevidenceRefs
        self.confidenceTier = confidenceTier
    }
}

public struct AIHaplotypingValidationReport: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let run: AIHaplotypingRunMetadata?
    public let chunkID: String?
    public let registryDigest: String?
    public let inputSnapshotDigest: String?
    public let normalizedCalls: [AIHaplotypingValidatedCall]
    public let validatedDefinitions: [AIHaplotypingValidatedDefinition]
    public let warnings: [String]
    public let errors: [AIHaplotypingValidationError]

    public init(
        accepted: Bool,
        run: AIHaplotypingRunMetadata? = nil,
        chunkID: String? = nil,
        registryDigest: String? = nil,
        inputSnapshotDigest: String? = nil,
        normalizedCalls: [AIHaplotypingValidatedCall],
        validatedDefinitions: [AIHaplotypingValidatedDefinition],
        warnings: [String],
        errors: [AIHaplotypingValidationError]
    ) {
        self.accepted = accepted
        self.run = run
        self.chunkID = chunkID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.normalizedCalls = normalizedCalls
        self.validatedDefinitions = validatedDefinitions
        self.warnings = warnings
        self.errors = errors
    }
}

public enum AIHaplotypingResultSchema {
    public static func jsonSchema() -> [String: JSONValue] {
        closedObject([
            "schemaVersion": integerEnum([1]),
            "run": runSchema(),
            "registryDigest": stringSchema(),
            "inputSnapshotDigest": stringSchema(),
            "chunkID": nullableStringSchema(),
            "discoveredDefinitions": arraySchema(discoveredDefinitionSchema(), maxItems: 256),
            "calls": arraySchema(callSchema(), maxItems: 2_048),
            "warnings": stringArray(maxItems: 128),
        ])
    }

    private static func runSchema() -> JSONValue {
        .object(closedObject([
            "mode": stringEnum(AIHaplotypingPromptMode.allCases.map(\.rawValue)),
            "promptTemplateID": stringSchema(),
            "promptTemplateVersion": stringSchema(),
            "promptHash": stringSchema(),
            "provider": stringSchema(),
            "model": stringSchema(),
            "generationParameters": generationParametersSchema(),
            "parentRevisionID": nullableStringSchema(),
            "registryDigest": stringSchema(),
            "inputSnapshotDigest": stringSchema(),
        ]))
    }

    private static func callSchema() -> JSONValue {
        .object(closedObject([
            "patchOpID": nonEmptyStringSchema(),
            "sample": stringSchema(),
            "locus": stringSchema(),
            "slot": stringEnum(["h1", "h2"]),
            "haplotypeLabel": stringSchema(),
            "normalizedFamily": nullableStringSchema(),
            "source": stringEnum([GenotypeHaplotypeAnalysisSource.ai.rawValue]),
            "sourceState": stringEnum(aiCallSourceStateRawValues),
            "reviewState": stringEnum([GenotypeHaplotypeAICallReviewState.needsReview.rawValue]),
            "callState": stringEnum(aiCallStateRawValues),
            "confidenceTier": stringEnum(aiConfidenceTierRawValues),
            "supportEvidenceRefs": stringArray(maxItems: 64),
            "counterevidenceRefs": stringArray(maxItems: 64),
            "alternates": stringArray(maxItems: 16),
            "rationaleCode": stringSchema(),
            "rationale": stringSchema(),
        ]))
    }

    private static func discoveredDefinitionSchema() -> JSONValue {
        .object(closedObject([
            "definitionID": nonEmptyStringSchema(),
            "locus": stringSchema(),
            "proposedLabel": stringSchema(),
            "normalizedFamily": nullableStringSchema(),
            "supportEvidenceRefs": stringArray(maxItems: 64),
            "counterevidenceRefs": stringArray(maxItems: 64),
            "confidenceTier": stringEnum(aiConfidenceTierRawValues),
            "rationaleCode": stringSchema(),
            "rationale": stringSchema(),
        ]))
    }

    private static func closedObject(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
        ]
    }

    private static func stringSchema() -> JSONValue {
        .object([
            "type": .string("string"),
            "maxLength": .integer(4_096),
        ])
    }

    private static func nonEmptyStringSchema() -> JSONValue {
        .object([
            "type": .string("string"),
            "minLength": .integer(1),
            "maxLength": .integer(4_096),
        ])
    }

    private static func nullableStringSchema() -> JSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "maxLength": .integer(4_096),
        ])
    }

    private static func stringEnum(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.sorted().map(JSONValue.string)),
        ])
    }

    private static func integerEnum(_ values: [Int]) -> JSONValue {
        .object([
            "type": .string("integer"),
            "enum": .array(values.map(JSONValue.integer)),
        ])
    }

    private static func stringArray(maxItems: Int) -> JSONValue {
        arraySchema(stringSchema(), maxItems: maxItems)
    }

    private static func arraySchema(_ items: JSONValue, maxItems: Int) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "maxItems": .integer(maxItems),
        ])
    }

    private static func generationParametersSchema() -> JSONValue {
        .object(closedObject([
            "chunkEndIndex": stringSchema(),
            "chunkStartIndex": stringSchema(),
            "compactKnowledgePack": stringSchema(),
            "maxObservationsPerChunk": stringSchema(),
            "maxOutputTokens": stringSchema(),
            "maxProviderRetries": stringSchema(),
            "reasoningEffort": stringSchema(),
            "reviewScope": stringSchema(),
            "schemaName": stringSchema(),
            "temperature": stringSchema(),
        ]))
    }

    private static let aiCallSourceStateRawValues = [
        GenotypeHaplotypeAICallSourceState.raw.rawValue,
        GenotypeHaplotypeAICallSourceState.deterministic.rawValue,
        GenotypeHaplotypeAICallSourceState.manual.rawValue,
        GenotypeHaplotypeAICallSourceState.current.rawValue,
    ]

    private static let aiCallStateRawValues = [
        GenotypeHaplotypeAICallState.called.rawValue,
        GenotypeHaplotypeAICallState.novelCandidate.rawValue,
        GenotypeHaplotypeAICallState.ambiguousTie.rawValue,
        GenotypeHaplotypeAICallState.insufficientEvidence.rawValue,
        GenotypeHaplotypeAICallState.lowSupportOrDropout.rawValue,
        GenotypeHaplotypeAICallState.conflictsCurrent.rawValue,
        GenotypeHaplotypeAICallState.conflictsManual.rawValue,
        GenotypeHaplotypeAICallState.notAssayed.rawValue,
        GenotypeHaplotypeAICallState.outOfScope.rawValue,
        GenotypeHaplotypeAICallState.unresolved.rawValue,
    ]

    private static let aiConfidenceTierRawValues = [
        GenotypeHaplotypeAIConfidenceTier.high.rawValue,
        GenotypeHaplotypeAIConfidenceTier.medium.rawValue,
        GenotypeHaplotypeAIConfidenceTier.low.rawValue,
    ]
}
