import Foundation
import LungfishCore

public struct TwelveSAmpliconResultBundleManifest: Codable, Equatable, Sendable {
    public static let filename = "12s-result.json"

    public let schemaVersion: Int
    public let kind: String
    public let outputName: String
    public let analysisName: String
    public let referencePath: String
    public let targetTablePath: String
    public let countMatrixPath: String
    public let sampleTablePath: String
    public let readFatePath: String
    public let alternateMatchesTablePath: String?
    public let unresolvedTablePath: String?
    public let unresolvedFastaPath: String?
    public let reassignmentsTablePath: String?
    public let resolvedSampleMetadataPath: String?
    public let sampleMetadataManifestPath: String?
    public let analysisSampleMetadataOriginalPath: String?
    public let provenancePath: String
    public let createdAt: String?

    public init(
        schemaVersion: Int = 1,
        kind: String = "12s-amplicon-match",
        outputName: String,
        analysisName: String,
        referencePath: String,
        targetTablePath: String,
        countMatrixPath: String,
        sampleTablePath: String,
        readFatePath: String,
        alternateMatchesTablePath: String? = nil,
        unresolvedTablePath: String? = nil,
        unresolvedFastaPath: String? = nil,
        reassignmentsTablePath: String? = nil,
        resolvedSampleMetadataPath: String? = nil,
        sampleMetadataManifestPath: String? = nil,
        analysisSampleMetadataOriginalPath: String? = nil,
        provenancePath: String,
        createdAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.outputName = outputName
        self.analysisName = analysisName
        self.referencePath = referencePath
        self.targetTablePath = targetTablePath
        self.countMatrixPath = countMatrixPath
        self.sampleTablePath = sampleTablePath
        self.readFatePath = readFatePath
        self.alternateMatchesTablePath = alternateMatchesTablePath
        self.unresolvedTablePath = unresolvedTablePath
        self.unresolvedFastaPath = unresolvedFastaPath
        self.reassignmentsTablePath = reassignmentsTablePath
        self.resolvedSampleMetadataPath = resolvedSampleMetadataPath
        self.sampleMetadataManifestPath = sampleMetadataManifestPath
        self.analysisSampleMetadataOriginalPath = analysisSampleMetadataOriginalPath
        self.provenancePath = provenancePath
        self.createdAt = createdAt
    }

    public func replacingSampleMetadata(
        resolvedSampleMetadataPath: String?,
        sampleMetadataManifestPath: String?,
        analysisSampleMetadataOriginalPath: String?
    ) -> TwelveSAmpliconResultBundleManifest {
        TwelveSAmpliconResultBundleManifest(
            schemaVersion: schemaVersion,
            kind: kind,
            outputName: outputName,
            analysisName: analysisName,
            referencePath: referencePath,
            targetTablePath: targetTablePath,
            countMatrixPath: countMatrixPath,
            sampleTablePath: sampleTablePath,
            readFatePath: readFatePath,
            alternateMatchesTablePath: alternateMatchesTablePath,
            unresolvedTablePath: unresolvedTablePath,
            unresolvedFastaPath: unresolvedFastaPath,
            reassignmentsTablePath: reassignmentsTablePath,
            resolvedSampleMetadataPath: resolvedSampleMetadataPath,
            sampleMetadataManifestPath: sampleMetadataManifestPath,
            analysisSampleMetadataOriginalPath: analysisSampleMetadataOriginalPath,
            provenancePath: provenancePath,
            createdAt: createdAt
        )
    }
}

public struct TwelveSAmpliconResultArtifacts: Equatable, Sendable {
    public let referenceURL: URL
    public let targetTableURL: URL
    public let countMatrixURL: URL
    public let sampleTableURL: URL
    public let readFateURL: URL
    public let alternateMatchesTableURL: URL?
    public let unresolvedTableURL: URL?
    public let unresolvedFastaURL: URL?
    public let reassignmentsURL: URL?
    public let resolvedSampleMetadataURL: URL?
    public let sampleMetadataManifestURL: URL?
    public let analysisSampleMetadataOriginalURL: URL?
    public let provenanceURL: URL

