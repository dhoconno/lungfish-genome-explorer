import Foundation
import LungfishCore

public struct GenotypeHaplotypeDefinitionRegistry: Codable, Equatable, Sendable {
    public let assays: [GenotypeHaplotypeAssay]
    public let defaultDefinitionSetID: String?

    public init(
        assays: [GenotypeHaplotypeAssay],
        defaultDefinitionSetID: String? = nil
    ) {
        self.assays = assays
        self.defaultDefinitionSetID = defaultDefinitionSetID
    }

    public func assay(id: String) -> GenotypeHaplotypeAssay? {
        assays.first { $0.id == id }
    }

    public func definitionSets(assayID: String, speciesCode: String? = nil) -> [GenotypeHaplotypeDefinitionSet] {
        guard let assay = assay(id: assayID) else { return [] }
        guard let speciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speciesCode.isEmpty else {
            return assay.definitionSets
        }
        return assay.definitionSets.filter {
            $0.speciesCode.caseInsensitiveCompare(speciesCode) == .orderedSame
        }
    }

    public func definitionSet(id: String, assayID: String?) -> GenotypeHaplotypeDefinitionSet? {
        guard let assayID = assayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assayID.isEmpty else {
            return definitionSet(id: id)
        }
        return definitionSets(assayID: assayID).first { $0.id == id }
    }

    public func definitionSets(id: String) -> [GenotypeHaplotypeDefinitionSet] {
        assays.flatMap(\.definitionSets).filter { $0.id == id }
    }

    public func definitionSet(id: String) -> GenotypeHaplotypeDefinitionSet? {
        assays.lazy.flatMap(\.definitionSets).first { $0.id == id }
    }
}

public struct GenotypeHaplotypeAssay: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let definitionSets: [GenotypeHaplotypeDefinitionSet]

    public init(
        id: String,
        displayName: String,
        definitionSets: [GenotypeHaplotypeDefinitionSet]
    ) {
        self.id = id
        self.displayName = displayName
        self.definitionSets = definitionSets
    }
}

public struct GenotypeHaplotypeDefinitionSet: Codable, Equatable, Sendable {
    public let id: String
    public let assayID: String
    public let displayName: String
    public let speciesName: String
    public let speciesCode: String
    public let prefix: String
    public let locusDefinitions: [GenotypeHaplotypeLocusDefinition]
    /// Optional schema version for the set itself. Bumped each time the
    /// editor saves a change so downstream artifacts (LabKey export,
    /// provenance JSON) can record which version of the definition was
    /// used to make a call. nil for built-in sets that ship with Lungfish
    /// at the app's release version.
    public let schemaVersion: Int?
    /// ISO-8601 timestamp of the last edit. nil for built-in sets.
    public let lastModified: String?
    /// Free-text description of the change. Useful for explaining "added
    /// MHC-B alleles from pbaa.xlsx row 109" in the provenance trail.
    public let changeNote: String?

    private enum CodingKeys: String, CodingKey {
        case id, assayID, displayName, speciesName, speciesCode, prefix, locusDefinitions
        case schemaVersion, lastModified, changeNote
    }

    public init(
        id: String,
        assayID: String,
        displayName: String,
        speciesName: String,
        speciesCode: String,
        prefix: String,
        locusDefinitions: [GenotypeHaplotypeLocusDefinition],
        schemaVersion: Int? = nil,
        lastModified: String? = nil,
        changeNote: String? = nil
    ) {
        self.id = id
        self.assayID = assayID
        self.displayName = displayName
        self.speciesName = speciesName
        self.speciesCode = speciesCode
        self.prefix = prefix
        self.locusDefinitions = locusDefinitions
        self.schemaVersion = schemaVersion
        self.lastModified = lastModified
        self.changeNote = changeNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.assayID = try container.decodeIfPresent(String.self, forKey: .assayID)
            ?? GenotypeHaplotypeAssayIDResolver.assayID(forDefinitionSetID: id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.speciesName = try container.decode(String.self, forKey: .speciesName)
        self.speciesCode = try container.decode(String.self, forKey: .speciesCode)
        self.prefix = try container.decode(String.self, forKey: .prefix)
        self.locusDefinitions = try container.decode([GenotypeHaplotypeLocusDefinition].self, forKey: .locusDefinitions)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        self.lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        self.changeNote = try container.decodeIfPresent(String.self, forKey: .changeNote)
    }
}

public struct GenotypeHaplotypeLocusDefinition: Codable, Equatable, Sendable {
    public let locus: String
    public let sourceLocus: String
    public let haplotypes: [GenotypeHaplotypeDefinition]

