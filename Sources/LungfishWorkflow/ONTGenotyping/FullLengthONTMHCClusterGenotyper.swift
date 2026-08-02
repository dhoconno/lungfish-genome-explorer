import Foundation
import LungfishIO

public struct FullLengthONTMHCClusterGenotypeRow: Codable, Equatable, Sendable {
    public let sample: String
    public let cluster: String
    public let clusterReads: Int
    public let allele: String
    public let alleleLength: Int
    public let alignedBases: Int
    public let score: Int
    public let referenceSequenceID: String?
    public let mappingQuality: Int?
    public let cigar: String?
    public let evidence: ONTMHCEvidenceLocator?

    public init(
        sample: String,
        cluster: String,
        clusterReads: Int,
        allele: String,
        alleleLength: Int,
        alignedBases: Int,
        score: Int,
        referenceSequenceID: String? = nil,
        mappingQuality: Int? = nil,
        cigar: String? = nil,
        evidence: ONTMHCEvidenceLocator? = nil
    ) {
        self.sample = sample
        self.cluster = cluster
        self.clusterReads = clusterReads
        self.allele = allele
        self.alleleLength = alleleLength
        self.alignedBases = alignedBases
        self.score = score
        self.referenceSequenceID = referenceSequenceID
        self.mappingQuality = mappingQuality
        self.cigar = cigar
        self.evidence = evidence
    }
}

public struct FullLengthONTMHCClusterFASTARecord: Codable, Equatable, Sendable {
    public let name: String
    public let sequence: String
    public let readCount: Int

    public init(name: String, sequence: String, readCount: Int) {
        self.name = name
        self.sequence = sequence
        self.readCount = readCount
    }
}

public enum FullLengthONTMHCClosestMatchClass: String, Codable, Equatable, Sendable {
    case `extension` = "extension"
    case snpDifferent = "snp-different"
}

public struct FullLengthONTMHCClosestMatch: Codable, Equatable, Sendable {
    public let sample: String
    public let cluster: String
    public let clusterReads: Int
    public let closestReference: String
    public let matchClass: FullLengthONTMHCClosestMatchClass
    public let closestMatchID: String
    public let nucleotidesDifferent: Int
    public let snpDifferences: Int
    public let indelBases: Int
    public let alignedBases: Int
    public let score: Int
    public let trimStart: Int?
    public let trimEnd: Int?
    public let isReverse: Bool?

    public init(
        sample: String,
        cluster: String,
        clusterReads: Int,
        closestReference: String,
        matchClass: FullLengthONTMHCClosestMatchClass,
        closestMatchID: String,
        nucleotidesDifferent: Int,
        snpDifferences: Int,
        indelBases: Int,
        alignedBases: Int,
        score: Int,
        trimStart: Int? = nil,
        trimEnd: Int? = nil,
        isReverse: Bool? = nil
    ) {
        self.sample = sample
        self.cluster = cluster
        self.clusterReads = clusterReads
        self.closestReference = closestReference
        self.matchClass = matchClass
        self.closestMatchID = closestMatchID
        self.nucleotidesDifferent = nucleotidesDifferent
        self.snpDifferences = snpDifferences
        self.indelBases = indelBases
        self.alignedBases = alignedBases
        self.score = score
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.isReverse = isReverse
    }
}

public struct FullLengthONTMHCClusterGenotypingSummary: Codable, Equatable, Sendable {
    public let rows: [FullLengthONTMHCClusterGenotypeRow]
    public let unmatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    public let cdnaMatchedClusters: [FullLengthONTMHCClusterFASTARecord]
    public let closestMatches: [FullLengthONTMHCClosestMatch]
    public let cdnaStructuralInterpretations: [FullLengthONTMHCCDNAStructuralInterpretation]

    public init(
        rows: [FullLengthONTMHCClusterGenotypeRow],
        unmatchedClusters: [FullLengthONTMHCClusterFASTARecord],
        cdnaMatchedClusters: [FullLengthONTMHCClusterFASTARecord],
        closestMatches: [FullLengthONTMHCClosestMatch] = [],
        cdnaStructuralInterpretations: [FullLengthONTMHCCDNAStructuralInterpretation] = []
    ) {
        self.rows = rows
        self.unmatchedClusters = unmatchedClusters
        self.cdnaMatchedClusters = cdnaMatchedClusters
        self.closestMatches = closestMatches
        self.cdnaStructuralInterpretations = cdnaStructuralInterpretations
    }
}

