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
        sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest? = nil
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
        let exactReadsBySample = Dictionary(uniqueKeysWithValues: samples.map {
            ($0.sampleID, $0.exactMatchReads)
        })
        var groups: [String: ScientificNameAccumulator] = [:]

        for target in targets {
            let scientificName = Self.scientificNameKey(for: target)
            var accumulator = groups[scientificName] ?? ScientificNameAccumulator(scientificName: scientificName)
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
            groups[scientificName] = accumulator
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

    private struct ScientificNameAccumulator {
        let scientificName: String
        var commonNames: [String] = []
        var targetIDs: [String] = []
        var sampleCounts: [String: Int] = [:]
        var potentialMatches: [String] = []
        var alternateMatches: [TwelveSAlternateMatch] = []
        var taxonGroups: [String] = []
        var taxids: [String] = []
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

public enum TwelveSAmpliconResultBundle {
    public static let directoryExtension = "lungfish12s"

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> TwelveSAmpliconResultBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(TwelveSAmpliconResultBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: TwelveSAmpliconResultBundleManifest,
        to bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    public static func loadResult(from bundleURL: URL) throws -> TwelveSAmpliconResultBundleData {
        let manifest = try loadManifest(from: bundleURL)
        return try loadResult(from: bundleURL, manifest: manifest)
    }

    public static func loadSamples(from bundleURL: URL) throws -> [TwelveSAmpliconSampleResult] {
        let manifest = try loadManifest(from: bundleURL)
        return try loadSampleTable(from: resolvedURL(for: manifest.sampleTablePath, in: bundleURL))
    }

    public static func sampleIDs(in bundleURL: URL) throws -> Set<String> {
        Set(try loadSamples(from: bundleURL).map(\.sampleID))
    }

    public static func loadResult(
        from bundleURL: URL,
        manifest: TwelveSAmpliconResultBundleManifest
    ) throws -> TwelveSAmpliconResultBundleData {
        let artifacts = TwelveSAmpliconResultArtifacts(
            referenceURL: resolvedURL(for: manifest.referencePath, in: bundleURL),
            targetTableURL: resolvedURL(for: manifest.targetTablePath, in: bundleURL),
            countMatrixURL: resolvedURL(for: manifest.countMatrixPath, in: bundleURL),
            sampleTableURL: resolvedURL(for: manifest.sampleTablePath, in: bundleURL),
            readFateURL: resolvedURL(for: manifest.readFatePath, in: bundleURL),
            alternateMatchesTableURL: manifest.alternateMatchesTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            unresolvedTableURL: manifest.unresolvedTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            unresolvedFastaURL: manifest.unresolvedFastaPath.map { resolvedURL(for: $0, in: bundleURL) },
            reassignmentsURL: manifest.reassignmentsTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            resolvedSampleMetadataURL: manifest.resolvedSampleMetadataPath.map { resolvedURL(for: $0, in: bundleURL) },
            sampleMetadataManifestURL: manifest.sampleMetadataManifestPath.map { resolvedURL(for: $0, in: bundleURL) },
            analysisSampleMetadataOriginalURL: manifest.analysisSampleMetadataOriginalPath.map { resolvedURL(for: $0, in: bundleURL) },
            provenanceURL: resolvedURL(for: manifest.provenancePath, in: bundleURL)
        )
        var targets = try loadTargets(from: artifacts.targetTableURL)
        if let alternateMatchesTableURL = artifacts.alternateMatchesTableURL,
           FileManager.default.fileExists(atPath: alternateMatchesTableURL.path) {
            let alternateMatches = try loadAlternateMatches(from: alternateMatchesTableURL)
            targets = targets.map { target in
                target.withAlternateMatches(alternateMatches[target.targetID, default: []])
            }
        }
        let targetIDs = Set(targets.map(\.targetID))
        let samples = try loadSampleTable(from: artifacts.sampleTableURL)
        let countRows = try loadCountRows(from: artifacts.countMatrixURL, validTargetIDs: targetIDs)
        let readFate = try JSONDecoder().decode(
            TwelveSAmpliconReadFate.self,
            from: Data(contentsOf: artifacts.readFateURL)
        )
        let unresolvedSequences = try artifacts.unresolvedTableURL.map(loadUnresolvedSequences(from:)) ?? []
        let reassignments: [TwelveSReassignmentRecord]
        if let reassignmentsURL = artifacts.reassignmentsURL,
           FileManager.default.fileExists(atPath: reassignmentsURL.path) {
            reassignments = loadReassignments(from: reassignmentsURL)
        } else {
            reassignments = []
        }
        let sampleMetadata = try artifacts.resolvedSampleMetadataURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? try ResolvedSampleMetadata.loadTSV(from: url) : nil
        }
        let sampleMetadataManifest = try artifacts.sampleMetadataManifestURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(TwelveSSampleMetadataSnapshotManifest.self, from: Data(contentsOf: url))
                : nil
        }

        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            samples: samples,
            targets: targets,
            countRows: countRows,
            readFate: readFate,
            unresolvedSequences: unresolvedSequences,
            reassignments: reassignments,
            sampleMetadata: sampleMetadata,
            sampleMetadataManifest: sampleMetadataManifest
        )
    }

    public static func resolvedURL(for path: String, in bundleURL: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return bundleURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    private static func loadTargets(from url: URL) throws -> [TwelveSAmpliconTarget] {
        try loadTSVRows(from: url).map { row in
            let targetID = try required(row["target_id"], column: "target_id", file: url.lastPathComponent)
            let displayName = nonEmpty(row["display_name"]) ?? targetID
            var metadata = row
            let knownColumns = [
                "target_id", "display_name", "scientific_name", "common_name",
                "taxid", "taxon_group", "taxonomy", "name_source",
                "locus", "length", "source_header"
            ]
            for column in knownColumns {
                metadata.removeValue(forKey: column)
            }
            if let header = nonEmpty(row["source_header"]) {
                for field in header.split(separator: "|").dropFirst() {
                    let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pieces.count == 2 else { continue }
                    metadata[String(pieces[0])] = String(pieces[1])
                }
            }
            return TwelveSAmpliconTarget(
                targetID: targetID,
                displayName: displayName,
                scientificName: nonEmpty(row["scientific_name"]),
                commonName: nonEmpty(row["common_name"]),
                taxid: nonEmpty(row["taxid"]),
                taxonGroup: nonEmpty(row["taxon_group"]),
                taxonomy: nonEmpty(row["taxonomy"]),
                nameSource: nonEmpty(row["name_source"]),
                locus: nonEmpty(row["locus"]),
                length: try optionalInt(row["length"], column: "length", file: url.lastPathComponent),
                sourceHeader: nonEmpty(row["source_header"]),
                metadata: metadata.filter { !$0.value.isEmpty }
            )
        }
    }

    private static func loadAlternateMatches(from url: URL) throws -> [String: [TwelveSAlternateMatch]] {
        var matchesByTarget: [String: [TwelveSAlternateMatch]] = [:]
        for row in try loadTSVRows(from: url) {
            let targetID = try required(row["target_id"], column: "target_id", file: url.lastPathComponent)
            let displayName = nonEmpty(row["display_name"])
                ?? nonEmpty(row["scientific_name"])
                ?? targetID
            matchesByTarget[targetID, default: []].append(
                TwelveSAlternateMatch(
                    displayName: displayName,
                    scientificName: nonEmpty(row["scientific_name"]),
                    commonName: nonEmpty(row["common_name"]),
                    taxid: nonEmpty(row["taxid"]),
                    taxonGroup: nonEmpty(row["taxon_group"]),
                    taxonomy: nonEmpty(row["taxonomy"]),
                    nameSource: nonEmpty(row["name_source"]),
                    reason: nonEmpty(row["reason"])
                )
            )
        }
        return matchesByTarget
    }

    private static func loadReassignments(from url: URL) -> [TwelveSReassignmentRecord] {
        guard let table = try? loadTSVRows(from: url) else { return [] }
        var records: [TwelveSReassignmentRecord] = []
        for row in table {
            guard let sequenceID = nonEmpty(row["sequence_id"]),
                  let sampleID = nonEmpty(row["sample_id"]),
                  let toSpecies = nonEmpty(row["to_species"]),
                  let toTargetID = nonEmpty(row["to_target_id"]),
                  let readsText = nonEmpty(row["reads"]),
                  let reads = Int(readsText) else {
                continue
            }
            let decidedBy = nonEmpty(row["decided_by"]) ?? "pooled"
            let candidateSpecies = (nonEmpty(row["candidate_species"]) ?? "")
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            records.append(
                TwelveSReassignmentRecord(
                    sequenceID: sequenceID,
                    sampleID: sampleID,
                    toSpecies: toSpecies,
                    toTargetID: toTargetID,
                    reads: reads,
                    decidedBy: decidedBy,
                    candidateSpecies: candidateSpecies
                )
            )
        }
        return records
    }

    private static func loadSampleTable(from url: URL) throws -> [TwelveSAmpliconSampleResult] {
        try loadTSVRows(from: url).map { row in
            let sampleID = try required(
                row["sample_id"] ?? row["sample"],
                column: "sample_id",
                file: url.lastPathComponent
            )
            let inputReads = try requiredInt(row["input_reads"], column: "input_reads", file: url.lastPathComponent)
            let exactMatchReads = try requiredInt(
                row["exact_match_reads"],
                column: "exact_match_reads",
                file: url.lastPathComponent
            )
            let unresolvedReads = try requiredInt(
                row["unresolved_reads"],
                column: "unresolved_reads",
                file: url.lastPathComponent
            )
            let ambiguousExactReads = try optionalInt(
                row["ambiguous_exact_reads"],
                column: "ambiguous_exact_reads",
                file: url.lastPathComponent
            ) ?? 0
            let chimeraCandidateReads = try optionalInt(
                row["chimera_candidate_reads"],
                column: "chimera_candidate_reads",
                file: url.lastPathComponent
            ) ?? 0
            let reassignedReads = try optionalInt(
                row["reassigned_reads"],
                column: "reassigned_reads",
                file: url.lastPathComponent
            ) ?? 0
            return TwelveSAmpliconSampleResult(
                sampleID: sampleID,
                displayName: nonEmpty(row["display_name"]) ?? nonEmpty(row["sample_name"]) ?? sampleID,
                inputReads: inputReads,
                exactMatchReads: exactMatchReads,
                unresolvedReads: unresolvedReads,
                ambiguousExactReads: ambiguousExactReads,
                chimeraCandidateReads: chimeraCandidateReads,
                reassignedReads: reassignedReads,
                exactMatchPercent: optionalDouble(row["exact_match_percent"]) ?? percent(exactMatchReads, inputReads),
                unresolvedPercent: optionalDouble(row["unresolved_percent"]) ?? percent(unresolvedReads, inputReads)
            )
        }
    }

    private static func loadCountRows(
        from url: URL,
        validTargetIDs: Set<String>
    ) throws -> [String: [String: Int]] {
        let table = try loadTSVTable(from: url)
        guard table.headers.contains("target_id") else {
            throw TwelveSAmpliconResultBundleError.missingColumn(
                file: url.lastPathComponent,
                column: "target_id"
            )
        }
        let sampleColumns = table.headers.filter { $0 != "target_id" }
        var rowsByTarget: [String: [String: Int]] = [:]
        for row in table.rows {
            let targetID = try required(row["target_id"], column: "target_id", file: url.lastPathComponent)
            guard validTargetIDs.contains(targetID) else {
                throw TwelveSAmpliconResultBundleError.unknownTarget(targetID: targetID)
            }
            var counts: [String: Int] = [:]
            for sample in sampleColumns {
                counts[sample] = try requiredInt(row[sample], column: sample, file: url.lastPathComponent)
            }
            rowsByTarget[targetID] = counts
        }
        return rowsByTarget
    }

    private static func loadUnresolvedSequences(from url: URL) throws -> [TwelveSUnresolvedSequence] {
        try loadTSVRows(from: url).map { row in
            let statusText = nonEmpty(row["chimera_status"]) ?? TwelveSChimeraStatus.notReviewed.rawValue
            return TwelveSUnresolvedSequence(
                sequenceID: try required(row["sequence_id"], column: "sequence_id", file: url.lastPathComponent),
                sequence: try required(row["sequence"], column: "sequence", file: url.lastPathComponent),
                readCount: try requiredInt(row["read_count"], column: "read_count", file: url.lastPathComponent),
                sampleCounts: try parseSampleCounts(row["sample_counts"], file: url.lastPathComponent),
                chimeraStatus: TwelveSChimeraStatus(rawValue: statusText) ?? .notReviewed,
                note: nonEmpty(row["note"])
            )
        }
    }

    private struct TSVTable {
        let headers: [String]
        let rows: [[String: String]]
    }

    private static func loadTSVRows(from url: URL) throws -> [[String: String]] {
        try loadTSVTable(from: url).rows
    }

    private static func loadTSVTable(from url: URL) throws -> TSVTable {
        let content = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first else {
            return TSVTable(headers: [], rows: [])
        }
        let headers = splitTSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let rows = lines.dropFirst().map { line in
            let fields = splitTSVLine(line)
            var row: [String: String] = [:]
            for index in headers.indices {
                guard !headers[index].isEmpty else { continue }
                row[headers[index]] = index < fields.count ? fields[index] : ""
            }
            return row
        }
        return TSVTable(headers: headers, rows: rows)
    }

    private static func splitTSVLine(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private static func parseSampleCounts(_ value: String?, file: String) throws -> [String: Int] {
        guard let value = nonEmpty(value) else { return [:] }
        var counts: [String: Int] = [:]
        for token in value.split(separator: ",", omittingEmptySubsequences: true) {
            let pieces = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let sampleID = String(pieces[0])
            let countText = String(pieces[1])
            guard let count = Int(countText) else {
                throw TwelveSAmpliconResultBundleError.invalidInteger(
                    file: file,
                    column: "sample_counts",
                    value: countText
                )
            }
            counts[sampleID] = count
        }
        return counts
    }

    private static func required(_ value: String?, column: String, file: String) throws -> String {
        guard let value = nonEmpty(value) else {
            throw TwelveSAmpliconResultBundleError.missingColumn(file: file, column: column)
        }
        return value
    }

    private static func requiredInt(_ value: String?, column: String, file: String) throws -> Int {
        guard let value = nonEmpty(value) else {
            throw TwelveSAmpliconResultBundleError.missingColumn(file: file, column: column)
        }
        guard let intValue = Int(value) else {
            throw TwelveSAmpliconResultBundleError.invalidInteger(file: file, column: column, value: value)
        }
        return intValue
    }

    private static func optionalInt(_ value: String?, column: String, file: String) throws -> Int? {
        guard let value = nonEmpty(value) else { return nil }
        guard let intValue = Int(value) else {
            throw TwelveSAmpliconResultBundleError.invalidInteger(file: file, column: column, value: value)
        }
        return intValue
    }

    private static func optionalDouble(_ value: String?) -> Double? {
        guard var text = nonEmpty(value) else { return nil }
        if text.hasSuffix("%") {
            text.removeLast()
        }
        return Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func percent(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }
}