    public init(
        locus: String,
        sourceLocus: String,
        haplotypes: [GenotypeHaplotypeDefinition]
    ) {
        self.locus = locus
        self.sourceLocus = sourceLocus
        self.haplotypes = haplotypes
    }
}

public struct GenotypeHaplotypeDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let diagnosticAlleles: [String]
    public let primaryAlleles: [String]?
    public let evidenceWeights: [String: Double]?
    public let colorTokenIndex: Int
    public let colorOverride: AnnotationColor?
    /// Minimum number of `diagnosticAlleles` that must be observed for
    /// this haplotype to match. `nil` means "all" (the strict notebook
    /// rule). Use a smaller integer when supplying multi-family
    /// supporting alleles so the call still succeeds when one or two
    /// families dropped out — this lets the inspector use rich
    /// diagnostic lists from the pbaa.xlsx workbook without requiring
    /// every single allele to be present.
    public let minimumMatches: Int?

    public init(
        name: String,
        diagnosticAlleles: [String],
        primaryAlleles: [String]? = nil,
        evidenceWeights: [String: Double]? = nil,
        colorTokenIndex: Int? = nil,
        colorOverride: AnnotationColor? = nil,
        minimumMatches: Int? = nil
    ) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.primaryAlleles = primaryAlleles
        self.evidenceWeights = evidenceWeights
        self.colorTokenIndex = colorTokenIndex ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
        self.colorOverride = colorOverride
        self.minimumMatches = minimumMatches
    }

    public init(
        name: String,
        diagnosticAlleles: [String],
        colorTokenIndex: Int? = nil,
        minimumMatches: Int? = nil
    ) {
        self.init(
            name: name,
            diagnosticAlleles: diagnosticAlleles,
            primaryAlleles: nil,
            evidenceWeights: nil,
            colorTokenIndex: colorTokenIndex,
            colorOverride: nil,
            minimumMatches: minimumMatches
        )
    }

    public init(
        name: String,
        diagnosticAlleles: [String],
        colorTokenIndex: Int? = nil,
        colorOverride: AnnotationColor?,
        minimumMatches: Int? = nil
    ) {
        self.init(
            name: name,
            diagnosticAlleles: diagnosticAlleles,
            primaryAlleles: nil,
            evidenceWeights: nil,
            colorTokenIndex: colorTokenIndex,
            colorOverride: colorOverride,
            minimumMatches: minimumMatches
        )
    }

    /// Effective threshold for matching: `minimumMatches` when set,
    /// otherwise the full diagnostic-allele count (the strict rule).
    public var effectiveMinimumMatches: Int {
        if let minimumMatches { return max(1, min(minimumMatches, diagnosticAlleles.count)) }
        return diagnosticAlleles.count
    }

    public var primaryAllelesForDominance: [String] {
        guard let primaryAlleles, !primaryAlleles.isEmpty else {
            return diagnosticAlleles
        }
        return primaryAlleles
    }

    public var effectiveFillColor: AnnotationColor {
        if let colorOverride {
            return colorOverride
        }
        guard HaplotypeColorToken.canonicalPalette.indices.contains(colorTokenIndex) else {
            return HaplotypeColorToken.assigned(forName: name).fillColor
        }
        return HaplotypeColorToken.canonicalPalette[colorTokenIndex].fillColor
    }

    private enum CodingKeys: String, CodingKey {
        case name, diagnosticAlleles, primaryAlleles, evidenceWeights, colorTokenIndex, colorOverride, minimumMatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let diagnosticAlleles = try container.decode([String].self, forKey: .diagnosticAlleles)
        let colorTokenIndex = try container.decodeIfPresent(Int.self, forKey: .colorTokenIndex)
            ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.primaryAlleles = try container.decodeIfPresent([String].self, forKey: .primaryAlleles)
        self.evidenceWeights = try container.decodeIfPresent([String: Double].self, forKey: .evidenceWeights)
        self.colorTokenIndex = colorTokenIndex
        self.colorOverride = try container.decodeIfPresent(AnnotationColor.self, forKey: .colorOverride)
        self.minimumMatches = try container.decodeIfPresent(Int.self, forKey: .minimumMatches)
    }
}

public enum GenotypeHaplotypeCallStatus: String, Codable, Equatable, Sendable {
    case called
    case notAssayed
    case noHaplotype
    case tooManyHaplotypes
    case tooManyGenotypes
    case specialCase
}

public enum GenotypeHaplotypeAnalysisSource: String, Codable, Equatable, Sendable {
    case legacy
    case deterministic
    case manual
    case ai
}

public enum GenotypeHaplotypeAICallSourceState: String, Codable, Equatable, Sendable {
    case raw
    case deterministic
    case manual
    case current
}

public enum GenotypeHaplotypeAICallReviewState: String, Codable, Equatable, Sendable {
    case needsReview
    case reviewed
    case confirmed
    case rejected
}