public struct FullLengthONTMHCReportRow: Codable, Equatable, Sendable {
    public let sample: String
    public let genotype: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleTotalReads: Int?
    public let sampleUniqueRetainedReads: Int
    public let sampleUniqueRetainedPercent: Double?
    public let overallInputReads: Int
    public let overallUniqueRetainedReads: Int
    public let overallUniqueRetainedPercent: Double?

}

public enum FullLengthONTMHCClusterGenotyper {
    struct Hit {
        let allele: String
        let snps: Int
        let matchedBases: Int
        let indelBases: Int
        let score: Int
        let targetStart: Int
        let targetEnd: Int
        let isReverse: Bool
    }

    struct StreamingAccumulator {
        let sampleID: String
        let clusterRecords: [FullLengthONTMHCClusterFASTARecord]
        let clusterLengths: [String: Int]
        let referenceLengths: [String: Int]
        let referenceMoleculeClasses: [String: MHCReferenceMoleculeClass]
        let referenceAlleleNames: [String: String]
        let minUnmatchedReads: Int

        private var bestKnownScoreByCluster: [String: Int] = [:]
        private var bestKnownHitsByCluster: [String: [String: Hit]] = [:]
        private var closestHitByCluster: [String: Hit] = [:]
        private var cdnaInterpretationsByCluster: [String: [String: FullLengthONTMHCCDNAStructuralInterpretation]] = [:]

        init(
            sampleID: String,
            clusterRecords: [FullLengthONTMHCClusterFASTARecord],
            referenceLengths: [String: Int],
            referenceMoleculeClasses: [String: MHCReferenceMoleculeClass],
            referenceAlleleNames: [String: String] = [:],
            minUnmatchedReads: Int
        ) {
            self.sampleID = sampleID
            self.clusterRecords = clusterRecords
            self.clusterLengths = Dictionary(
                uniqueKeysWithValues: clusterRecords.map { ($0.name, $0.sequence.count) }
            )
            self.referenceLengths = referenceLengths
            self.referenceMoleculeClasses = referenceMoleculeClasses
            self.referenceAlleleNames = referenceAlleleNames
            self.minUnmatchedReads = minUnmatchedReads
        }

        mutating func consume(
            allele: String,
            cluster: String,
            flag: Int,
            position: Int,
            metrics: FullLengthONTMHCSAMMetrics
        ) throws {
            guard let alleleLength = referenceLengths[allele], alleleLength > 0 else {
                throw StreamingAccumulatorError.unknownOrEmptyAllele(allele)
            }
            guard let clusterLength = clusterLengths[cluster], clusterLength > 0 else {
                throw StreamingAccumulatorError.unknownOrEmptyCluster(cluster)
            }
            guard let moleculeClass = referenceMoleculeClasses[allele] else {
                throw StreamingAccumulatorError.unknownMoleculeClass(allele)
            }
            let score = try alignmentScore(for: metrics)
            let targetOffset = try FullLengthONTMHCSAMMetrics.subtracting(
                metrics.referenceSpan,
                1,
                metric: .targetEnd,
                operation: .subtract
            )
            let targetEnd = try FullLengthONTMHCSAMMetrics.adding(
                position,
                targetOffset,
                metric: .targetEnd,
                operation: .add
            )
            let hit = Hit(
                allele: allele,
                snps: metrics.snps,
                matchedBases: metrics.matches,
                indelBases: metrics.nonIntronIndelBases,
                score: score,
                targetStart: position,
                targetEnd: targetEnd,
                isReverse: flag & 16 != 0
            )

            if let current = closestHitByCluster[cluster] {
                if isBetterClosestHit(hit, than: current) {
                    closestHitByCluster[cluster] = hit
                }
            } else {
                closestHitByCluster[cluster] = hit
            }

            let isKnownGenotype: Bool
            switch moleculeClass {
            case .genomicDNA:
                isKnownGenotype = hit.snps == 0
            case .cDNA:
                let interpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyCohort(
                    referenceSequenceID: allele,
                    clusterID: cluster,
                    cDNAReferenceLength: alleleLength,
                    clusterLength: clusterLength,
                    targetStart: position,
                    isReverse: hit.isReverse,
                    metrics: metrics
                )
                if interpretation.relationship != .ineligible {
                    retainBestCDNAInterpretation(interpretation, for: cluster)
                }
                isKnownGenotype = interpretation.relationship == .known
            }
            guard isKnownGenotype else { return }

            if let currentBestScore = bestKnownScoreByCluster[cluster] {
                if score > currentBestScore {
                    bestKnownScoreByCluster[cluster] = score
                    bestKnownHitsByCluster[cluster] = [allele: hit]
                } else if score == currentBestScore,
                          bestKnownHitsByCluster[cluster]?[allele] == nil {
                    bestKnownHitsByCluster[cluster, default: [:]][allele] = hit
                }
            } else {
                bestKnownScoreByCluster[cluster] = score
                bestKnownHitsByCluster[cluster] = [allele: hit]
            }
        }

