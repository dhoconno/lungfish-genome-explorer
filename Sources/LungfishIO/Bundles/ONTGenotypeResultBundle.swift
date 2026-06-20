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
    public let haplotypeAnalysisPath: String?
    public let activeHaplotypeAnalysisRevisionID: String?
    public let haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]?
    public let haplotypeDefinitionSetID: String?
    public let haplotypeAssayID: String?
    public let presetID: String?
    public let presetVersion: String?
    public let createdAt: String?

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
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil,
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil
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
        self.haplotypeAnalysisPath = haplotypeAnalysisPath
        self.activeHaplotypeAnalysisRevisionID = activeHaplotypeAnalysisRevisionID
        self.haplotypeAnalysisRevisions = haplotypeAnalysisRevisions
        self.haplotypeDefinitionSetID = haplotypeDefinitionSetID
        self.haplotypeAssayID = haplotypeAssayID
        self.presetID = presetID
        self.presetVersion = presetVersion
        self.createdAt = createdAt
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
        haplotypeAnalysisPath: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        haplotypeAssayID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        createdAt: String? = nil
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
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: nil,
            haplotypeAnalysisRevisions: nil
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
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]? = nil
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
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: haplotypeAnalysisRevisions
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
        createdAt: String? = nil
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
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            haplotypeAssayID: haplotypeAssayID,
            presetID: presetID,
            presetVersion: presetVersion,
            createdAt: createdAt,
            activeHaplotypeAnalysisRevisionID: nil,
            haplotypeAnalysisRevisions: nil
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
        if passedAlignments < 20 || passedUniqueReads < 5 {
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
    public let haplotypeAnalysisURL: URL?

    public init(
        workbookURL: URL,
        primaryWorkbookURL: URL? = nil,
        longSummaryCSVURL: URL,
        sampleSummaryCSVURL: URL,
        statsJSONURL: URL,
        provenanceURL: URL,
        haplotypeAnalysisURL: URL? = nil
    ) {
        self.workbookURL = workbookURL.standardizedFileURL
        self.primaryWorkbookURL = (primaryWorkbookURL ?? workbookURL).standardizedFileURL
        self.longSummaryCSVURL = longSummaryCSVURL.standardizedFileURL
        self.sampleSummaryCSVURL = sampleSummaryCSVURL.standardizedFileURL
        self.statsJSONURL = statsJSONURL.standardizedFileURL
        self.provenanceURL = provenanceURL.standardizedFileURL
        self.haplotypeAnalysisURL = haplotypeAnalysisURL?.standardizedFileURL
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
            haplotypeAnalysisURL: haplotypeAnalysisURL
        )
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

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.manifest = manifest
        self.artifacts = artifacts
        self.stats = stats
        self.calls = calls
        self.samples = samples
        self.haplotypeAnalysis = haplotypeAnalysis
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

    public static func loadResult(from bundleURL: URL) throws -> ONTGenotypeResultBundleData {
        let manifest = try loadManifest(from: bundleURL)
        return try loadResult(from: bundleURL, manifest: manifest)
    }

    public static func loadResult(
        from bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest
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
            haplotypeAnalysisURL: manifest.haplotypeAnalysisPath.map {
                resolvedURL(for: $0, in: bundleURL)
            }
        )
        let callRows = try loadCSVRows(from: artifacts.longSummaryCSVURL)
        let sampleRows = try loadCSVRows(from: artifacts.sampleSummaryCSVURL)
        let stats = try ONTGenotypeRunStats.load(from: artifacts.statsJSONURL)
        let haplotypeAnalysis = try loadHaplotypeAnalysisIfPresent(from: artifacts.haplotypeAnalysisURL)

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
            haplotypeAnalysis: haplotypeAnalysis
        )
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

private struct OrderedSet<Element: Hashable>: Swift.Sequence {
    private var values: [Element] = []
    private var seen = Set<Element>()

    init(_ source: [Element]) {
        for value in source where seen.insert(value).inserted {
            values.append(value)
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        values.makeIterator()
    }
}

// MARK: - Annotation sidecar accessors

public extension ONTGenotypeResultBundleData {
    static func annotationSidecarURL(forBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    static func loadOrCreateAnnotationSidecar(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        let url = annotationSidecarURL(forBundleAt: bundleURL)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
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
        let url = annotationSidecarURL(forBundleAt: bundleURL)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try GenotypeAnnotationSidecar.decode(data)
        }
        return GenotypeAnnotationSidecar.empty(generatedAt: "")
    }

    static func writeAnnotationSidecar(_ sidecar: GenotypeAnnotationSidecar, forBundleAt bundleURL: URL) throws {
        let url = annotationSidecarURL(forBundleAt: bundleURL)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try sidecar.encoded()
        try data.write(to: url, options: .atomic)
    }
}