public enum GenotypeHaplotypeAICallState: String, Codable, Equatable, Sendable {
    case called
    case novelCandidate = "novel_candidate"
    case ambiguousTie = "ambiguous_tie"
    case insufficientEvidence = "insufficient_evidence"
    case lowSupportOrDropout = "low_support_or_dropout"
    case conflictsCurrent = "conflicts_current"
    case conflictsManual = "conflicts_manual"
    case retainCurrent = "retain_current"
    case notAssayed = "not_assayed"
    case outOfScope = "out_of_scope"
    case unresolved
}

public enum GenotypeHaplotypeAIConfidenceTier: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public struct GenotypeHaplotypeAICallMetadata: Codable, Equatable, Sendable {
    public let patchOpID: String
    public let source: GenotypeHaplotypeAnalysisSource
    public let sourceState: GenotypeHaplotypeAICallSourceState
    public let reviewState: GenotypeHaplotypeAICallReviewState
    public let callState: GenotypeHaplotypeAICallState
    public let confidenceTier: GenotypeHaplotypeAIConfidenceTier
    public let proposedHaplotypeLabel: String?
    public let supportEvidenceRefs: [String]
    public let counterevidenceRefs: [String]
    public let alternates: [String]
    public let rationaleCode: String
    public let rationale: String
    public let provenancePath: String

    public init(
        patchOpID: String,
        source: GenotypeHaplotypeAnalysisSource,
        sourceState: GenotypeHaplotypeAICallSourceState,
        reviewState: GenotypeHaplotypeAICallReviewState,
        callState: GenotypeHaplotypeAICallState,
        confidenceTier: GenotypeHaplotypeAIConfidenceTier,
        proposedHaplotypeLabel: String? = nil,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String],
        alternates: [String],
        rationaleCode: String,
        rationale: String,
        provenancePath: String
    ) {
        self.patchOpID = patchOpID
        self.source = source
        self.sourceState = sourceState
        self.reviewState = reviewState
        self.callState = callState
        self.confidenceTier = confidenceTier
        self.proposedHaplotypeLabel = proposedHaplotypeLabel
        self.supportEvidenceRefs = supportEvidenceRefs
        self.counterevidenceRefs = counterevidenceRefs
        self.alternates = alternates
        self.rationaleCode = rationaleCode
        self.rationale = rationale
        self.provenancePath = provenancePath
    }
}

public struct GenotypeHaplotypeAISlotMetadata: Codable, Equatable, Sendable {
    public let slot: HaplotypeSlot
    public let metadata: GenotypeHaplotypeAICallMetadata

    public init(slot: HaplotypeSlot, metadata: GenotypeHaplotypeAICallMetadata) {
        self.slot = slot
        self.metadata = metadata
    }
}

public struct GenotypeHaplotypeMatchedDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let diagnosticAlleles: [String]
    public let observedDiagnosticAlleles: [String]

    public init(
        name: String,
        diagnosticAlleles: [String],
        observedDiagnosticAlleles: [String]
    ) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.observedDiagnosticAlleles = observedDiagnosticAlleles
    }
}

public struct GenotypeHaplotypeLocusCall: Codable, Equatable, Sendable {
    public let locus: String
    public let sourceLocus: String
    public let haplotype1: String
    public let haplotype2: String
    public let status: GenotypeHaplotypeCallStatus
    public let matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition]
    public let observedGenotypeCount: Int
    public let observedGenotypes: [String]
    public let notes: String
    public let aiMetadata: GenotypeHaplotypeAICallMetadata?
    public let aiSlotMetadata: [GenotypeHaplotypeAISlotMetadata]

    private enum CodingKeys: String, CodingKey {
        case locus
        case sourceLocus
        case haplotype1
        case haplotype2
        case status
        case matchedHaplotypes
        case observedGenotypeCount
        case observedGenotypes
        case notes
        case aiMetadata
        case aiSlotMetadata
    }

    public init(
        locus: String,
        sourceLocus: String,
        haplotype1: String,
        haplotype2: String,
        status: GenotypeHaplotypeCallStatus,
        matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition],
        observedGenotypeCount: Int,
        observedGenotypes: [String],
        notes: String = "",
        aiMetadata: GenotypeHaplotypeAICallMetadata?,
        aiSlotMetadata: [GenotypeHaplotypeAISlotMetadata] = []
    ) {
        self.locus = locus
        self.sourceLocus = sourceLocus
        self.haplotype1 = haplotype1
        self.haplotype2 = haplotype2
        self.status = status
        self.matchedHaplotypes = matchedHaplotypes
        self.observedGenotypeCount = observedGenotypeCount
        self.observedGenotypes = observedGenotypes
        self.notes = notes
        self.aiMetadata = aiMetadata
        self.aiSlotMetadata = aiSlotMetadata
    }

    public init(
        locus: String,
        sourceLocus: String,
        haplotype1: String,
        haplotype2: String,
        status: GenotypeHaplotypeCallStatus,
        matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition],
        observedGenotypeCount: Int,
        observedGenotypes: [String],
        notes: String = ""
    ) {
        self.init(
            locus: locus,
            sourceLocus: sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: status,
            matchedHaplotypes: matchedHaplotypes,
            observedGenotypeCount: observedGenotypeCount,
            observedGenotypes: observedGenotypes,
            notes: notes,
            aiMetadata: nil,
            aiSlotMetadata: []
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.locus = try container.decode(String.self, forKey: .locus)
        self.sourceLocus = try container.decode(String.self, forKey: .sourceLocus)
        self.haplotype1 = try container.decode(String.self, forKey: .haplotype1)
        self.haplotype2 = try container.decode(String.self, forKey: .haplotype2)
        self.status = try container.decode(GenotypeHaplotypeCallStatus.self, forKey: .status)
        self.matchedHaplotypes = try container.decode(
            [GenotypeHaplotypeMatchedDefinition].self,
            forKey: .matchedHaplotypes
        )
        self.observedGenotypeCount = try container.decode(Int.self, forKey: .observedGenotypeCount)
        self.observedGenotypes = try container.decode([String].self, forKey: .observedGenotypes)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.aiMetadata = try container.decodeIfPresent(GenotypeHaplotypeAICallMetadata.self, forKey: .aiMetadata)
        self.aiSlotMetadata = try container.decodeIfPresent(
            [GenotypeHaplotypeAISlotMetadata].self,
            forKey: .aiSlotMetadata
        ) ?? []
    }
}