        func summary() -> FullLengthONTMHCClusterGenotypingSummary {
            let clusterRecordByName = Dictionary(
                uniqueKeysWithValues: clusterRecords.map { ($0.name, $0) }
            )
            let matchedClusters = Set(bestKnownHitsByCluster.keys)
            var cdnaClusters = Set<String>()
            var rows: [FullLengthONTMHCClusterGenotypeRow] = []

            for cluster in bestKnownHitsByCluster.keys.sorted(by: localizedStandardLessThan) {
                guard let hitsByAllele = bestKnownHitsByCluster[cluster] else { continue }
                for hit in hitsByAllele.values {
                    guard let alleleLength = referenceLengths[hit.allele], alleleLength > 0 else {
                        continue
                    }
                    if referenceMoleculeClasses[hit.allele] == .cDNA {
                        cdnaClusters.insert(cluster)
                    }
                    rows.append(FullLengthONTMHCClusterGenotypeRow(
                        sample: sampleID,
                        cluster: cluster,
                        clusterReads: parseReadCount(cluster),
                        allele: referenceAlleleNames[hit.allele] ?? hit.allele,
                        alleleLength: alleleLength,
                        alignedBases: hit.matchedBases,
                        score: hit.score,
                        referenceSequenceID: referenceAlleleNames[hit.allele] == nil ? nil : hit.allele
                    ))
                }
            }

            let unmatched = clusterRecords.filter {
                !matchedClusters.contains($0.name) && $0.readCount >= minUnmatchedReads
            }
            let closestMatches = unmatched.compactMap { record in
                closestHitByCluster[record.name].map {
                    closestMatch(sampleID: sampleID, cluster: record, hit: $0)
                }
            }
            let cdna = cdnaClusters.sorted(by: localizedStandardLessThan)
                .compactMap { clusterRecordByName[$0] }

            return FullLengthONTMHCClusterGenotypingSummary(
                rows: rows.sorted {
                    if $0.sample != $1.sample {
                        return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
                    }
                    if $0.cluster != $1.cluster {
                        return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
                    }
                    return $0.allele.localizedStandardCompare($1.allele) == .orderedAscending
                },
                unmatchedClusters: unmatched,
                cdnaMatchedClusters: cdna,
                closestMatches: closestMatches.sorted {
                    if $0.sample != $1.sample {
                        return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
                    }
                    if $0.closestMatchID != $1.closestMatchID {
                        return $0.closestMatchID.localizedStandardCompare($1.closestMatchID) == .orderedAscending
                    }
                    return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
                },
                cdnaStructuralInterpretations: cdnaInterpretationsByCluster
                    .values
                    .flatMap(\.values)
                    .sorted {
                        if $0.clusterID != $1.clusterID {
                            return $0.clusterID.localizedStandardCompare($1.clusterID) == .orderedAscending
                        }
                        return $0.referenceSequenceID.localizedStandardCompare($1.referenceSequenceID) == .orderedAscending
                    }
            )
        }

        private mutating func retainBestCDNAInterpretation(
            _ interpretation: FullLengthONTMHCCDNAStructuralInterpretation,
            for cluster: String
        ) {
            let referenceID = interpretation.referenceSequenceID
            guard let current = cdnaInterpretationsByCluster[cluster]?[referenceID] else {
                cdnaInterpretationsByCluster[cluster, default: [:]][referenceID] = interpretation
                return
            }
            if interpretation.alignmentScore > current.alignmentScore
                || (interpretation.alignmentScore == current.alignmentScore
                    && interpretation.cDNAReferenceCoverage > current.cDNAReferenceCoverage)
                || (interpretation.alignmentScore == current.alignmentScore
                    && interpretation.cDNAReferenceCoverage == current.cDNAReferenceCoverage
                    && interpretation.clusterCoverage > current.clusterCoverage)
                || (interpretation.alignmentScore == current.alignmentScore
                    && interpretation.cDNAReferenceCoverage == current.cDNAReferenceCoverage
                    && interpretation.clusterCoverage == current.clusterCoverage
                    && interpretation.relationship == .extension
                    && current.relationship != .extension) {
                cdnaInterpretationsByCluster[cluster, default: [:]][referenceID] = interpretation
            }
        }
    }

