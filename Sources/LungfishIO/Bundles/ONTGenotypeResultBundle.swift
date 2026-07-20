import CryptoKit
import Darwin
import Foundation

public enum ONTGenotypeWorkbookRevisionRole: String, Codable, CaseIterable, Equatable, Sendable {
    case initialCurrentCopy = "initial-current-copy"
    case imported
    case restored
    case externalEditSnapshot = "external-edit-snapshot"
    case aiRefinement = "ai-refinement"
}

public enum ONTGenotypeHaplotypeAnalysisMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case deterministic
    case aiDiscovery
    case aiRefinement
}

public enum ONTGenotypeHaplotypeAnalysisReviewState: String, Codable, CaseIterable, Equatable, Sendable {
    case unreviewed
    case needsReview
    case reviewed
    case confirmed
    case rejected
}

public struct ONTGenotypeHaplotypeAnalysisRevision: Codable, Equatable, Sendable {
    public let id: String
    public let method: ONTGenotypeHaplotypeAnalysisMethod
    public let path: String
    public let predecessorID: String?
    public let predecessorPath: String?
    public let createdAt: String
    public let reviewState: ONTGenotypeHaplotypeAnalysisReviewState
    public let sha256: String
    public let sizeBytes: Int64
    public let provenancePath: String
    public let provider: String?
    public let model: String?
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let promptHash: String?
    public let promptSnapshotPath: String?
    public let evidenceSnapshotPath: String?
    public let validationReportPath: String?

    public init(
        id: String,
        method: ONTGenotypeHaplotypeAnalysisMethod,
        path: String,
        predecessorID: String? = nil,
        predecessorPath: String? = nil,
        createdAt: String,
        reviewState: ONTGenotypeHaplotypeAnalysisReviewState,
        sha256: String,
        sizeBytes: Int64,
        provenancePath: String,
        provider: String? = nil,
        model: String? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        promptHash: String? = nil,
        promptSnapshotPath: String? = nil,
        evidenceSnapshotPath: String? = nil,
        validationReportPath: String? = nil
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.predecessorID = predecessorID
        self.predecessorPath = predecessorPath
        self.createdAt = createdAt
        self.reviewState = reviewState
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.provenancePath = provenancePath
        self.provider = provider
        self.model = model
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.promptHash = promptHash
        self.promptSnapshotPath = promptSnapshotPath
        self.evidenceSnapshotPath = evidenceSnapshotPath
        self.validationReportPath = validationReportPath
    }
}

public struct ONTGenotypeWorkbookRevision: Codable, Equatable, Sendable {
    public let id: String
    public let role: ONTGenotypeWorkbookRevisionRole
    public let path: String
    public let label: String
    public let sourceFilename: String?
    public let createdAt: String
    public let user: String?
    public let predecessorID: String?
    public let predecessorPath: String?
    public let sha256: String
    public let sizeBytes: Int64
    public let provenancePath: String?

    public init(
        id: String,
        role: ONTGenotypeWorkbookRevisionRole,
        path: String,
        label: String,
        sourceFilename: String? = nil,
        createdAt: String,
        user: String? = nil,
        predecessorID: String? = nil,
        predecessorPath: String? = nil,
        sha256: String,
        sizeBytes: Int64,
        provenancePath: String? = nil
    ) {
        self.id = id
        self.role = role
        self.path = path
        self.label = label
        self.sourceFilename = sourceFilename
        self.createdAt = createdAt
        self.user = user
        self.predecessorID = predecessorID
        self.predecessorPath = predecessorPath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.provenancePath = provenancePath
    }
}

public struct ONTGenotypeResultBundleManifest: Codable, Equatable, Sendable {
    public static let filename = "genotype-result.json"

    public let schemaVersion: Int
    public let kind: String
    public let outputName: String
    public let analysisName: String
    public let primaryWorkbookPath: String
    public let currentWorkbookPath: String?
    public let workbookRevisions: [ONTGenotypeWorkbookRevision]?
    public let longSummaryCSVPath: String
    public let sampleSummaryCSVPath: String
    public let statsJSONPath: String
    public let provenancePath: String
    public let deduplicatedUnmatchedClustersFASTAPath: String?
    public let haplotypeAnalysisPath: String?
    public let activeHaplotypeAnalysisRevisionID: String?
    public let haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]?
    public let haplotypeDefinitionSetID: String?
    public let haplotypeAssayID: String?
    public let presetID: String?
    public let presetVersion: String?
    public let createdAt: String?
    public let mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest?

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.outputName = outputName
        self.analysisName = analysisName
        self.primaryWorkbookPath = primaryWorkbookPath
        self.currentWorkbookPath = currentWorkbookPath
        self.workbookRevisions = workbookRevisions
        self.longSummaryCSVPath = longSummaryCSVPath
        self.sampleSummaryCSVPath = sampleSummaryCSVPath
        self.statsJSONPath = statsJSONPath
        self.provenancePath = provenancePath
        self.deduplicatedUnmatchedClustersFASTAPath = deduplicatedUnmatchedClustersFASTAPath
        self.haplotypeAnalysisPath = haplotypeAnalysisPath
        self.activeHaplotypeAnalysisRevisionID = activeHaplotypeAnalysisRevisionID
        self.haplotypeAnalysisRevisions = haplotypeAnalysisRevisions
        self.haplotypeDefinitionSetID = haplotypeDefinitionSetID
        self.haplotypeAssayID = haplotypeAssayID
        self.presetID = presetID
        self.presetVersion = presetVersion
        self.createdAt = createdAt
        self.mhcCandidateArtifacts = mhcCandidateArtifacts
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        currentWorkbookPath: String? = nil,
        workbookRevisions: [ONTGenotypeWorkbookRevision]? = nil,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: workbookRevisions,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: nil,
            haplotypeAnalysisRevisions: nil,
            mhcCandidateArtifacts: mhcCandidateArtifacts
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            currentWorkbookPath: nil,
            workbookRevisions: nil,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: mhcCandidateArtifacts
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        deduplicatedUnmatchedClustersFASTAPath: String? = nil,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: nil,
            haplotypeAnalysisRevisions: nil,
            mhcCandidateArtifacts: mhcCandidateArtifacts
        )
    }

    public init(
        schemaVersion: Int = 1,
        kind: String = "ont-barcode-genotype",
        outputName: String,
        analysisName: String,
        primaryWorkbookPath: String,
        longSummaryCSVPath: String,
        sampleSummaryCSVPath: String,
        statsJSONPath: String,
        provenancePath: String,
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil
    ) {
        self.init(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            primaryWorkbookPath: primaryWorkbookPath,
            longSummaryCSVPath: longSummaryCSVPath,
            sampleSummaryCSVPath: sampleSummaryCSVPath,
            statsJSONPath: statsJSONPath,
            provenancePath: provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: nil,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: nil,
            haplotypeAnalysisRevisions: nil,
            mhcCandidateArtifacts: mhcCandidateArtifacts
        )
    }
}

public enum ONTGenotypeQCStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case ok
    case lowSupport
    case review

    public var displayName: String {
        switch self {
        case .ok:
            return "OK"
        case .lowSupport:
            return "Low Support"
        case .review:
            return "Review"
        }
    }
}

public struct ONTGenotypeCall: Codable, Equatable, Sendable {
    public let sample: String
    public let genotype: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleTotalReads: Int?
    public let sampleUniqueRetainedReads: Int?
    public let sampleUniqueRetainedPercent: Double?
    public let overallInputReads: Int?
    public let overallUniqueRetainedReads: Int?
    public let overallUniqueRetainedPercent: Double?

    public init(
        sample: String,
        genotype: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleTotalReads: Int?,
        sampleUniqueRetainedReads: Int?,
        sampleUniqueRetainedPercent: Double?,
        overallInputReads: Int?,
        overallUniqueRetainedReads: Int?,
        overallUniqueRetainedPercent: Double?
    ) {
        self.sample = sample
        self.genotype = genotype
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleTotalReads = sampleTotalReads
        self.sampleUniqueRetainedReads = sampleUniqueRetainedReads
        self.sampleUniqueRetainedPercent = sampleUniqueRetainedPercent
        self.overallInputReads = overallInputReads
        self.overallUniqueRetainedReads = overallUniqueRetainedReads
        self.overallUniqueRetainedPercent = overallUniqueRetainedPercent
    }

    public var haplotypeTokens: [String] {
        Self.inferHaplotypeTokens(from: genotype)
    }

    public var locusToken: String? {
        Self.inferLocusToken(from: genotype)
    }