public struct GenotypeHaplotypeSampleAnalysis: Codable, Equatable, Sendable {
    public let sample: String
    public let calls: [GenotypeHaplotypeLocusCall]

    public init(sample: String, calls: [GenotypeHaplotypeLocusCall]) {
        self.sample = sample
        self.calls = calls
    }
}

public struct GenotypeHaplotypeAnalysis: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let assayID: String
    public let definitionSetID: String
    public let definitionSetName: String
    public let speciesName: String
    public let generatedAt: String?
    public let analysisRevisionID: String?
    public let source: GenotypeHaplotypeAnalysisSource
    public let samples: [GenotypeHaplotypeSampleAnalysis]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, assayID, definitionSetID, definitionSetName, speciesName, generatedAt
        case analysisRevisionID, source, samples
    }

    public init(
        schemaVersion: Int = 1,
        assayID: String,
        definitionSetID: String,
        definitionSetName: String,
        speciesName: String,
        generatedAt: String? = nil,
        analysisRevisionID: String? = nil,
        source: GenotypeHaplotypeAnalysisSource = .deterministic,
        samples: [GenotypeHaplotypeSampleAnalysis]
    ) {
        self.schemaVersion = schemaVersion
        self.assayID = assayID
        self.definitionSetID = definitionSetID
        self.definitionSetName = definitionSetName
        self.speciesName = speciesName
        self.generatedAt = generatedAt
        self.analysisRevisionID = analysisRevisionID
        self.source = source
        self.samples = samples
    }

    public init(
        schemaVersion: Int = 1,
        assayID: String,
        definitionSetID: String,
        definitionSetName: String,
        speciesName: String,
        generatedAt: String? = nil,
        samples: [GenotypeHaplotypeSampleAnalysis]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            assayID: assayID,
            definitionSetID: definitionSetID,
            definitionSetName: definitionSetName,
            speciesName: speciesName,
            generatedAt: generatedAt,
            analysisRevisionID: nil,
            source: .deterministic,
            samples: samples
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definitionSetID = try container.decode(String.self, forKey: .definitionSetID)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.assayID = try container.decodeIfPresent(String.self, forKey: .assayID)
            ?? GenotypeHaplotypeAssayIDResolver.assayID(forDefinitionSetID: definitionSetID)
        self.definitionSetID = definitionSetID
        self.definitionSetName = try container.decode(String.self, forKey: .definitionSetName)
        self.speciesName = try container.decode(String.self, forKey: .speciesName)
        self.generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        self.analysisRevisionID = try container.decodeIfPresent(String.self, forKey: .analysisRevisionID)
        self.source = try container.decodeIfPresent(GenotypeHaplotypeAnalysisSource.self, forKey: .source) ?? .legacy
        self.samples = try container.decode([GenotypeHaplotypeSampleAnalysis].self, forKey: .samples)
    }
}

private enum GenotypeHaplotypeAssayIDResolver {
    static let defaultAssayID = "MHC-exon2-miSeq"

    static func assayID(forDefinitionSetID id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.firstIndex(of: ".") {
            let prefix = String(trimmed[..<separator])
            if prefix == defaultAssayID {
                return defaultAssayID
            }
        }
        return defaultAssayID
    }
}