    public init(
        referenceURL: URL,
        targetTableURL: URL,
        countMatrixURL: URL,
        sampleTableURL: URL,
        readFateURL: URL,
        alternateMatchesTableURL: URL? = nil,
        unresolvedTableURL: URL?,
        unresolvedFastaURL: URL?,
        reassignmentsURL: URL? = nil,
        resolvedSampleMetadataURL: URL? = nil,
        sampleMetadataManifestURL: URL? = nil,
        analysisSampleMetadataOriginalURL: URL? = nil,
        provenanceURL: URL
    ) {
        self.referenceURL = referenceURL.standardizedFileURL
        self.targetTableURL = targetTableURL.standardizedFileURL
        self.countMatrixURL = countMatrixURL.standardizedFileURL
        self.sampleTableURL = sampleTableURL.standardizedFileURL
        self.readFateURL = readFateURL.standardizedFileURL
        self.alternateMatchesTableURL = alternateMatchesTableURL?.standardizedFileURL
        self.unresolvedTableURL = unresolvedTableURL?.standardizedFileURL
        self.unresolvedFastaURL = unresolvedFastaURL?.standardizedFileURL
        self.reassignmentsURL = reassignmentsURL?.standardizedFileURL
        self.resolvedSampleMetadataURL = resolvedSampleMetadataURL?.standardizedFileURL
        self.sampleMetadataManifestURL = sampleMetadataManifestURL?.standardizedFileURL
        self.analysisSampleMetadataOriginalURL = analysisSampleMetadataOriginalURL?.standardizedFileURL
        self.provenanceURL = provenanceURL.standardizedFileURL
    }
}

public struct TwelveSSampleMetadataSnapshotManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let precedence: [String]
    public let emptyOverrideCells: String
    public let sampleCount: Int
    public let columns: [String]
    public let sources: [SampleMetadataSourceSummary]
    public let warnings: [String]

    public init(
        schemaVersion: Int = 1,
        precedence: [String],
        emptyOverrideCells: String,
        sampleCount: Int,
        columns: [String],
        sources: [SampleMetadataSourceSummary],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.precedence = precedence
        self.emptyOverrideCells = emptyOverrideCells
        self.sampleCount = sampleCount
        self.columns = columns
        self.sources = sources
        self.warnings = warnings
    }

    public var hasAnalysisMetadata: Bool {
        sources.contains { $0.kind == .analysisOverride }
    }

    public var hasFASTQMetadata: Bool {
        sources.contains { $0.kind == .fastqBundle || $0.kind == .fastqFolder }
    }
}

public struct TwelveSAlternateMatch: Codable, Equatable, Sendable {
    public let displayName: String
    public let scientificName: String?
    public let commonName: String?
    public let taxid: String?
    public let taxonGroup: String?
    public let taxonomy: String?
    public let nameSource: String?
    public let reason: String?

    public init(
        displayName: String,
        scientificName: String? = nil,
        commonName: String? = nil,
        taxid: String? = nil,
        taxonGroup: String? = nil,
        taxonomy: String? = nil,
        nameSource: String? = nil,
        reason: String? = nil
    ) {
        self.displayName = displayName
        self.scientificName = scientificName
        self.commonName = commonName
        self.taxid = taxid
        self.taxonGroup = taxonGroup
        self.taxonomy = taxonomy
        self.nameSource = nameSource
        self.reason = reason
    }
}

public struct TwelveSAmpliconTarget: Codable, Equatable, Sendable {
    public let targetID: String
    public let displayName: String
    public let scientificName: String?
    public let commonName: String?
    public let taxid: String?
    public let taxonGroup: String?
    public let taxonomy: String?
    public let nameSource: String?
    public let locus: String?
    public let length: Int?
    public let sourceHeader: String?
    public let metadata: [String: String]
    public let alternateMatches: [TwelveSAlternateMatch]