    enum StreamingAccumulatorError: Error, LocalizedError {
        case unknownOrEmptyAllele(String)
        case unknownOrEmptyCluster(String)
        case unknownMoleculeClass(String)

        var errorDescription: String? {
            switch self {
            case .unknownOrEmptyAllele(let allele):
                return "Cannot genotype unknown or empty allele '\(allele)'."
            case .unknownOrEmptyCluster(let cluster):
                return "Cannot genotype unknown or empty cluster '\(cluster)'."
            case .unknownMoleculeClass(let allele):
                return "Cannot genotype allele '\(allele)' without a resolved molecule class."
            }
        }
    }

    public static func genotypeSummary(
        sampleID: String,
        clustersFASTAURL: URL,
        referenceFASTAURL: URL,
        samText: String,
        cdnaThreshold: Int = 2_000,
        minUnmatchedReads: Int = 5
    ) throws -> FullLengthONTMHCClusterGenotypingSummary {
        let referenceLengths = try readFASTARecords(from: referenceFASTAURL)
            .reduce(into: [String: Int]()) { values, record in
                values[record.name] = record.sequence.count
            }
        let clusterRecords = try readFASTARecords(from: clustersFASTAURL)
        let clusterRecordByName = Dictionary(uniqueKeysWithValues: clusterRecords.map { ($0.name, $0) })
        var clusterHits: [String: [Hit]] = [:]

        for rawLine in samText.split(whereSeparator: \.isNewline).map(String.init) {
            guard !rawLine.hasPrefix("@") else { continue }
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6,
                  let flag = Int(fields[1]),
                  let position = Int(fields[3]) else { continue }
            let allele = fields[0].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? fields[0]
            let cluster = fields[2]
            let cigar = fields[5]
            guard cluster != "*", flag & 4 == 0, cigar != "*", position > 0 else { continue }
            let nm: Int?
            if let nmField = fields.dropFirst(11).first(where: { $0.hasPrefix("NM:i:") }) {
                let rawNM = String(nmField.dropFirst(5))
                guard let parsedNM = Int(rawNM) else {
                    throw FullLengthONTMHCSAMMetricsError.invalidNM(rawNM)
                }
                nm = parsedNM
            } else {
                nm = nil
            }
            let metrics = try FullLengthONTMHCSAMMetrics(cigar: cigar, nm: nm)
            guard metrics.referenceSpan > 0 else { continue }
            let score = try alignmentScore(for: metrics)
            let targetOffset = try FullLengthONTMHCSAMMetrics.subtracting(
                metrics.referenceSpan,
                1,
                metric: .targetEnd,
                operation: .subtract
            )
            let targetEnd = try FullLengthONTMHCSAMMetrics.adding(
                position,
                targetOffset,
                metric: .targetEnd,
                operation: .add
            )
            clusterHits[cluster, default: []].append(Hit(
                allele: allele,
                snps: metrics.snps,
                matchedBases: metrics.matches,
                indelBases: metrics.nonIntronIndelBases,
                score: score,
                targetStart: position,
                targetEnd: targetEnd,
                isReverse: flag & 16 != 0
            ))
        }

        var rows: [FullLengthONTMHCClusterGenotypeRow] = []
        var matchedClusters = Set<String>()
        var cdnaClusters = Set<String>()
        var seen = Set<String>()
        for cluster in clusterHits.keys.sorted(by: localizedStandardLessThan) {
            guard let hits = clusterHits[cluster] else { continue }
            let knownGenotypeHits = hits.filter { hit in
                guard hit.snps == 0 else { return false }
                guard hit.indelBases > 0 else { return true }
                return (referenceLengths[hit.allele] ?? 0) >= cdnaThreshold
            }
            guard let bestScore = knownGenotypeHits.map(\.score).max() else { continue }
            for hit in knownGenotypeHits where hit.score == bestScore {
                let key = "\(cluster)\u{0}\(hit.allele)"
                guard seen.insert(key).inserted else { continue }
                matchedClusters.insert(cluster)
                let alleleLength = referenceLengths[hit.allele] ?? 0
                if alleleLength > 0 && alleleLength < cdnaThreshold {
                    cdnaClusters.insert(cluster)
                }
                rows.append(FullLengthONTMHCClusterGenotypeRow(
                    sample: sampleID,
                    cluster: cluster,
                    clusterReads: parseReadCount(cluster),
                    allele: hit.allele,
                    alleleLength: alleleLength,
                    alignedBases: hit.matchedBases,
                    score: hit.score
                ))
            }
        }

        let unmatched = clusterRecords
            .filter { !matchedClusters.contains($0.name) && $0.readCount >= minUnmatchedReads }
        let closestMatches = unmatched.compactMap { record -> FullLengthONTMHCClosestMatch? in
            guard let hit = bestClosestHit(clusterHits[record.name] ?? []) else {
                return nil
            }
            return closestMatch(
                sampleID: sampleID,
                cluster: record,
                hit: hit
            )
        }
        let cdna = cdnaClusters.sorted(by: localizedStandardLessThan).compactMap { clusterRecordByName[$0] }
        return FullLengthONTMHCClusterGenotypingSummary(
            rows: rows.sorted {
                if $0.sample != $1.sample { return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }
                if $0.cluster != $1.cluster { return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending }
                return $0.allele.localizedStandardCompare($1.allele) == .orderedAscending
            },
            unmatchedClusters: unmatched,
            cdnaMatchedClusters: cdna,
            closestMatches: closestMatches.sorted {
                if $0.sample != $1.sample { return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }
                if $0.closestMatchID != $1.closestMatchID {
                    return $0.closestMatchID.localizedStandardCompare($1.closestMatchID) == .orderedAscending
                }
                return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
            }
        )
    }

