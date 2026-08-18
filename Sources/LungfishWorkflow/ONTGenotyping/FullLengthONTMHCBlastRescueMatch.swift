import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCBlastRescueMatch: Sendable, Codable, Equatable {
    static let minimumQueryCoverage = 70.0
    static let minimumAlignedBases = 1_000
    static let minimumPercentIdentity = 75.0
    static let maximumEValue = 1e-20

    let sample: String
    let cluster: String
    let clusterReads: Int
    let closestReference: String
    let percentIdentity: Double
    let queryCoverage: Double
    let alignedBases: Int
    let mismatches: Int
    let gapOpens: Int
    let eValue: Double
    let bitScore: Double
    let closestMatchID: String
}

enum FullLengthONTMHCBlastRescueParseError: Error, Equatable {
    case fieldCountMismatch(expected: Int, actual: Int)
}

enum FullLengthONTMHCBlastRescueParser {
    /// The `-outfmt 6` field list the blast-rescue pipeline requests from
    /// `blastn`, in order. Single-sourced here so the pipeline's actual
    /// invocation and any conformance test asserting against real `blastn`
    /// output can never drift apart.
    static let outfmt6Fields: [String] = [
        "qseqid",
        "sseqid",
        "pident",
        "length",
        "mismatch",
        "gapopen",
        "qstart",
        "qend",
        "sstart",
        "send",
        "evalue",
        "bitscore",
        "qlen",
        "slen",
    ]

    /// Parses a single `-outfmt 6` line into the fields declared by
    /// ``outfmt6Fields``, without any of the acceptance-threshold or
    /// cluster-lookup logic `acceptedMatches` applies. Exists so callers
    /// (and conformance tests against real `blastn` output) can validate
    /// that a line matches the declared field contract.
    static func parseLine(_ line: String) throws -> [String: String] {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == outfmt6Fields.count else {
            throw FullLengthONTMHCBlastRescueParseError.fieldCountMismatch(
                expected: outfmt6Fields.count,
                actual: fields.count
            )
        }
        return Dictionary(uniqueKeysWithValues: zip(outfmt6Fields, fields))
    }

    static func acceptedMatches(
        sample: String,
        recordsByCluster: [String: FullLengthONTMHCClusterFASTARecord],
        tsv: String
    ) throws -> [FullLengthONTMHCBlastRescueMatch] {
        let candidates = tsv
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> FullLengthONTMHCBlastRescueMatch? in
                parseLine(String(line), sample: sample, recordsByCluster: recordsByCluster)
            }
            .filter(passesThresholds)
        let grouped = Dictionary(grouping: candidates, by: \.cluster)
        return grouped.values.compactMap { group in
            group.sorted(by: rescueSort).first
        }
        .sorted {
            if $0.sample != $1.sample {
                return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
            }
            return $0.cluster.localizedStandardCompare($1.cluster) == .orderedAscending
        }
    }

    private static func parseLine(
        _ line: String,
        sample: String,
        recordsByCluster: [String: FullLengthONTMHCClusterFASTARecord]
    ) -> FullLengthONTMHCBlastRescueMatch? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 14,
              let record = recordsByCluster[fields[0]],
              let percentIdentity = Double(fields[2]),
              let alignedBases = Int(fields[3]),
              let mismatches = Int(fields[4]),
              let gapOpens = Int(fields[5]),
              let eValue = Double(fields[10]),
              let bitScore = Double(fields[11]),
              let queryLength = Double(fields[12]),
              queryLength > 0
        else {
            return nil
        }
        let queryCoverage = Double(alignedBases) / queryLength * 100.0
        let closestReference = fields[1]
        return FullLengthONTMHCBlastRescueMatch(
            sample: sample,
            cluster: record.name,
            clusterReads: record.readCount,
            closestReference: closestReference,
            percentIdentity: percentIdentity,
            queryCoverage: queryCoverage,
            alignedBases: alignedBases,
            mismatches: mismatches,
            gapOpens: gapOpens,
            eValue: eValue,
            bitScore: bitScore,
            closestMatchID: "\(closestReference)_blast-rescue"
        )
    }

    private static func passesThresholds(_ match: FullLengthONTMHCBlastRescueMatch) -> Bool {
        match.queryCoverage >= FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage
            && match.alignedBases >= FullLengthONTMHCBlastRescueMatch.minimumAlignedBases
            && match.percentIdentity >= FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity
            && match.eValue <= FullLengthONTMHCBlastRescueMatch.maximumEValue
    }

    static func rescueSort(
        _ lhs: FullLengthONTMHCBlastRescueMatch,
        _ rhs: FullLengthONTMHCBlastRescueMatch
    ) -> Bool {
        if lhs.eValue != rhs.eValue { return lhs.eValue < rhs.eValue }
        if lhs.bitScore != rhs.bitScore { return lhs.bitScore > rhs.bitScore }
        if lhs.queryCoverage != rhs.queryCoverage { return lhs.queryCoverage > rhs.queryCoverage }
        if lhs.percentIdentity != rhs.percentIdentity { return lhs.percentIdentity > rhs.percentIdentity }
        if lhs.alignedBases != rhs.alignedBases { return lhs.alignedBases > rhs.alignedBases }
        return lhs.closestReference.localizedStandardCompare(rhs.closestReference) == .orderedAscending
    }
}