    public init(
        targetID: String,
        displayName: String,
        scientificName: String? = nil,
        commonName: String? = nil,
        taxid: String? = nil,
        taxonGroup: String? = nil,
        taxonomy: String? = nil,
        nameSource: String? = nil,
        locus: String? = nil,
        length: Int? = nil,
        sourceHeader: String? = nil,
        metadata: [String: String] = [:],
        alternateMatches: [TwelveSAlternateMatch] = []
    ) {
        self.targetID = targetID
        self.displayName = displayName
        self.scientificName = scientificName
        self.commonName = commonName
        self.taxid = taxid
        self.taxonGroup = taxonGroup
        self.taxonomy = taxonomy
        self.nameSource = nameSource
        self.locus = locus
        self.length = length
        self.sourceHeader = sourceHeader
        self.metadata = metadata
        self.alternateMatches = alternateMatches
    }

    public func withAlternateMatches(_ alternateMatches: [TwelveSAlternateMatch]) -> TwelveSAmpliconTarget {
        TwelveSAmpliconTarget(
            targetID: targetID,
            displayName: displayName,
            scientificName: scientificName,
            commonName: commonName,
            taxid: taxid,
            taxonGroup: taxonGroup,
            taxonomy: taxonomy,
            nameSource: nameSource,
            locus: locus,
            length: length,
            sourceHeader: sourceHeader,
            metadata: metadata,
            alternateMatches: alternateMatches
        )
    }
}

public struct TwelveSAmpliconSampleResult: Codable, Equatable, Sendable {
    public let sampleID: String
    public let displayName: String
    public let inputReads: Int
    public let exactMatchReads: Int
    public let unresolvedReads: Int
    public let ambiguousExactReads: Int
    public let chimeraCandidateReads: Int
    public let reassignedReads: Int
    public let exactMatchPercent: Double
    public let unresolvedPercent: Double

    public init(
        sampleID: String,
        displayName: String,
        inputReads: Int,
        exactMatchReads: Int,
        unresolvedReads: Int,
        ambiguousExactReads: Int,
        chimeraCandidateReads: Int,
        reassignedReads: Int = 0,
        exactMatchPercent: Double,
        unresolvedPercent: Double
    ) {
        self.sampleID = sampleID
        self.displayName = displayName
        self.inputReads = inputReads
        self.exactMatchReads = exactMatchReads
        self.unresolvedReads = unresolvedReads
        self.ambiguousExactReads = ambiguousExactReads
        self.chimeraCandidateReads = chimeraCandidateReads
        self.reassignedReads = reassignedReads
        self.exactMatchPercent = exactMatchPercent
        self.unresolvedPercent = unresolvedPercent
    }
}

public struct TwelveSAmpliconReadFate: Codable, Equatable, Sendable {
    public let totalReads: Int
    public let exactMatchReads: Int
    public let unresolvedReads: Int
    public let ambiguousExactReads: Int
    public let chimeraCandidateReads: Int

    public init(
        totalReads: Int,
        exactMatchReads: Int,
        unresolvedReads: Int,
        ambiguousExactReads: Int,
        chimeraCandidateReads: Int
    ) {
        self.totalReads = totalReads
        self.exactMatchReads = exactMatchReads
        self.unresolvedReads = unresolvedReads
        self.ambiguousExactReads = ambiguousExactReads
        self.chimeraCandidateReads = chimeraCandidateReads
    }

    public var exactMatchPercent: Double {
        percentage(exactMatchReads, of: totalReads)
    }

    public var unresolvedPercent: Double {
        percentage(unresolvedReads, of: totalReads)
    }

    private func percentage(_ numerator: Int, of denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }
}

public enum TwelveSChimeraStatus: String, Codable, Equatable, Sendable {
    case notReviewed = "not_reviewed"
    case notDetected = "not_detected"
    case candidate
    case confirmed

    public var displayName: String {
        switch self {
        case .notReviewed:
            return "Not Reviewed"
        case .notDetected:
            return "Not Detected"
        case .candidate:
            return "Candidate"
        case .confirmed:
            return "Confirmed"
        }
    }
}

public struct TwelveSUnresolvedSequence: Codable, Equatable, Sendable {
    public let sequenceID: String
    public let sequence: String
    public let readCount: Int
    public let sampleCounts: [String: Int]
    public let chimeraStatus: TwelveSChimeraStatus
    public let note: String?