    private static func bestClosestHit(_ hits: [Hit]) -> Hit? {
        hits.sorted { lhs, rhs in
            if lhs.snps != rhs.snps { return lhs.snps < rhs.snps }
            if lhs.indelBases != rhs.indelBases { return lhs.indelBases < rhs.indelBases }
            if lhs.matchedBases != rhs.matchedBases { return lhs.matchedBases > rhs.matchedBases }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.allele.localizedStandardCompare(rhs.allele) == .orderedAscending
        }.first
    }

    private static func isBetterClosestHit(_ candidate: Hit, than current: Hit) -> Bool {
        if candidate.snps != current.snps { return candidate.snps < current.snps }
        if candidate.indelBases != current.indelBases { return candidate.indelBases < current.indelBases }
        if candidate.matchedBases != current.matchedBases { return candidate.matchedBases > current.matchedBases }
        if candidate.score != current.score { return candidate.score > current.score }
        return candidate.allele.localizedStandardCompare(current.allele) == .orderedAscending
    }

    private static func closestMatch(
        sampleID: String,
        cluster: FullLengthONTMHCClusterFASTARecord,
        hit: Hit
    ) -> FullLengthONTMHCClosestMatch {
        let matchClass: FullLengthONTMHCClosestMatchClass = hit.snps == 0 ? .extension : .snpDifferent
        let closestMatchID = hit.snps == 0
            ? "\(hit.allele)_extension"
            : "\(hit.allele)_\(hit.snps)SNP"
        let nucleotidesDifferent = hit.snps == 0 ? 0 : hit.snps
        return FullLengthONTMHCClosestMatch(
            sample: sampleID,
            cluster: cluster.name,
            clusterReads: cluster.readCount,
            closestReference: hit.allele,
            matchClass: matchClass,
            closestMatchID: closestMatchID,
            nucleotidesDifferent: nucleotidesDifferent,
            snpDifferences: hit.snps,
            indelBases: hit.indelBases,
            alignedBases: hit.matchedBases,
            score: hit.score,
            trimStart: min(hit.targetStart, hit.targetEnd),
            trimEnd: max(hit.targetStart, hit.targetEnd),
            isReverse: hit.isReverse
        )
    }