    public var locusGroup: String {
        guard let token = locusToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return "Unknown"
        }
        if let classIILocusGroup = Self.preciseClassIILocusGroup(from: token) {
            return classIILocusGroup
        }
        return GenotypeHaplotypeLocusResolver.canonicalLocusName(token)
    }

    private static func genotypeParts(_ genotype: String) -> [String] {
        var parts = genotype
            .split(separator: "_", omittingEmptySubsequences: true)
            .map(String.init)
        if let first = parts.first, first.allSatisfy(\.isNumber) {
            parts.removeFirst()
        }
        return parts
    }

    private static func inferHaplotypeTokens(from genotype: String) -> [String] {
        guard let first = genotypeParts(genotype).first else { return [] }
        var matches: [String] = []
        var seen = Set<String>()
        var index = first.startIndex
        while index < first.endIndex {
            guard first[index] == "M" else {
                index = first.index(after: index)
                continue
            }
            var end = first.index(after: index)
            let numberStart = end
            while end < first.endIndex, first[end].isNumber {
                end = first.index(after: end)
            }
            if numberStart < end {
                let token = String(first[index..<end])
                if seen.insert(token).inserted {
                    matches.append(token)
                }
                index = end
            } else {
                index = first.index(after: index)
            }
        }
        return matches
    }

    private static func inferLocusToken(from genotype: String) -> String? {
        let parts = genotypeParts(genotype)
        guard !parts.isEmpty else { return nil }
        if !inferHaplotypeTokens(from: genotype).isEmpty, parts.count > 1 {
            return cleanLocusToken(parts[1])
        }
        if isSpeciesToken(parts[0]), parts.count > 1 {
            return cleanLocusToken(parts[1])
        }
        return cleanLocusToken(parts[0])
    }

    private static func cleanLocusToken(_ token: String) -> String {
        let aliasFree = token.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? token
        return aliasFree.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSpeciesToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "mafa", "mamu", "mane", "mafu", "mnem", "mfas", "mton", "mleu", "mthi",
            "macaque", "macaca",
        ].contains(normalized)
    }

    private static func preciseClassIILocusGroup(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let speciesFree = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? trimmed
        let uppercased = speciesFree.uppercased()
        for prefix in ["DQA", "DQB", "DPA", "DPB"] where uppercased.hasPrefix(prefix) {
            let suffix = uppercased.dropFirst(prefix.count)
            guard suffix.first?.isNumber == true else { return nil }
            let digits = suffix.prefix(while: \.isNumber)
            return "MHC-\(prefix)\(digits)"
        }
        return nil
    }
}

public struct ONTGenotypeSampleSupport: Codable, Equatable, Sendable {
    public let sample: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleUniqueRetainedReads: Int?

    public init(
        sample: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleUniqueRetainedReads: Int? = nil
    ) {
        self.sample = sample
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleUniqueRetainedReads = sampleUniqueRetainedReads
    }
}

public enum ONTGenotypeSupportDenominator: String, Codable, CaseIterable, Equatable, Sendable {
    case viewedLocus
    case sampleRetained

    public var displayName: String {
        switch self {
        case .viewedLocus:
            return "Viewed Locus"
        case .sampleRetained:
            return "Sample Retained"
        }
    }
}

public struct ONTGenotypeSharedCall: Codable, Equatable, Sendable {
    public let locus: String
    public let genotype: String
    public let sampleSupport: [ONTGenotypeSampleSupport]

    public init(locus: String, genotype: String, sampleSupport: [ONTGenotypeSampleSupport]) {
        self.locus = locus
        self.genotype = genotype
        self.sampleSupport = sampleSupport.sorted {
            if $0.passedUniqueReads != $1.passedUniqueReads {
                return $0.passedUniqueReads > $1.passedUniqueReads
            }
            if $0.passedAlignments != $1.passedAlignments {
                return $0.passedAlignments > $1.passedAlignments
            }
            return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
        }
    }

    public var sampleCount: Int {
        sampleSupport.count
    }

    public var totalAlignments: Int {
        sampleSupport.reduce(0) { $0 + $1.passedAlignments }
    }

    public var totalUniqueReads: Int {
        sampleSupport.reduce(0) { $0 + $1.passedUniqueReads }
    }

    public var topSupport: ONTGenotypeSampleSupport? {
        sampleSupport.first
    }

    public var aliasDisplay: String? {
        guard let pipeIndex = genotype.firstIndex(of: "|") else { return nil }
        let aliases = genotype[genotype.index(after: pipeIndex)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return aliases.isEmpty ? nil : aliases.joined(separator: ", ")
    }

    public func support(for sample: String) -> ONTGenotypeSampleSupport? {
        sampleSupport.first { $0.sample == sample }
    }
}

public struct ONTGenotypeLocusSummary: Codable, Equatable, Sendable {
    public let locus: String
    public let sharedCalls: [ONTGenotypeSharedCall]