    public init(
        sequenceID: String,
        sequence: String,
        readCount: Int,
        sampleCounts: [String: Int],
        chimeraStatus: TwelveSChimeraStatus,
        note: String? = nil
    ) {
        self.sequenceID = sequenceID
        self.sequence = sequence
        self.readCount = readCount
        self.sampleCounts = sampleCounts
        self.chimeraStatus = chimeraStatus
        self.note = note
    }
}

public struct TwelveSReassignmentRecord: Equatable, Sendable {
    public let sequenceID: String
    public let sampleID: String
    public let toSpecies: String
    public let toTargetID: String
    public let reads: Int
    public let decidedBy: String
    public let candidateSpecies: [String]

    public init(
        sequenceID: String,
        sampleID: String,
        toSpecies: String,
        toTargetID: String,
        reads: Int,
        decidedBy: String,
        candidateSpecies: [String]
    ) {
        self.sequenceID = sequenceID
        self.sampleID = sampleID
        self.toSpecies = toSpecies
        self.toTargetID = toTargetID
        self.reads = reads
        self.decidedBy = decidedBy
        self.candidateSpecies = candidateSpecies
    }
}

public struct TwelveSTargetCountRow: Equatable, Sendable {
    public let target: TwelveSAmpliconTarget
    public let sampleCounts: [String: Int]
    public let sampleExactReadTotals: [String: Int]

    public init(
        target: TwelveSAmpliconTarget,
        sampleCounts: [String: Int],
        sampleExactReadTotals: [String: Int]
    ) {
        self.target = target
        self.sampleCounts = sampleCounts
        self.sampleExactReadTotals = sampleExactReadTotals
    }

    public var targetID: String {
        target.targetID
    }

    public var totalExactReads: Int {
        sampleCounts.values.reduce(0, +)
    }

    public var maxSamplePercent: Double {
        sampleCounts.reduce(0) { best, entry in
            guard let denominator = sampleExactReadTotals[entry.key], denominator > 0 else {
                return best
            }
            let percent = Double(entry.value) / Double(denominator) * 100
            return max(best, percent)
        }
    }

    public func count(forSample sampleID: String) -> Int {
        sampleCounts[sampleID, default: 0]
    }
}

public struct TwelveSScientificNameCountRow: Equatable, Sendable {
    public let scientificName: String
    public let commonNames: [String]
    public let targetIDs: [String]
    public let sampleCounts: [String: Int]
    public let sampleExactReadTotals: [String: Int]
    public let potentialMatches: [String]
    public let alternateMatches: [TwelveSAlternateMatch]
    public let taxonGroups: [String]
    public let taxids: [String]

    public init(
        scientificName: String,
        commonNames: [String] = [],
        targetIDs: [String],
        sampleCounts: [String: Int],
        sampleExactReadTotals: [String: Int],
        potentialMatches: [String] = [],
        alternateMatches: [TwelveSAlternateMatch] = [],
        taxonGroups: [String] = [],
        taxids: [String] = []
    ) {
        self.scientificName = scientificName
        self.commonNames = Self.uniquedNonEmpty(commonNames)
        self.targetIDs = Self.uniquedNonEmpty(targetIDs)
        self.sampleCounts = sampleCounts
        self.sampleExactReadTotals = sampleExactReadTotals
        self.potentialMatches = Self.uniquedNonEmpty(potentialMatches)
        self.alternateMatches = Self.uniquedAlternateMatches(alternateMatches)
        self.taxonGroups = Self.uniquedNonEmpty(taxonGroups)
        self.taxids = Self.uniquedNonEmpty(taxids)
    }

    public var totalExactReads: Int {
        sampleCounts.values.reduce(0, +)
    }

    public var referenceTargetCount: Int {
        targetIDs.count
    }

    public var commonNamesText: String {
        commonNames.joined(separator: "; ")
    }

    public var potentialMatchesText: String {
        potentialMatches.joined(separator: "; ")
    }

    public var maxSamplePercent: Double {
        sampleCounts.reduce(0) { best, entry in
            guard let denominator = sampleExactReadTotals[entry.key], denominator > 0 else {
                return best
            }
            let percent = Double(entry.value) / Double(denominator) * 100
            return max(best, percent)
        }
    }