    static func readFASTARecords(from url: URL) throws -> [FullLengthONTMHCClusterFASTARecord] {
        var records: [FullLengthONTMHCClusterFASTARecord] = []
        var currentName: String?
        var parts: [String] = []
        func flush() {
            guard let currentName else { return }
            let sequence = parts.joined()
            records.append(FullLengthONTMHCClusterFASTARecord(
                name: currentName,
                sequence: sequence,
                readCount: parseReadCount(currentName)
            ))
        }
        try url.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                flush()
                let rawName = String(line.dropFirst())
                currentName = rawName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rawName
                parts = []
            } else {
                let sequenceLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentName != nil || !sequenceLine.isEmpty {
                    parts.append(sequenceLine)
                }
            }
        }
        flush()
        return records
    }

    static func parseReadCount(_ name: String) -> Int {
        guard let range = name.range(of: "ReadCount-") else { return 0 }
        let suffix = name[range.upperBound...]
        let digits = suffix.prefix(while: \.isNumber)
        return Int(digits) ?? 0
    }

    private static func alignmentScore(for metrics: FullLengthONTMHCSAMMetrics) throws -> Int {
        let indelPenalty = try FullLengthONTMHCSAMMetrics.multiplying(
            metrics.nonIntronIndelBases,
            10,
            metric: .alignmentScore,
            operation: .multiply(10)
        )
        let snpPenalty = try FullLengthONTMHCSAMMetrics.multiplying(
            metrics.snps,
            100,
            metric: .alignmentScore,
            operation: .multiply(100)
        )
        let scoreAfterIndels = try FullLengthONTMHCSAMMetrics.subtracting(
            metrics.matches,
            indelPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
        return try FullLengthONTMHCSAMMetrics.subtracting(
            scoreAfterIndels,
            snpPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

public enum FullLengthONTMHCClusterReportBuilder {
    private struct CallKey: Hashable {
        let sample: String
        let referenceSequenceID: String
    }

    public static func reportRows(
        genotypeRows: [FullLengthONTMHCClusterGenotypeRow],
        sampleReadCounts: [String: Int]
    ) -> [FullLengthONTMHCReportRow] {
        let sampleAssignedReads = Dictionary(grouping: genotypeRows, by: \.sample).mapValues { rows in
            assignedReadCount(genotypeRows: rows)
        }
        let overallInputReads = sampleReadCounts.values.reduce(0, +)
        let overallRetainedReads = sampleAssignedReads.values.reduce(0, +)
        let overallRetainedPercent = overallInputReads > 0
            ? Double(overallRetainedReads) / Double(overallInputReads) * 100.0
            : nil

        let rowsByCall = Dictionary(grouping: genotypeRows) { row in
            CallKey(
                sample: row.sample,
                referenceSequenceID: row.referenceSequenceID ?? row.allele
            )
        }
        let readsByCall = rowsByCall.mapValues { rows in
            Dictionary(grouping: rows, by: \.cluster).values.reduce(0) { total, clusterRows in
                total + (clusterRows.map(\.clusterReads).max() ?? 0)
            }
        }

        return readsByCall.keys.sorted(by: callKeyLess).map { key in
            let sample = key.sample
            let readCount = readsByCall[key] ?? 0
            let sampleTotal = sampleReadCounts[sample]
            let sampleRetained = sampleAssignedReads[sample] ?? 0
            let samplePercent = sampleTotal.flatMap { total -> Double? in
                total > 0 ? Double(sampleRetained) / Double(total) * 100.0 : nil
            }
            return FullLengthONTMHCReportRow(
                sample: sample,
                genotype: key.referenceSequenceID,
                passedAlignments: readCount,
                passedUniqueReads: readCount,
                sampleTotalReads: sampleTotal,
                sampleUniqueRetainedReads: sampleRetained,
                sampleUniqueRetainedPercent: samplePercent,
                overallInputReads: overallInputReads,
                overallUniqueRetainedReads: overallRetainedReads,
                overallUniqueRetainedPercent: overallRetainedPercent
            )
        }
    }

    static func assignedReadCount(genotypeRows: [FullLengthONTMHCClusterGenotypeRow]) -> Int {
        Dictionary(grouping: genotypeRows, by: \.cluster).values.reduce(0) { total, clusterRows in
            total + (clusterRows.map(\.clusterReads).max() ?? 0)
        }
    }

    private static func callKeyLess(_ lhs: CallKey, _ rhs: CallKey) -> Bool {
        if lhs.sample != rhs.sample {
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }
        return lhs.referenceSequenceID.localizedStandardCompare(rhs.referenceSequenceID) == .orderedAscending
    }
}
