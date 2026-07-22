import Foundation
import LungfishIO

/// Streams the final cohort SAM into the compact, per-target evidence shape used by
/// candidate observations. Coordinate-level alignment details are retained only long
/// enough to collapse schema-v1 locator identities and rank biological relationships.
struct FullLengthONTMHCGenotypingHitSummaryAccumulator {
    private struct LocatorIdentity: Hashable {
        let bamPathID: Int
        let queryNameID: Int
        let referenceNameID: Int
        let readGroupID: Int?
        let referenceStart: Int
        let cigarID: Int
    }

    private struct StringInterner {
        private var ids: [String: Int] = [:]

        mutating func id(for value: String) -> Int {
            if let existing = ids[value] { return existing }
            let newID = ids.count
            ids[value] = newID
            return newID
        }
    }

    private struct AlignmentRecord {
        let queryName: String
        let locatorIdentity: LocatorIdentity
    }

    private struct BiologicalRank: Equatable, Comparable {
        let snps: Int
        let indelBases: Int
        let matchedBases: Int
        let score: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.snps != rhs.snps { return lhs.snps < rhs.snps }
            if lhs.indelBases != rhs.indelBases { return lhs.indelBases < rhs.indelBases }
            if lhs.matchedBases != rhs.matchedBases { return lhs.matchedBases > rhs.matchedBases }
            return lhs.score > rhs.score
        }
    }

    private struct TargetAccumulator {
        var locatorIdentities = Set<LocatorIdentity>()
        var queryAlignmentCounts: [String: Int] = [:]
        var exactMatchQueryNames = Set<String>()
        var closestRank: BiologicalRank?
        var closestMatchQueryNames = Set<String>()

        mutating func consume(
            record: AlignmentRecord,
            metrics: FullLengthONTMHCSAMMetrics,
            referenceLength: Int?,
            cdnaThreshold: Int
        ) throws {
            guard locatorIdentities.insert(record.locatorIdentity).inserted else { return }
            queryAlignmentCounts[record.queryName, default: 0] += 1

            let rank = BiologicalRank(
                snps: metrics.snps,
                indelBases: metrics.nonIntronIndelBases,
                matchedBases: metrics.matches,
                score: try alignmentScore(for: metrics)
            )
            if let closestRank {
                if rank < closestRank {
                    self.closestRank = rank
                    closestMatchQueryNames = [record.queryName]
                } else if rank == closestRank {
                    closestMatchQueryNames.insert(record.queryName)
                }
            } else {
                closestRank = rank
                closestMatchQueryNames = [record.queryName]
            }

            let isKnownGenotype = metrics.snps == 0
                && (metrics.nonIntronIndelBases == 0 || (referenceLength ?? 0) >= cdnaThreshold)
            if isKnownGenotype {
                exactMatchQueryNames.insert(record.queryName)
            }
        }
    }

    static func summaries(
        samURL: URL,
        bamPath: String,
        referenceLengths: [String: Int],
        cdnaThreshold: Int
    ) throws -> [String: ONTMHCGenotypingTargetHitSummary] {
        var accumulators: [String: TargetAccumulator] = [:]
        var internedStrings = StringInterner()
        let bamPathID = internedStrings.id(for: bamPath)
        try samURL.forEachLineAutoDecompressing { line in
            try Task.checkCancellation()
            guard !line.isEmpty, !line.hasPrefix("@") else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 11,
                  let flag = Int(fields[1]),
                  flag & 0x4 == 0,
                  fields[2] != "*",
                  let position = Int(fields[3]), position > 0,
                  fields[5] != "*" else { return }

            let queryName = fields[0]
            let targetName = fields[2]
            let cigar = fields[5]
            let readGroupID = fields.dropFirst(11).first(where: { $0.hasPrefix("RG:Z:") }).map {
                String($0.dropFirst(5))
            }
            let rawNM = fields.dropFirst(11).first(where: { $0.hasPrefix("NM:i:") }).map {
                String($0.dropFirst(5))
            }
            let nm: Int?
            if let rawNM {
                guard let value = Int(rawNM) else {
                    throw FullLengthONTMHCSAMMetricsError.invalidNM(rawNM)
                }
                nm = value
            } else {
                nm = nil
            }
            let metrics = try FullLengthONTMHCSAMMetrics(cigar: cigar, nm: nm)
            guard metrics.referenceSpan > 0 else { return }
            let record = AlignmentRecord(
                queryName: queryName,
                locatorIdentity: LocatorIdentity(
                    bamPathID: bamPathID,
                    queryNameID: internedStrings.id(for: queryName),
                    referenceNameID: internedStrings.id(for: targetName),
                    readGroupID: readGroupID.map { internedStrings.id(for: $0) },
                    referenceStart: position,
                    cigarID: internedStrings.id(for: cigar)
                )
            )
            try accumulators[targetName, default: TargetAccumulator()].consume(
                record: record,
                metrics: metrics,
                referenceLength: referenceLengths[queryName],
                cdnaThreshold: cdnaThreshold
            )
        }

        return try Dictionary(uniqueKeysWithValues: accumulators.map { targetName, accumulator in
            (
                targetName,
                try ONTMHCGenotypingTargetHitSummary(
                    bamPath: bamPath,
                    targetName: targetName,
                    alignmentCount: accumulator.locatorIdentities.count,
                    queryAlignmentCounts: accumulator.queryAlignmentCounts,
                    exactMatchQueryNames: accumulator.exactMatchQueryNames.sorted(by: localizedStandardLessThan),
                    closestMatchQueryNames: accumulator.closestMatchQueryNames.sorted(by: localizedStandardLessThan)
                )
            )
        })
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
        let afterIndels = try FullLengthONTMHCSAMMetrics.subtracting(
            metrics.matches,
            indelPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
        return try FullLengthONTMHCSAMMetrics.subtracting(
            afterIndels,
            snpPenalty,
            metric: .alignmentScore,
            operation: .subtract
        )
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