    public init(locus: String, sharedCalls: [ONTGenotypeSharedCall]) {
        self.locus = locus
        self.sharedCalls = sharedCalls.sorted {
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            if $0.totalUniqueReads != $1.totalUniqueReads {
                return $0.totalUniqueReads > $1.totalUniqueReads
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
    }

    public var sampleCount: Int {
        Set(sharedCalls.flatMap { $0.sampleSupport.map(\.sample) }).count
    }

    public var callCount: Int {
        sharedCalls.count
    }

    public var totalUniqueReads: Int {
        sharedCalls.reduce(0) { $0 + $1.totalUniqueReads }
    }
}

public struct ONTGenotypeCoOccurrence: Codable, Equatable, Sendable {
    public let selectedGenotype: String
    public let candidateGenotype: String
    public let locus: String
    public let selectedSampleCount: Int
    public let candidateSampleCount: Int
    public let sharedSampleCount: Int
    public let unionSampleCount: Int
    public let probabilityCandidateGivenSelected: Double
    public let probabilitySelectedGivenCandidate: Double
    public let jaccard: Double
    public let lift: Double?
    public let sharedSamples: [String]

    public init(
        selectedGenotype: String,
        candidateGenotype: String,
        locus: String,
        selectedSampleCount: Int,
        candidateSampleCount: Int,
        sharedSampleCount: Int,
        unionSampleCount: Int,
        probabilityCandidateGivenSelected: Double,
        probabilitySelectedGivenCandidate: Double,
        jaccard: Double,
        lift: Double?,
        sharedSamples: [String]
    ) {
        self.selectedGenotype = selectedGenotype
        self.candidateGenotype = candidateGenotype
        self.locus = locus
        self.selectedSampleCount = selectedSampleCount
        self.candidateSampleCount = candidateSampleCount
        self.sharedSampleCount = sharedSampleCount
        self.unionSampleCount = unionSampleCount
        self.probabilityCandidateGivenSelected = probabilityCandidateGivenSelected
        self.probabilitySelectedGivenCandidate = probabilitySelectedGivenCandidate
        self.jaccard = jaccard
        self.lift = lift
        self.sharedSamples = sharedSamples.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}

public enum ONTGenotypeAnchorSource: String, Codable, Equatable, Sendable {
    case labelToken
    case unanchored

    public var displayName: String {
        switch self {
        case .labelToken:
            return "Source Label Token"
        case .unanchored:
            return "No Source Token"
        }
    }
}

public struct ONTGenotypeAnchorSummary: Codable, Equatable, Sendable {
    public let label: String
    public let source: ONTGenotypeAnchorSource
    public let loci: [String]
    public let sharedCalls: [ONTGenotypeSharedCall]
    public let sampleSupport: [ONTGenotypeSampleSupport]
    public let caveat: String

    public init(
        label: String,
        source: ONTGenotypeAnchorSource,
        loci: [String],
        sharedCalls: [ONTGenotypeSharedCall],
        sampleSupport: [ONTGenotypeSampleSupport],
        caveat: String = "Anchor groups are derived from source labels and sample-level observation. They are not phased haplotype calls, zygosity calls, copy-number calls, absence calls, or inheritance assertions."
    ) {
        self.label = label
        self.source = source
        self.loci = loci.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.sharedCalls = sharedCalls.sorted {
            if $0.locus != $1.locus {
                return $0.locus.localizedStandardCompare($1.locus) == .orderedAscending
            }
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
        self.sampleSupport = sampleSupport.sorted {
            if $0.passedUniqueReads != $1.passedUniqueReads {
                return $0.passedUniqueReads > $1.passedUniqueReads
            }
            return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
        }
        self.caveat = caveat
    }

    public var sampleCount: Int {
        sampleSupport.count
    }

    public var totalUniqueReads: Int {
        sharedCalls.reduce(0) { $0 + $1.totalUniqueReads }
    }
}

public struct ONTGenotypeSampleResult: Codable, Equatable, Sendable {
    public let sample: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleTotalReads: Int?
    public let sampleUniqueRetainedPercent: Double?
    public let calls: [ONTGenotypeCall]

    public init(
        sample: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleTotalReads: Int?,
        sampleUniqueRetainedPercent: Double?,
        calls: [ONTGenotypeCall]
    ) {
        self.sample = sample
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleTotalReads = sampleTotalReads
        self.sampleUniqueRetainedPercent = sampleUniqueRetainedPercent
        self.calls = calls.sorted {
            if $0.passedAlignments != $1.passedAlignments {
                return $0.passedAlignments > $1.passedAlignments
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
    }

    public var callCount: Int {
        calls.count
    }

    public var topCall: ONTGenotypeCall? {
        calls.first
    }

    public var qcStatus: ONTGenotypeQCStatus {
        guard !calls.isEmpty, passedAlignments > 0, passedUniqueReads > 0 else {
            return .review
        }
        if passedAlignments < 20 || passedUniqueReads < 1_000 {
            return .lowSupport
        }
        return .ok
    }
}

public struct ONTGenotypeRunStats: Codable, Equatable, Sendable {
    public let totalInputReads: Int?
    public let totalAlignments: Int?
    public let passedAlignments: Int?
    public let retainedUniqueReads: Int?
    public let retainedUniquePercentOfTotalReads: Double?
    public let assignedUniqueRetainedReads: Int?
    public let unassignedUniqueRetainedReads: Int?
    public let rawMetrics: [String: String]

    public init(
        totalInputReads: Int? = nil,
        totalAlignments: Int? = nil,
        passedAlignments: Int? = nil,
        retainedUniqueReads: Int? = nil,
        retainedUniquePercentOfTotalReads: Double? = nil,
        assignedUniqueRetainedReads: Int? = nil,
        unassignedUniqueRetainedReads: Int? = nil,
        rawMetrics: [String: String] = [:]
    ) {
        self.totalInputReads = totalInputReads
        self.totalAlignments = totalAlignments
        self.passedAlignments = passedAlignments
        self.retainedUniqueReads = retainedUniqueReads
        self.retainedUniquePercentOfTotalReads = retainedUniquePercentOfTotalReads
        self.assignedUniqueRetainedReads = assignedUniqueRetainedReads
        self.unassignedUniqueRetainedReads = unassignedUniqueRetainedReads
        self.rawMetrics = rawMetrics
    }

    static func load(from url: URL) throws -> ONTGenotypeRunStats {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ONTGenotypeRunStats()
        }

        var rawMetrics: [String: String] = [:]
        for (key, value) in object {
            if let dictionary = value as? [String: Any] {
                if let data = try? JSONSerialization.data(withJSONObject: dictionary),
                   let json = String(data: data, encoding: .utf8) {
                    rawMetrics[key] = json
                }
            } else if let array = value as? [Any] {
                if let data = try? JSONSerialization.data(withJSONObject: array),
                   let json = String(data: data, encoding: .utf8) {
                    rawMetrics[key] = json
                }
            } else if value is NSNull {
                rawMetrics[key] = "null"
            } else {
                rawMetrics[key] = String(describing: value)
            }
        }

        return ONTGenotypeRunStats(
            totalInputReads: intValue(object["totalInputReads"]),
            totalAlignments: intValue(object["totalAlignments"]),
            passedAlignments: intValue(object["passedAlignments"]),
            retainedUniqueReads: intValue(object["retainedUniqueReads"]),
            retainedUniquePercentOfTotalReads: doubleValue(object["retainedUniquePercentOfTotalReads"]),
            assignedUniqueRetainedReads: intValue(object["assignedUniqueRetainedReads"]),
            unassignedUniqueRetainedReads: intValue(object["unassignedUniqueRetainedReads"]),
            rawMetrics: rawMetrics
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return ONTGenotypeResultBundle.parseInt(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return ONTGenotypeResultBundle.parseDouble(string) }
        return nil
    }
}

public struct ONTGenotypeResultArtifacts: Codable, Equatable, Sendable {
    public let workbookURL: URL
    public let primaryWorkbookURL: URL
    public let longSummaryCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let provenanceURL: URL
    public let deduplicatedUnmatchedClustersFASTAURL: URL?
    public let haplotypeAnalysisURL: URL?

    public init(
        workbookURL: URL,
        primaryWorkbookURL: URL? = nil,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        deduplicatedUnmatchedClustersFASTAURL: URL? = nil,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.workbookURL = workbookURL.standardizedFileURL
        self.primaryWorkbookURL = (primaryWorkbookURL ?? workbookURL).standardizedFileURL
        self.longSummaryCSVURL = longSummaryCSVURL.standardizedFileURL
        self.sampleSummaryCSVURL = sampleSummaryCSVURL.standardizedFileURL
        self.statsJSONURL = statsJSONURL.standardizedFileURL
        self.provenanceURL = provenanceURL.standardizedFileURL
        self.deduplicatedUnmatchedClustersFASTAURL = deduplicatedUnmatchedClustersFASTAURL?.standardizedFileURL
        self.haplotypeAnalysisURL = haplotypeAnalysisURL?.standardizedFileURL
    }

    public init(
        workbookURL: URL,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        deduplicatedUnmatchedClustersFASTAURL: URL? = nil,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.init(
            workbookURL: workbookURL,
            primaryWorkbookURL: workbookURL,
            longSummaryCSVURL: longSummaryCSVURL,
            sampleSummaryCSVURL: sampleSummaryCSVURL,
            statsJSONURL: statsJSONURL,
            provenanceURL: provenanceURL,
            deduplicatedUnmatchedClustersFASTAURL: deduplicatedUnmatchedClustersFASTAURL,
            haplotypeAnalysisURL: haplotypeAnalysisURL
        )
    }

    public init(
        workbookURL: URL,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.init(
            workbookURL: workbookURL,
            primaryWorkbookURL: workbookURL,
            longSummaryCSVURL: longSummaryCSVURL,
            sampleSummaryCSVURL: sampleSummaryCSVURL,
            statsJSONURL: statsJSONURL,
            provenanceURL: provenanceURL,
            deduplicatedUnmatchedClustersFASTAURL: nil,
            haplotypeAnalysisURL: haplotypeAnalysisURL
        )
    }
}

public enum ONTGenotypeIntegrityWarningCode: String, Codable, Equatable, Sendable {
    case candidateArtifactManifestSchemaUnsupported = "candidate-artifact-manifest-schema-unsupported"
    case candidateArtifactIncompleteDeclaration = "candidate-artifact-incomplete-declaration"
    case candidateArtifactPathInvalid = "candidate-artifact-path-invalid"
    case candidateArtifactMissing = "candidate-artifact-missing"
    case candidateArtifactNotRegularFile = "candidate-artifact-not-regular-file"
    case candidateArtifactSizeMismatch = "candidate-artifact-size-mismatch"
    case candidateArtifactChecksumMismatch = "candidate-artifact-checksum-mismatch"
    case candidateArtifactTooLarge = "candidate-artifact-too-large"
    case candidateArtifactMalformedJSON = "candidate-artifact-malformed-json"
    case candidateArtifactSchemaUnsupported = "candidate-artifact-schema-unsupported"
    case candidateArtifactDocumentReferenceMismatch = "candidate-artifact-document-reference-mismatch"
    case candidateArtifactMalformedFASTA = "candidate-artifact-malformed-fasta"
    case candidateArtifactMissingFASTARecord = "candidate-artifact-missing-fasta-record"
    case candidateArtifactDuplicateFASTARecord = "candidate-artifact-duplicate-fasta-record"
    case candidateArtifactExtraFASTARecord = "candidate-artifact-extra-fasta-record"
    case candidateArtifactSequenceChecksumMismatch = "candidate-artifact-sequence-checksum-mismatch"
}

public struct ONTGenotypeIntegrityWarning: Codable, Equatable, Sendable {
    public let code: ONTGenotypeIntegrityWarningCode
    public let detail: String
    public let path: String?

    public init(code: ONTGenotypeIntegrityWarningCode, detail: String, path: String? = nil) {
        self.code = code
        self.detail = detail
        self.path = path
    }
}

public struct ONTGenotypeResultBundleData: Codable, Equatable, Sendable {
    private struct SupportKey: Hashable {
        let sample: String
        let locus: String
    }

    private struct CallSupportContext {
        let call: ONTGenotypeCall
        let locus: String
    }

    public let bundleURL: URL
    public let manifest: ONTGenotypeResultBundleManifest
    public let artifacts: ONTGenotypeResultArtifacts
    public let stats: ONTGenotypeRunStats
    public let calls: [ONTGenotypeCall]
    public let samples: [ONTGenotypeSampleResult]
    public let haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    public let mhcCandidates: ONTMHCCandidateAllelesDocument?
    public let mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?
    public let integrityWarnings: [ONTGenotypeIntegrityWarning]

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
    ) {
        self.init(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: []
        )
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        mhcCandidates: ONTMHCCandidateAllelesDocument?,
        mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?,
        integrityWarnings: [ONTGenotypeIntegrityWarning]
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.manifest = manifest
        self.artifacts = artifacts
        self.stats = stats
        self.calls = calls
        self.samples = samples
        self.haplotypeAnalysis = haplotypeAnalysis
        self.mhcCandidates = mhcCandidates
        self.mhcUnnameableClusters = mhcUnnameableClusters
        self.integrityWarnings = integrityWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case bundleURL
        case manifest
        case artifacts
        case stats
        case calls
        case samples
        case haplotypeAnalysis
        case mhcCandidates
        case mhcUnnameableClusters
        case integrityWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleURL: try container.decode(URL.self, forKey: .bundleURL),
            manifest: try container.decode(ONTGenotypeResultBundleManifest.self, forKey: .manifest),
            artifacts: try container.decode(ONTGenotypeResultArtifacts.self, forKey: .artifacts),
            stats: try container.decode(ONTGenotypeRunStats.self, forKey: .stats),
            calls: try container.decode([ONTGenotypeCall].self, forKey: .calls),
            samples: try container.decode([ONTGenotypeSampleResult].self, forKey: .samples),
            haplotypeAnalysis: try container.decodeIfPresent(GenotypeHaplotypeAnalysis.self, forKey: .haplotypeAnalysis),
            mhcCandidates: try container.decodeIfPresent(ONTMHCCandidateAllelesDocument.self, forKey: .mhcCandidates),
            mhcUnnameableClusters: try container.decodeIfPresent(
                ONTMHCUnnameableClustersDocument.self,
                forKey: .mhcUnnameableClusters
            ),
            integrityWarnings: try container.decodeIfPresent(
                [ONTGenotypeIntegrityWarning].self,
                forKey: .integrityWarnings
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleURL, forKey: .bundleURL)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(stats, forKey: .stats)
        try container.encode(calls, forKey: .calls)
        try container.encode(samples, forKey: .samples)
        try container.encodeIfPresent(haplotypeAnalysis, forKey: .haplotypeAnalysis)
        try container.encodeIfPresent(mhcCandidates, forKey: .mhcCandidates)
        try container.encodeIfPresent(mhcUnnameableClusters, forKey: .mhcUnnameableClusters)
        try container.encode(integrityWarnings, forKey: .integrityWarnings)
    }

    public var sampleCount: Int {
        samples.count
    }

    public var callCount: Int {
        calls.count
    }

    public var qcStatusCounts: [ONTGenotypeQCStatus: Int] {
        Dictionary(grouping: samples, by: \.qcStatus).mapValues(\.count)
    }

    public var sampleNames: [String] {
        samples.map(\.sample)
    }

    public var locusSummaries: [ONTGenotypeLocusSummary] {
        locusSummaries(minimumSupportPercent: 0, denominator: .viewedLocus)
    }

    public func locusSummaries(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> [ONTGenotypeLocusSummary] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        return makeLocusSummaries(from: filteredCalls)
    }

    public func sameLocusCoOccurrences(
        for selectedGenotype: String,
        minimumSupportPercent: Double = 0,
        denominator: ONTGenotypeSupportDenominator = .viewedLocus
    ) -> [ONTGenotypeCoOccurrence] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        guard let selectedCall = filteredCalls.first(where: { $0.genotype == selectedGenotype }) else {
            return []
        }

        let locus = selectedCall.locusGroup
        let sameLocusCalls = filteredCalls.filter { $0.locusGroup == locus }
        let samplesByGenotype = Dictionary(grouping: sameLocusCalls, by: \.genotype)
            .mapValues { Set($0.map(\.sample)) }
        guard let selectedSamples = samplesByGenotype[selectedGenotype], !selectedSamples.isEmpty else {
            return []
        }
        let backgroundSamples = Set(sameLocusCalls.map(\.sample))

        return samplesByGenotype.compactMap { genotype, candidateSamples -> ONTGenotypeCoOccurrence? in
            guard genotype != selectedGenotype, !candidateSamples.isEmpty else { return nil }
            let sharedSamples = selectedSamples.intersection(candidateSamples)
            guard !sharedSamples.isEmpty else { return nil }
            let unionSamples = selectedSamples.union(candidateSamples)
            let probabilityCandidateGivenSelected = Double(sharedSamples.count) / Double(selectedSamples.count)
            let probabilitySelectedGivenCandidate = Double(sharedSamples.count) / Double(candidateSamples.count)
            let jaccard = Double(sharedSamples.count) / Double(unionSamples.count)
            let backgroundProbability = backgroundSamples.isEmpty
                ? 0
                : Double(candidateSamples.count) / Double(backgroundSamples.count)
            let lift = backgroundProbability > 0
                ? probabilityCandidateGivenSelected / backgroundProbability
                : nil
            return ONTGenotypeCoOccurrence(
                selectedGenotype: selectedGenotype,
                candidateGenotype: genotype,
                locus: locus,
                selectedSampleCount: selectedSamples.count,
                candidateSampleCount: candidateSamples.count,
                sharedSampleCount: sharedSamples.count,
                unionSampleCount: unionSamples.count,
                probabilityCandidateGivenSelected: probabilityCandidateGivenSelected,
                probabilitySelectedGivenCandidate: probabilitySelectedGivenCandidate,
                jaccard: jaccard,
                lift: lift,
                sharedSamples: Array(sharedSamples)
            )
        }.sorted { lhs, rhs in
            if lhs.probabilityCandidateGivenSelected != rhs.probabilityCandidateGivenSelected {
                return lhs.probabilityCandidateGivenSelected > rhs.probabilityCandidateGivenSelected
            }
            if lhs.sharedSampleCount != rhs.sharedSampleCount {
                return lhs.sharedSampleCount > rhs.sharedSampleCount
            }
            if lhs.jaccard != rhs.jaccard {
                return lhs.jaccard > rhs.jaccard
            }
            return lhs.candidateGenotype.localizedStandardCompare(rhs.candidateGenotype) == .orderedAscending
        }
    }

    public func anchorSummaries(
        minimumSupportPercent: Double = 0,
        denominator: ONTGenotypeSupportDenominator = .viewedLocus
    ) -> [ONTGenotypeAnchorSummary] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        var callsByAnchor: [String: [ONTGenotypeCall]] = [:]
        var sourceByAnchor: [String: ONTGenotypeAnchorSource] = [:]

        for call in filteredCalls {
            let tokens = call.haplotypeTokens
            if tokens.isEmpty {
                callsByAnchor["Unanchored", default: []].append(call)
                sourceByAnchor["Unanchored"] = .unanchored
            } else {
                for token in tokens {
                    callsByAnchor[token, default: []].append(call)
                    sourceByAnchor[token] = .labelToken
                }
            }
        }

        return callsByAnchor.map { label, callsForAnchor in
            let sharedCalls = makeLocusSummaries(from: callsForAnchor).flatMap(\.sharedCalls)
            return ONTGenotypeAnchorSummary(
                label: label,
                source: sourceByAnchor[label] ?? .unanchored,
                loci: Array(Set(callsForAnchor.map(\.locusGroup))),
                sharedCalls: sharedCalls,
                sampleSupport: aggregateSampleSupport(callsForAnchor)
            )
        }.sorted { lhs, rhs in
            Self.anchorSortKey(lhs.label) < Self.anchorSortKey(rhs.label)
        }
    }

    public func supportFraction(
        for call: ONTGenotypeCall,
        denominator: ONTGenotypeSupportDenominator
    ) -> Double? {
        let denominatorValue: Int?
        switch denominator {
        case .viewedLocus:
            let locus = call.locusGroup
            denominatorValue = viewedLocusDenominators(
                contexts: callSupportContexts()
            )[SupportKey(sample: call.sample, locus: locus)]
        case .sampleRetained:
            denominatorValue = call.sampleUniqueRetainedReads
                ?? samples.first { $0.sample == call.sample }?.passedUniqueReads
        }

        guard let denominatorValue, denominatorValue > 0 else { return nil }
        return Double(call.passedUniqueReads) / Double(denominatorValue)
    }

    public func hiddenSupportCallCount(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> Int {
        guard minimumSupportPercent > 0 else { return 0 }
        return calls.count - supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        ).count
    }

    private func supportFilteredCalls(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> [ONTGenotypeCall] {
        guard minimumSupportPercent > 0 else { return calls }
        let threshold = minimumSupportPercent / 100
        switch denominator {
        case .viewedLocus:
            let contexts = callSupportContexts()
            let denominators = viewedLocusDenominators(contexts: contexts)
            return contexts.compactMap { context in
                guard let denominatorValue = denominators[
                    SupportKey(sample: context.call.sample, locus: context.locus)
                ],
                      denominatorValue > 0 else {
                    return nil
                }
                return Double(context.call.passedUniqueReads) / Double(denominatorValue) >= threshold
                    ? context.call
                    : nil
            }
        case .sampleRetained:
            let retainedBySample = Dictionary(uniqueKeysWithValues: samples.map {
                ($0.sample, $0.passedUniqueReads)
            })
            return calls.filter { call in
                guard let denominatorValue = call.sampleUniqueRetainedReads ?? retainedBySample[call.sample],
                      denominatorValue > 0 else {
                    return false
                }
                return Double(call.passedUniqueReads) / Double(denominatorValue) >= threshold
            }
        }
    }

    private func callSupportContexts() -> [CallSupportContext] {
        calls.map { CallSupportContext(call: $0, locus: $0.locusGroup) }
    }

    private func viewedLocusDenominators(contexts: [CallSupportContext]) -> [SupportKey: Int] {
        var denominators: [SupportKey: Int] = [:]
        denominators.reserveCapacity(contexts.count)
        for context in contexts {
            denominators[
                SupportKey(sample: context.call.sample, locus: context.locus),
                default: 0
            ] += context.call.passedUniqueReads
        }
        return denominators
    }

    private func makeLocusSummaries(from calls: [ONTGenotypeCall]) -> [ONTGenotypeLocusSummary] {
        let callsByLocus = Dictionary(grouping: calls, by: \.locusGroup)
        return callsByLocus.map { locus, callsForLocus in
            let callsByGenotype = Dictionary(grouping: callsForLocus, by: \.genotype)
            let sharedCalls = callsByGenotype.map { genotype, genotypeCalls in
                let support = genotypeCalls.map {
                    ONTGenotypeSampleSupport(
                        sample: $0.sample,
                        passedAlignments: $0.passedAlignments,
                        passedUniqueReads: $0.passedUniqueReads,
                        sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads
                    )
                }
                return ONTGenotypeSharedCall(locus: locus, genotype: genotype, sampleSupport: support)
            }
            return ONTGenotypeLocusSummary(locus: locus, sharedCalls: sharedCalls)
        }.sorted { lhs, rhs in
            let lhsOrder = Self.locusSortRank(lhs.locus)
            let rhsOrder = Self.locusSortRank(rhs.locus)
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.locus.localizedStandardCompare(rhs.locus) == .orderedAscending
        }
    }

    private func aggregateSampleSupport(_ calls: [ONTGenotypeCall]) -> [ONTGenotypeSampleSupport] {
        struct MutableSupport {
            var alignments = 0
            var uniqueReads = 0
            var retainedReads: Int?
        }
        var supportBySample: [String: MutableSupport] = [:]
        for call in calls {
            var support = supportBySample[call.sample] ?? MutableSupport()
            support.alignments += call.passedAlignments
            support.uniqueReads += call.passedUniqueReads
            support.retainedReads = call.sampleUniqueRetainedReads ?? support.retainedReads
            supportBySample[call.sample] = support
        }
        return supportBySample.map { sample, support in
            ONTGenotypeSampleSupport(
                sample: sample,
                passedAlignments: support.alignments,
                passedUniqueReads: support.uniqueReads,
                sampleUniqueRetainedReads: support.retainedReads
            )
        }
    }

    private static func anchorSortKey(_ label: String) -> (Int, Int, String) {
        if label == "Unanchored" {
            return (1, Int.max, label)
        }
        if label.hasPrefix("M"),
           let value = Int(label.dropFirst()) {
            return (0, value, label)
        }
        return (0, Int.max - 1, label)
    }

    private static func locusSortRank(_ locus: String) -> Int {
        let uppercased = locus.uppercased()
        if uppercased == "MHC-A" { return 0 }
        if uppercased == "MHC-B" { return 1 }
        if uppercased.hasPrefix("MHC-DRB") { return 2 }
        if uppercased.hasPrefix("MHC-DQA") { return 3 }
        if uppercased.hasPrefix("MHC-DQB") { return 4 }
        if uppercased.hasPrefix("MHC-DPA") { return 5 }
        if uppercased.hasPrefix("MHC-DPB") { return 6 }
        if uppercased == "MHC-F" { return 7 }
        if uppercased == "MHC-G" || uppercased == "MHC-AG" { return 8 }
        return 100
    }
}

public enum ONTGenotypeResultBundle {
    public static let directoryExtension = "lungfishgenotype"

    private static let maximumCollectedCandidateArtifactBytes: Int64 = 256 * 1_024 * 1_024
    private static let artifactReadChunkBytes = 64 * 1_024

    private struct MHCCandidateProjection {
        let candidates: ONTMHCCandidateAllelesDocument?
        let unnameable: ONTMHCUnnameableClustersDocument?
        let warnings: [ONTGenotypeIntegrityWarning]

        static let absent = MHCCandidateProjection(candidates: nil, unnameable: nil, warnings: [])
    }

    private struct CandidateIntegrityFailure: Error {
        let warning: ONTGenotypeIntegrityWarning
    }

    private struct ParsedFASTA {
        let sequenceChecksums: [String: String]
        let counts: [String: Int]
    }

    private struct StreamingFASTAParser {
        private static let maximumLineBytes = 1_048_576
        private let path: String
        private let requiredIDs: Set<String>
        private var pendingLine: [UInt8] = []
        private var currentID: String?
        private var currentIsRequired = false
        private var currentHasher = SHA256()
        private var currentBaseCount = 0
        private var counts: [String: Int] = [:]
        private var checksums: [String: String] = [:]

        init(path: String, requiredIDs: Set<String>) {
            self.path = path
            self.requiredIDs = requiredIDs
        }

        mutating func consume(_ data: Data) throws {
            for byte in data {
                if byte == 0x0a {
                    try consumeLine(pendingLine)
                    pendingLine.removeAll(keepingCapacity: true)
                } else {
                    guard pendingLine.count < Self.maximumLineBytes else {
                        throw ONTGenotypeResultBundle.integrityFailure(
                            .candidateArtifactMalformedFASTA,
                            "Candidate FASTA contains a line longer than \(Self.maximumLineBytes) bytes.",
                            path: path
                        )
                    }
                    pendingLine.append(byte)
                }
            }
        }

        mutating func finish() throws -> ParsedFASTA {
            if !pendingLine.isEmpty { try consumeLine(pendingLine) }
            try finishRecord()
            return ParsedFASTA(sequenceChecksums: checksums, counts: counts)
        }

        private mutating func consumeLine(_ rawLine: [UInt8]) throws {
            var line = rawLine
            if line.last == 0x0d { line.removeLast() }
            if line.first == 0x3e {
                try finishRecord()
                guard let header = String(bytes: line.dropFirst(), encoding: .utf8) else {
                    throw malformed("Candidate FASTA header is not valid UTF-8.")
                }
                let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = trimmed.split(whereSeparator: \.isWhitespace).first, !id.isEmpty else {
                    throw malformed("Candidate FASTA contains an empty record identifier.")
                }
                currentID = String(id)
                currentIsRequired = requiredIDs.contains(String(id))
                currentHasher = SHA256()
                currentBaseCount = 0
                return
            }
            var start = 0
            var end = line.count
            while start < end, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
            while end > start, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
            guard start < end || currentID != nil else {
                throw malformed("Candidate FASTA contains sequence data before its first header.")
            }
            guard start < end else { return }
            guard currentID != nil else {
                throw malformed("Candidate FASTA contains sequence data before its first header.")
            }
            var normalized: [UInt8] = []
            normalized.reserveCapacity(end - start)
            for byte in line[start..<end] {
                guard byte >= 0x21, byte <= 0x7e else {
                    throw malformed("Candidate FASTA sequence contains non-ASCII or embedded whitespace bytes.")
                }
                normalized.append((0x61...0x7a).contains(byte) ? byte - 0x20 : byte)
            }
            if currentIsRequired { currentHasher.update(data: Data(normalized)) }
            currentBaseCount += normalized.count
        }

        private mutating func finishRecord() throws {
            guard let id = currentID else { return }
            guard currentBaseCount > 0 else {
                throw malformed("FASTA record '\(id)' has no sequence.")
            }
            counts[id, default: 0] += 1
            if currentIsRequired, checksums[id] == nil {
                checksums[id] = currentHasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            currentID = nil
            currentIsRequired = false
            currentBaseCount = 0
        }

        private func malformed(_ detail: String) -> CandidateIntegrityFailure {
            ONTGenotypeResultBundle.integrityFailure(.candidateArtifactMalformedFASTA, detail, path: path)
        }
    }

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> ONTGenotypeResultBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: ONTGenotypeResultBundleManifest,
        to bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    public static func primaryWorkbookURL(for bundleURL: URL) throws -> URL {
        let manifest = try loadManifest(from: bundleURL)
        return resolvedURL(for: manifest.primaryWorkbookPath, in: bundleURL)
    }

    public static func currentWorkbookURL(for bundleURL: URL) throws -> URL {
        let manifest = try loadManifest(from: bundleURL)
        return resolvedURL(
            for: manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath,
            in: bundleURL
        )
    }

    /// Synchronous loader retained for CLI and non-UI callers. This method may hash
    /// large declared BAM artifacts; AppKit call sites should use `loadResultAsync`.
    public static func loadResult(from bundleURL: URL) throws -> ONTGenotypeResultBundleData {
        let manifest = try loadManifest(from: bundleURL)
        return try loadResult(
            from: bundleURL,
            manifest: manifest,
            candidateArtifactByteBudget: maximumCollectedCandidateArtifactBytes
        )
    }

    public static func loadResultAsync(from bundleURL: URL) async throws -> ONTGenotypeResultBundleData {
        try Task.checkCancellation()
        let worker = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try loadResult(from: bundleURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func loadResult(
        from bundleURL: URL,
        candidateArtifactByteBudget: Int64
    ) throws -> ONTGenotypeResultBundleData {
        let manifest = try loadManifest(from: bundleURL)
        return try loadResult(
            from: bundleURL,
            manifest: manifest,
            candidateArtifactByteBudget: candidateArtifactByteBudget
        )
    }

    /// Synchronous manifest-aware variant for CLI and tests. AppKit callers
    /// should use `loadResultAsync(from:)` so evidence hashing stays off-main.
    public static func loadResult(
        from bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest
    ) throws -> ONTGenotypeResultBundleData {
        try loadResult(
            from: bundleURL,
            manifest: manifest,
            candidateArtifactByteBudget: maximumCollectedCandidateArtifactBytes
        )
    }

    private static func loadResult(
        from bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        candidateArtifactByteBudget: Int64
    ) throws -> ONTGenotypeResultBundleData {
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: resolvedURL(
                for: manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath,
                in: bundleURL
            ),
            primaryWorkbookURL: resolvedURL(for: manifest.primaryWorkbookPath, in: bundleURL),
            longSummaryCSVURL: resolvedURL(for: manifest.longSummaryCSVPath, in: bundleURL),
            sampleSummaryCSVURL: resolvedURL(for: manifest.sampleSummaryCSVPath, in: bundleURL),
            statsJSONURL: resolvedURL(for: manifest.statsJSONPath, in: bundleURL),
            provenanceURL: resolvedURL(for: manifest.provenancePath, in: bundleURL),
            deduplicatedUnmatchedClustersFASTAURL: manifest.deduplicatedUnmatchedClustersFASTAPath.map {
                resolvedURL(for: $0, in: bundleURL)
            },
            haplotypeAnalysisURL: manifest.haplotypeAnalysisPath.map {
                resolvedURL(for: $0, in: bundleURL)
            }
        )
        let callRows = try loadCSVRows(from: artifacts.longSummaryCSVURL)
        let sampleRows = try loadCSVRows(from: artifacts.sampleSummaryCSVURL)
        let stats = try ONTGenotypeRunStats.load(from: artifacts.statsJSONURL)
        let haplotypeAnalysis = try loadHaplotypeAnalysisIfPresent(from: artifacts.haplotypeAnalysisURL)
        let mhcProjection = try loadMHCCandidateProjection(
            from: manifest.mhcCandidateArtifacts,
            bundleURL: bundleURL,
            parsedArtifactByteBudget: candidateArtifactByteBudget
        )

        let calls = callRows.compactMap(makeCall(row:)).filter { isAssignedSample($0.sample) }
        let callsBySample = Dictionary(grouping: calls, by: \.sample)
        let orderedSampleNames = orderedAssignedSampleNames(sampleRows: sampleRows, calls: calls)
        let samples = orderedSampleNames.map { sampleName in
            let row = sampleRows.first { ($0["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sampleName }
            let callsForSample = callsBySample[sampleName] ?? []
            let passedAlignments = parseInt(row?["passed_alignments"]) ?? callsForSample.reduce(0) { $0 + $1.passedAlignments }
            let passedUniqueReads = parseInt(row?["passed_unique_reads"])
                ?? callsForSample.map(\.passedUniqueReads).max()
                ?? 0
            return ONTGenotypeSampleResult(
                sample: sampleName,
                passedAlignments: passedAlignments,
                passedUniqueReads: passedUniqueReads,
                sampleTotalReads: parseInt(row?["sample_total_reads"]),
                sampleUniqueRetainedPercent: parseDouble(row?["sample_unique_retained_percent"]),
                calls: callsForSample
            )
        }

        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: mhcProjection.candidates,
            mhcUnnameableClusters: mhcProjection.unnameable,
            integrityWarnings: mhcProjection.warnings
        )
    }

    private static func loadMHCCandidateProjection(
        from artifactManifest: ONTMHCCandidateArtifactManifest?,
        bundleURL: URL,
        parsedArtifactByteBudget: Int64
    ) throws -> MHCCandidateProjection {
        guard let artifactManifest else { return .absent }
        do {
            guard artifactManifest.schemaVersion == 1 else {
                throw integrityFailure(
                    .candidateArtifactManifestSchemaUnsupported,
                    "MHC candidate artifact manifest schema \(artifactManifest.schemaVersion) is unsupported; expected schema 1."
                )
            }
            try requirePairedDeclaration(
                artifactManifest.candidateJSON,
                artifactManifest.candidateFASTA,
                label: "candidate JSON and FASTA"
            )
            try requirePairedDeclaration(
                artifactManifest.unnameableJSON,
                artifactManifest.unnameableFASTA,
                label: "un-nameable JSON and FASTA"
            )
            let parsedReferences = [
                artifactManifest.candidateJSON,
                artifactManifest.candidateFASTA,
                artifactManifest.unnameableJSON,
                artifactManifest.unnameableFASTA,
            ].compactMap { $0 }
            guard parsedArtifactByteBudget >= 0 else {
                throw integrityFailure(
                    .candidateArtifactTooLarge,
                    "The aggregate candidate artifact byte budget must not be negative."
                )
            }
            var aggregateBytes: Int64 = 0
            for reference in parsedReferences {
                let (next, overflow) = aggregateBytes.addingReportingOverflow(reference.sizeBytes)
                guard reference.sizeBytes >= 0, !overflow, next <= parsedArtifactByteBudget else {
                    throw integrityFailure(
                        .candidateArtifactTooLarge,
                        "Declared candidate JSON/FASTA artifacts exceed the aggregate parsed-artifact budget of \(parsedArtifactByteBudget) bytes.",
                        path: reference.path
                    )
                }
                aggregateBytes = next
            }
            for reference in declaredBAMReferences(artifactManifest) {
                _ = try validateArtifact(reference, in: bundleURL, collectData: false)
            }

            let declaredEvidence = declaredBAMReferences(artifactManifest)
            var candidates: ONTMHCCandidateAllelesDocument?
            if let jsonReference = artifactManifest.candidateJSON,
               let fastaReference = artifactManifest.candidateFASTA {
                let jsonData = try validateArtifact(jsonReference, in: bundleURL, collectData: true) ?? Data()
                let document = try decodeCandidateDocument(jsonData, path: jsonReference.path)
                try validateDocumentReferences(
                    sequenceFASTA: document.sequenceFASTA,
                    evidence: document.evidence,
                    expectedSequenceFASTA: fastaReference,
                    expectedEvidence: declaredEvidence,
                    reciprocalEvidenceLocators: document.candidates.map(\.selectedEvidence),
                    genotypingEvidenceLocators: document.observations.flatMap(\.evidence),
                    genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                    reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                    documentPath: jsonReference.path
                )
                var parser = StreamingFASTAParser(
                    path: fastaReference.path,
                    requiredIDs: Set(document.candidates.map(\.stableClusterID))
                )
                var parserFailure: Error?
                _ = try validateArtifact(
                    fastaReference,
                    in: bundleURL,
                    collectData: false,
                    chunkHandler: { chunk in
                        guard parserFailure == nil else { return }
                        do { try parser.consume(chunk) } catch { parserFailure = error }
                    }
                )
                if let parserFailure { throw parserFailure }
                try validateCandidateRecords(
                    document.candidates,
                    fasta: try parser.finish(),
                    path: fastaReference.path
                )
                candidates = document
            }
            var unnameable: ONTMHCUnnameableClustersDocument?
            if let jsonReference = artifactManifest.unnameableJSON,
               let fastaReference = artifactManifest.unnameableFASTA {
                let jsonData = try validateArtifact(jsonReference, in: bundleURL, collectData: true) ?? Data()
                let document = try decodeUnnameableDocument(jsonData, path: jsonReference.path)
                try validateDocumentReferences(
                    sequenceFASTA: document.sequenceFASTA,
                    evidence: document.evidence,
                    expectedSequenceFASTA: fastaReference,
                    expectedEvidence: declaredEvidence,
                    reciprocalEvidenceLocators: document.clusters.flatMap(\.evidence),
                    genotypingEvidenceLocators: document.observations.flatMap(\.evidence),
                    genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                    reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                    documentPath: jsonReference.path
                )
                var parser = StreamingFASTAParser(
                    path: fastaReference.path,
                    requiredIDs: Set(document.clusters.map(\.stableClusterID))
                )
                var parserFailure: Error?
                _ = try validateArtifact(
                    fastaReference,
                    in: bundleURL,
                    collectData: false,
                    chunkHandler: { chunk in
                        guard parserFailure == nil else { return }
                        do { try parser.consume(chunk) } catch { parserFailure = error }
                    }
                )
                if let parserFailure { throw parserFailure }
                try validateUnnameableRecords(
                    document.clusters,
                    fasta: try parser.finish(),
                    path: fastaReference.path
                )
                unnameable = document
            }
            return MHCCandidateProjection(candidates: candidates, unnameable: unnameable, warnings: [])
        } catch let failure as CandidateIntegrityFailure {
            return MHCCandidateProjection(candidates: nil, unnameable: nil, warnings: [failure.warning])
        }
    }

    private static func requirePairedDeclaration(
        _ json: ONTMHCArtifactReference?,
        _ fasta: ONTMHCArtifactReference?,
        label: String
    ) throws {
        guard (json == nil) == (fasta == nil) else {
            throw integrityFailure(
                .candidateArtifactIncompleteDeclaration,
                "The optional MHC \(label) must either both be declared or both be absent.",
                path: json?.path ?? fasta?.path
            )
        }
    }

    private static func declaredBAMReferences(
        _ manifest: ONTMHCCandidateArtifactManifest
    ) -> [ONTMHCArtifactReference] {
        [
            manifest.genotypingEvidence?.bam,
            manifest.genotypingEvidence?.bai,
            manifest.reciprocalEvidence?.bam,
            manifest.reciprocalEvidence?.bai,
        ].compactMap { $0 }
    }

    private static func validateArtifact(
        _ reference: ONTMHCArtifactReference,
        in bundleURL: URL,
        collectData: Bool,
        chunkHandler: ((Data) throws -> Void)? = nil
    ) throws -> Data? {
        let components = try safeRelativePathComponents(reference.path)
        let rootFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "The genotype bundle root could not be opened without following symbolic links: \(errnoDetail()).",
                path: reference.path
            )
        }
        defer { Darwin.close(rootFD) }

        var directoryFD = rootFD
        var ownedDirectoryFDs: [Int32] = []
        defer { ownedDirectoryFDs.reversed().forEach { Darwin.close($0) } }
        for component in components.dropLast() {
            let nextFD = component.withCString {
                Darwin.openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextFD >= 0 else {
                let code: ONTGenotypeIntegrityWarningCode = errno == ENOENT
                    ? .candidateArtifactMissing
                    : .candidateArtifactPathInvalid
                throw integrityFailure(
                    code,
                    "A path component could not be opened as a real directory without following links: \(errnoDetail()).",
                    path: reference.path
                )
            }
            ownedDirectoryFDs.append(nextFD)
            directoryFD = nextFD
        }

        let finalFD = components.last!.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard finalFD >= 0 else {
            let code: ONTGenotypeIntegrityWarningCode = errno == ENOENT
                ? .candidateArtifactMissing
                : .candidateArtifactPathInvalid
            throw integrityFailure(
                code,
                "The declared artifact could not be opened as a no-follow file: \(errnoDetail()).",
                path: reference.path
            )
        }
        defer { Darwin.close(finalFD) }

        var status = stat()
        guard Darwin.fstat(finalFD, &status) == 0 else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "The declared artifact could not be inspected: \(errnoDetail()).",
                path: reference.path
            )
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw integrityFailure(
                .candidateArtifactNotRegularFile,
                "The declared MHC artifact is not a regular file.",
                path: reference.path
            )
        }
        let actualSize = Int64(status.st_size)
        guard reference.sizeBytes >= 0, actualSize == reference.sizeBytes else {
            throw integrityFailure(
                .candidateArtifactSizeMismatch,
                "Declared size \(reference.sizeBytes) bytes does not match the regular file size \(actualSize) bytes.",
                path: reference.path
            )
        }
        if (collectData || chunkHandler != nil), actualSize > maximumCollectedCandidateArtifactBytes {
            throw integrityFailure(
                .candidateArtifactTooLarge,
                "The candidate JSON/FASTA is \(actualSize) bytes; the safe loading limit is \(maximumCollectedCandidateArtifactBytes) bytes.",
                path: reference.path
            )
        }

        var hasher = SHA256()
        var collected = collectData ? Data() : nil
        if collectData { collected?.reserveCapacity(Int(actualSize)) }
        var bytesRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: artifactReadChunkBytes)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(finalFD, rawBuffer.baseAddress!, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw integrityFailure(
                    .candidateArtifactPathInvalid,
                    "The declared artifact could not be read: \(errnoDetail()).",
                    path: reference.path
                )
            }
            if count == 0 { break }
            bytesRead += Int64(count)
            guard bytesRead <= actualSize else {
                throw integrityFailure(
                    .candidateArtifactSizeMismatch,
                    "The artifact grew while it was being validated.",
                    path: reference.path
                )
            }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            collected?.append(chunk)
            try chunkHandler?(chunk)
        }
        guard bytesRead == actualSize else {
            throw integrityFailure(
                .candidateArtifactSizeMismatch,
                "The artifact changed size while it was being validated (read \(bytesRead) of \(actualSize) bytes).",
                path: reference.path
            )
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == reference.sha256.lowercased() else {
            throw integrityFailure(
                .candidateArtifactChecksumMismatch,
                "Declared SHA-256 \(reference.sha256) does not match computed SHA-256 \(checksum).",
                path: reference.path
            )
        }
        return collected
    }

    private static func safeRelativePathComponents(_ path: String) throws -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.utf8.contains(0),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "Candidate artifact paths must be non-empty relative paths contained below the bundle root.",
                path: path
            )
        }
        return components
    }

    private static func decodeCandidateDocument(
        _ data: Data,
        path: String
    ) throws -> ONTMHCCandidateAllelesDocument {
        try requireSchemaOne(data, path: path)
        do {
            return try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate JSON does not conform to schema 1: \(error.localizedDescription)",
                path: path
            )
        }
    }