    public func count(forSample sampleID: String) -> Int {
        sampleCounts[sampleID, default: 0]
    }

    private static func uniquedNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func uniquedAlternateMatches(_ values: [TwelveSAlternateMatch]) -> [TwelveSAlternateMatch] {
        var seen = Set<String>()
        var result: [TwelveSAlternateMatch] = []
        for value in values {
            let key = [
                value.scientificName ?? value.displayName,
                value.taxid ?? "",
                value.reason ?? "",
            ].joined(separator: "\u{0}")
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

public struct TwelveSAmpliconResultBundleData: Equatable, Sendable {
    public let bundleURL: URL
    public let manifest: TwelveSAmpliconResultBundleManifest
    public let artifacts: TwelveSAmpliconResultArtifacts
    public let samples: [TwelveSAmpliconSampleResult]
    public let targets: [TwelveSAmpliconTarget]
    public let countRows: [String: [String: Int]]
    public let readFate: TwelveSAmpliconReadFate
    public let unresolvedSequences: [TwelveSUnresolvedSequence]
    public let reassignments: [TwelveSReassignmentRecord]
    public let sampleMetadata: ResolvedSampleMetadata?
    public let sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest?
    private let precomputedScientificNameRows: [TwelveSScientificNameCountRow]?

    public init(
        bundleURL: URL,
        manifest: TwelveSAmpliconResultBundleManifest,
        artifacts: TwelveSAmpliconResultArtifacts,
        samples: [TwelveSAmpliconSampleResult],
        targets: [TwelveSAmpliconTarget],
        countRows: [String: [String: Int]],
        readFate: TwelveSAmpliconReadFate,
        unresolvedSequences: [TwelveSUnresolvedSequence],
        reassignments: [TwelveSReassignmentRecord] = [],
        sampleMetadata: ResolvedSampleMetadata? = nil,
        sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest? = nil,
        scientificNameRows: [TwelveSScientificNameCountRow]? = nil
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.manifest = manifest
        self.artifacts = artifacts
        self.samples = samples
        self.targets = targets
        self.countRows = countRows
        self.readFate = readFate
        self.unresolvedSequences = unresolvedSequences
        self.reassignments = reassignments
        self.sampleMetadata = sampleMetadata
        self.sampleMetadataManifest = sampleMetadataManifest
        self.precomputedScientificNameRows = scientificNameRows
    }

    public var sampleNames: [String] {
        samples.map(\.sampleID)
    }

    public var targetRows: [TwelveSTargetCountRow] {
        let exactReadsBySample = Dictionary(uniqueKeysWithValues: samples.map {
            ($0.sampleID, $0.exactMatchReads)
        })
        return targets.map { target in
            TwelveSTargetCountRow(
                target: target,
                sampleCounts: countRows[target.targetID, default: [:]],
                sampleExactReadTotals: exactReadsBySample
            )
        }.sorted { lhs, rhs in
            if lhs.totalExactReads != rhs.totalExactReads {
                return lhs.totalExactReads > rhs.totalExactReads
            }
            return lhs.target.displayName.localizedStandardCompare(rhs.target.displayName) == .orderedAscending
        }
    }

    public var scientificNameRows: [TwelveSScientificNameCountRow] {
        if let precomputedScientificNameRows {
            return precomputedScientificNameRows
        }
        return Self.buildScientificNameRows(targets: targets, samples: samples, countRows: countRows)
    }

    static func buildScientificNameRows(
        targets: [TwelveSAmpliconTarget],
        samples: [TwelveSAmpliconSampleResult],
        countRows: [String: [String: Int]]
    ) -> [TwelveSScientificNameCountRow] {
        let exactReadsBySample = Dictionary(uniqueKeysWithValues: samples.map {
            ($0.sampleID, $0.exactMatchReads)
        })
        var groups: [String: ScientificNameAccumulator] = [:]

        for target in targets {
            let scientificName = Self.scientificNameKey(for: target)
            let accumulator: ScientificNameAccumulator
            if let existing = groups[scientificName] {
                accumulator = existing
            } else {
                accumulator = ScientificNameAccumulator(scientificName: scientificName)
                groups[scientificName] = accumulator
            }
            accumulator.commonNames.append(target.commonName ?? "")
            accumulator.targetIDs.append(target.targetID)
            accumulator.potentialMatches.append(contentsOf: Self.potentialMatches(for: target))
            accumulator.alternateMatches.append(contentsOf: target.alternateMatches)
            accumulator.taxonGroups.append(target.taxonGroup ?? "")
            accumulator.taxids.append(target.taxid ?? "")
            accumulator.taxonGroups.append(contentsOf: target.alternateMatches.map { $0.taxonGroup ?? "" })
            accumulator.taxids.append(contentsOf: target.alternateMatches.map { $0.taxid ?? "" })
            for (sampleID, count) in countRows[target.targetID, default: [:]] {
                accumulator.sampleCounts[sampleID, default: 0] += count
            }
        }

        return groups.values.map { accumulator in
            TwelveSScientificNameCountRow(
                scientificName: accumulator.scientificName,
                commonNames: accumulator.commonNames,
                targetIDs: accumulator.targetIDs,
                sampleCounts: accumulator.sampleCounts,
                sampleExactReadTotals: exactReadsBySample,
                potentialMatches: accumulator.potentialMatches,
                alternateMatches: accumulator.alternateMatches,
                taxonGroups: accumulator.taxonGroups,
                taxids: accumulator.taxids
            )
        }.sorted { lhs, rhs in
            if lhs.totalExactReads != rhs.totalExactReads {
                return lhs.totalExactReads > rhs.totalExactReads
            }
            return lhs.scientificName.localizedStandardCompare(rhs.scientificName) == .orderedAscending
        }
    }

    public var chimeraCandidateCount: Int {
        unresolvedSequences.filter { $0.chimeraStatus == .candidate || $0.chimeraStatus == .confirmed }.count
    }

    private final class ScientificNameAccumulator {
        let scientificName: String
        var commonNames: [String] = []
        var targetIDs: [String] = []
        var sampleCounts: [String: Int] = [:]
        var potentialMatches: [String] = []
        var alternateMatches: [TwelveSAlternateMatch] = []
        var taxonGroups: [String] = []
        var taxids: [String] = []

        init(scientificName: String) {
            self.scientificName = scientificName
        }
    }

    private static func scientificNameKey(for target: TwelveSAmpliconTarget) -> String {
        if let scientificName = nonEmpty(target.scientificName) {
            return scientificName
        }
        if let parsed = parseScientificName(fromDisplayName: target.displayName) {
            return parsed
        }
        return target.displayName
    }

    private static func potentialMatches(for target: TwelveSAmpliconTarget) -> [String] {
        if !target.alternateMatches.isEmpty {
            return target.alternateMatches.map(\.displayName)
        }
        let raw = nonEmpty(target.metadata["also_matches"])
            ?? metadataValue(named: "also_matches", in: target.sourceHeader)
        guard let raw else { return [] }
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func metadataValue(named key: String, in sourceHeader: String?) -> String? {
        guard let sourceHeader else { return nil }
        for field in sourceHeader.split(separator: "|").dropFirst() {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let fieldKey = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard fieldKey == key else { continue }
            return nonEmpty(String(pieces[1]))
        }
        return nil
    }

    private static func parseScientificName(fromDisplayName displayName: String) -> String? {
        guard let open = displayName.firstIndex(of: "("),
              let close = displayName.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let start = displayName.index(after: open)
        return nonEmpty(String(displayName[start..<close]))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum TwelveSAmpliconResultBundleError: Error, Equatable, CustomStringConvertible {
    case missingColumn(file: String, column: String)
    case invalidInteger(file: String, column: String, value: String)
    case unknownTarget(targetID: String)

    public var description: String {
        switch self {
        case let .missingColumn(file, column):
            return "\(file) is missing required column '\(column)'"
        case let .invalidInteger(file, column, value):
            return "\(file) column '\(column)' expected integer value, found '\(value)'"
        case let .unknownTarget(targetID):
            return "sample-target-counts.tsv references unknown target '\(targetID)'"
        }
    }
}