    private static func decodeUnnameableDocument(
        _ data: Data,
        path: String
    ) throws -> ONTMHCUnnameableClustersDocument {
        try requireSchemaOne(data, path: path)
        do {
            return try JSONDecoder().decode(ONTMHCUnnameableClustersDocument.self, from: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Un-nameable cluster JSON does not conform to schema 1: \(error.localizedDescription)",
                path: path
            )
        }
    }

    private static func requireSchemaOne(_ data: Data, path: String) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact is not valid JSON: \(error.localizedDescription)",
                path: path
            )
        }
        guard let dictionary = object as? [String: Any], let schema = dictionary["schema_version"] as? Int else {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact must be a JSON object with integer schema_version 1.",
                path: path
            )
        }
        guard schema == 1 else {
            throw integrityFailure(
                .candidateArtifactSchemaUnsupported,
                "Candidate artifact schema \(schema) is unsupported; expected schema 1.",
                path: path
            )
        }
    }

    private static func validateDocumentReferences(
        sequenceFASTA: ONTMHCArtifactReference,
        evidence: [ONTMHCArtifactReference],
        expectedSequenceFASTA: ONTMHCArtifactReference,
        expectedEvidence: [ONTMHCArtifactReference],
        reciprocalEvidenceLocators: [ONTMHCEvidenceLocator],
        genotypingEvidenceLocators: [ONTMHCEvidenceLocator],
        genotypingBAMPath: String?,
        reciprocalBAMPath: String?,
        documentPath: String?
    ) throws {
        guard sequenceFASTA == expectedSequenceFASTA else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "The document sequence_fasta reference does not exactly match the manifest FASTA reference.",
                path: documentPath
            )
        }
        guard canonicalReferences(evidence) == canonicalReferences(expectedEvidence) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "The document evidence references do not exactly match the BAM/BAI artifacts declared by the manifest.",
                path: documentPath
            )
        }
        guard reciprocalEvidenceLocators.allSatisfy({ $0.bamPath == reciprocalBAMPath }) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Candidate and un-nameable reciprocal evidence locators must name exactly the reciprocal BAM declared by the typed manifest role.",
                path: documentPath
            )
        }
        guard genotypingEvidenceLocators.allSatisfy({ $0.bamPath == genotypingBAMPath }) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Candidate and un-nameable observation evidence locators must name exactly the genotyping BAM declared by the typed manifest role.",
                path: documentPath
            )
        }
    }

    private static func canonicalReferences(_ references: [ONTMHCArtifactReference]) -> [String] {
        references.map { "\($0.path)\u{0}\($0.sha256.lowercased())\u{0}\($0.sizeBytes)" }.sorted()
    }

    private static func validateCandidateRecords(
        _ records: [ONTMHCCandidateRecord],
        fasta: ParsedFASTA,
        path: String
    ) throws {
        try validateFASTARecords(
            records.map { ($0.stableClusterID, $0.fastaRecordID, $0.sequenceSHA256) },
            fasta: fasta,
            path: path
        )
    }

    private static func validateUnnameableRecords(
        _ records: [ONTMHCUnnameableRecord],
        fasta: ParsedFASTA,
        path: String
    ) throws {
        try validateFASTARecords(
            records.map { ($0.stableClusterID, $0.fastaRecordID, $0.sequenceSHA256) },
            fasta: fasta,
            path: path
        )
    }

    private static func validateFASTARecords(
        _ records: [(stableID: String, fastaID: String, checksum: String)],
        fasta: ParsedFASTA,
        path: String
    ) throws {
        guard records.allSatisfy({ !$0.stableID.isEmpty && $0.stableID == $0.fastaID }),
              Set(records.map(\.stableID)).count == records.count else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Every document record must have one unique, non-empty stable_cluster_id equal to its fasta_record_id.",
                path: path
            )
        }
        let expected = Set(records.map(\.stableID))
        if let missing = expected.sorted().first(where: { fasta.counts[$0] == nil }) {
            throw integrityFailure(
                .candidateArtifactMissingFASTARecord,
                "FASTA is missing declared stable cluster '\(missing)'.",
                path: path
            )
        }
        if let duplicate = expected.sorted().first(where: { fasta.counts[$0] != 1 }) {
            throw integrityFailure(
                .candidateArtifactDuplicateFASTARecord,
                "FASTA stable cluster '\(duplicate)' occurs \(fasta.counts[duplicate] ?? 0) times; expected exactly once.",
                path: path
            )
        }
        let extras = Set(fasta.counts.keys).subtracting(expected)
        if let extra = extras.sorted().first {
            throw integrityFailure(
                .candidateArtifactExtraFASTARecord,
                "FASTA contains undeclared record '\(extra)'.",
                path: path
            )
        }
        for record in records.sorted(by: { $0.stableID < $1.stableID }) {
            guard let checksum = fasta.sequenceChecksums[record.stableID] else { continue }
            guard checksum == record.checksum.lowercased() else {
                throw integrityFailure(
                    .candidateArtifactSequenceChecksumMismatch,
                    "FASTA sequence SHA-256 for '\(record.stableID)' is \(checksum), not the document value \(record.checksum).",
                    path: path
                )
            }
        }
    }

    private static func integrityFailure(
        _ code: ONTGenotypeIntegrityWarningCode,
        _ detail: String,
        path: String? = nil
    ) -> CandidateIntegrityFailure {
        CandidateIntegrityFailure(warning: ONTGenotypeIntegrityWarning(code: code, detail: detail, path: path))
    }

    private static func errnoDetail() -> String {
        String(cString: Darwin.strerror(errno))
    }

    public static func resolvedURL(for path: String, in bundleURL: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return bundleURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    static func parseInt(_ value: String?) -> Int? {
        guard let double = parseDouble(value) else { return nil }
        return Int(double)
    }

    static func parseDouble(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix("%") {
            text.removeLast()
        }
        text = text.replacingOccurrences(of: ",", with: "")
        return Double(text)
    }

    private static func makeCall(row: [String: String]) -> ONTGenotypeCall? {
        let sample = (row["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let genotype = (row["genotype"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty, !genotype.isEmpty else { return nil }
        return ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: parseInt(row["passed_alignments"]) ?? 0,
            passedUniqueReads: parseInt(row["passed_unique_reads"]) ?? 0,
            sampleTotalReads: parseInt(row["sample_total_reads"]),
            sampleUniqueRetainedReads: parseInt(row["sample_unique_retained_reads"]),
            sampleUniqueRetainedPercent: parseDouble(row["sample_unique_retained_percent"]),
            overallInputReads: parseInt(row["overall_input_reads"]),
            overallUniqueRetainedReads: parseInt(row["overall_unique_retained_reads"]),
            overallUniqueRetainedPercent: parseDouble(row["overall_unique_retained_percent"])
        )
    }

    private static func isAssignedSample(_ sample: String) -> Bool {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.lowercased() != "unassigned"
    }

    private static func orderedAssignedSampleNames(
        sampleRows: [[String: String]],
        calls: [ONTGenotypeCall]
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for row in sampleRows {
            let sample = (row["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAssignedSample(sample), seen.insert(sample).inserted else { continue }
            names.append(sample)
        }
        for call in calls where seen.insert(call.sample).inserted {
            names.append(call.sample)
        }
        return names
    }

    private static func loadHaplotypeAnalysisIfPresent(
        from url: URL?
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: data)
    }

    private static func loadCSVRows(from url: URL) throws -> [[String: String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = parseCSV(content)
        guard let headers = rows.first else { return [] }
        return rows.dropFirst().compactMap { row in
            guard !isRepeatedCSVHeaderRow(row, headers: headers) else { return nil }
            var dict: [String: String] = [:]
            for index in headers.indices {
                let header = headers[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !header.isEmpty else { continue }
                dict[header] = index < row.count ? row[index] : ""
            }
            return dict
        }
    }

    private static func isRepeatedCSVHeaderRow(_ row: [String], headers: [String]) -> Bool {
        guard !headers.isEmpty, row.count >= headers.count else { return false }
        for index in headers.indices {
            let header = headers[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value == header else { return false }
        }
        return true
    }

    private static func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes {
                    var peekIterator = iterator
                    if let next = peekIterator.next(), next == "\"" {
                        field.append("\"")
                        iterator = peekIterator
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                row.append(field)
                field = ""
            case "\n" where !inQuotes:
                row.append(field)
                appendCSVRow(row, to: &rows)
                row = []
                field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            appendCSVRow(row, to: &rows)
        }
        return rows
    }

    private static func appendCSVRow(_ row: [String], to rows: inout [[String]]) {
        let trimmed = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.contains(where: { !$0.isEmpty }) {
            rows.append(trimmed)
        }
    }
}

// MARK: - Annotation sidecar accessors

public extension ONTGenotypeResultBundleData {
    static func annotationSidecarURL(forBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    static func loadOrCreateAnnotationSidecar(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        if let data = try readAnnotationSidecarDataIfPresent(forBundleAt: bundleURL) {
            return try GenotypeAnnotationSidecar.decode(data)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return GenotypeAnnotationSidecar.empty(generatedAt: formatter.string(from: Date()))
    }

    /// Read-only counterpart of `loadOrCreateAnnotationSidecar`. Returns an
    /// empty in-memory sidecar when the file is missing; never writes. Use
    /// this for CLI inspection commands that must not touch a possibly
    /// read-only bundle directory.
    static func loadAnnotationSidecarIfPresent(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        if let data = try readAnnotationSidecarDataIfPresent(forBundleAt: bundleURL) {
            return try GenotypeAnnotationSidecar.decode(data)
        }
        return GenotypeAnnotationSidecar.empty(generatedAt: "")
    }

    private static func readAnnotationSidecarDataIfPresent(forBundleAt bundleURL: URL) throws -> Data? {
        let directoryFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            throw annotationSidecarPOSIXError(
                operation: "open bundle directory without following symbolic links",
                path: bundleURL.path
            )
        }
        defer { Darwin.close(directoryFD) }

        let filename = GenotypeAnnotationSidecar.filename
        let sidecarFD = filename.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sidecarFD >= 0 else {
            if errno == ENOENT { return nil }
            throw annotationSidecarPOSIXError(
                operation: "open annotation sidecar without following symbolic links",
                path: annotationSidecarURL(forBundleAt: bundleURL).path
            )
        }
        defer { Darwin.close(sidecarFD) }

        var status = stat()
        guard Darwin.fstat(sidecarFD, &status) == 0 else {
            throw annotationSidecarPOSIXError(
                operation: "inspect annotation sidecar",
                path: annotationSidecarURL(forBundleAt: bundleURL).path
            )
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw annotationSidecarPOSIXError(
                operation: "validate annotation sidecar as a regular file",
                path: annotationSidecarURL(forBundleAt: bundleURL).path,
                code: EINVAL
            )
        }

        var data = Data()
        if status.st_size > 0, status.st_size <= Int.max {
            data.reserveCapacity(Int(status.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sidecarFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw annotationSidecarPOSIXError(
                    operation: "read annotation sidecar",
                    path: annotationSidecarURL(forBundleAt: bundleURL).path
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func writeAnnotationSidecar(_ sidecar: GenotypeAnnotationSidecar, forBundleAt bundleURL: URL) throws {
        let data = try sidecar.encoded()
        let directoryFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            throw annotationSidecarPOSIXError(
                operation: "open bundle directory without following symbolic links",
                path: bundleURL.path
            )
        }
        defer { Darwin.close(directoryFD) }

        let filename = GenotypeAnnotationSidecar.filename
        var existingStatus = stat()
        let existingResult = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &existingStatus, AT_SYMLINK_NOFOLLOW)
        }
        if existingResult == 0 {
            guard (existingStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw annotationSidecarPOSIXError(
                    operation: "validate existing sidecar as a regular file",
                    path: annotationSidecarURL(forBundleAt: bundleURL).path,
                    code: ELOOP
                )
            }
        } else if errno != ENOENT {
            throw annotationSidecarPOSIXError(
                operation: "inspect existing sidecar without following symbolic links",
                path: annotationSidecarURL(forBundleAt: bundleURL).path
            )
        }

        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let temporaryFD = temporaryName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard temporaryFD >= 0 else {
            throw annotationSidecarPOSIXError(
                operation: "create atomic sidecar staging file",
                path: bundleURL.appendingPathComponent(temporaryName).path
            )
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    temporaryFD,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw annotationSidecarPOSIXError(
                        operation: "write atomic sidecar staging file",
                        path: bundleURL.appendingPathComponent(temporaryName).path
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw annotationSidecarPOSIXError(
                operation: "synchronize atomic sidecar staging file",
                path: bundleURL.appendingPathComponent(temporaryName).path
            )
        }
        let renameResult = temporaryName.withCString { temporaryCString in
            filename.withCString { filenameCString in
                Darwin.renameat(directoryFD, temporaryCString, directoryFD, filenameCString)
            }
        }
        guard renameResult == 0 else {
            throw annotationSidecarPOSIXError(
                operation: "atomically publish annotation sidecar",
                path: annotationSidecarURL(forBundleAt: bundleURL).path
            )
        }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw annotationSidecarPOSIXError(
                operation: "synchronize annotation sidecar directory",
                path: bundleURL.path
            )
        }
    }

    private static func annotationSidecarPOSIXError(
        operation: String,
        path: String,
        code: Int32 = errno
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not \(operation) at \(path): \(String(cString: Darwin.strerror(code)))",
            ]
        )
    }
}
