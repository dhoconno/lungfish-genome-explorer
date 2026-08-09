import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder {
    static func detailRows(_ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) -> [[String]] {
        var result = [[
            "unmatched_sequence_id",
            "sample",
            "cluster",
            "cluster_reads",
            "raw_length",
            "trimmed_length",
            "trim_start",
            "trim_end",
            "trim_source",
            "closest_match_id",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
            "sequence",
        ]]
        result += rows.sorted(by: rowSort).map { row in
            let closest = row.closestMatch
            return [
                unmatchedSequenceID(for: row.sequence),
                row.sample,
                row.cluster,
                String(row.clusterReads),
                String(row.rawLength),
                String(row.trimmedLength),
                optionalNumber(row.trimStart),
                optionalNumber(row.trimEnd),
                row.trimSource,
                closest?.closestMatchID ?? "",
                closest?.matchClass.rawValue ?? "",
                optionalNumber(closest?.nucleotidesDifferent),
                optionalNumber(closest?.snpDifferences),
                optionalNumber(closest?.indelBases),
                optionalNumber(closest?.alignedBases),
                optionalNumber(closest?.score),
                row.sequence,
            ]
        }
        return result
    }

    static func pivotRows(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        sampleOrder: [String]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(sampleOrder, with: rows)
        var result = [[
            "unmatched_sequence_id",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
            "closest_match_id",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
        ] + sampleNames]
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.candidateSequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for unmatchedSequenceID in orderedGroups {
            guard let group = grouped[unmatchedSequenceID] else {
                continue
            }
            let metadata = group.compactMap(\.closestMatch).sorted(by: closestSort).first
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            let readsBySample = group.reduce(into: [String: Int]()) { totals, item in
                totals[item.sample, default: 0] += item.clusterReads
            }
            let sampleCount = readsBySample.values.filter { $0 > 0 }.count
            result.append([
                unmatchedSequenceID,
                String(group.count),
                String(sampleCount),
                String(totalReads),
                metadata?.closestMatchID ?? "",
                metadata?.matchClass.rawValue ?? "",
                optionalNumber(metadata?.nucleotidesDifferent),
                optionalNumber(metadata?.snpDifferences),
                optionalNumber(metadata?.indelBases),
                optionalNumber(metadata?.alignedBases),
                optionalNumber(metadata?.score),
            ] + sampleNames.map { sample in
                guard let count = readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }
        return result
    }

    static func mhcLikeDetailRows(_ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) -> [[String]] {
        var result = [[
            "unmatched_sequence_id",
            "sample",
            "cluster",
            "cluster_reads",
            "raw_length",
            "trimmed_length",
            "trim_start",
            "trim_end",
            "trim_source",
            "match_source",
            "closest_match_id",
            "closest_reference",
            "match_class",
            "nucleotides_different",
            "snp_differences",
            "indel_bases",
            "aligned_bases",
            "score",
            "percent_identity",
            "query_coverage",
            "evalue",
            "bitscore",
            "sequence",
        ]]
        result += rows.filter(isMHCLike).sorted(by: rowSort).map { row in
            let metadata = mhcLikeMetadata(for: row)
            return [
                unmatchedSequenceID(for: row.sequence),
                row.sample,
                row.cluster,
                String(row.clusterReads),
                String(row.rawLength),
                String(row.trimmedLength),
                optionalNumber(row.trimStart),
                optionalNumber(row.trimEnd),
                row.trimSource,
                metadata.matchSource,
                metadata.closestMatchID,
                metadata.closestReference,
                metadata.matchClass,
                metadata.nucleotidesDifferent,
                metadata.snpDifferences,
                metadata.indelBases,
                metadata.alignedBases,
                metadata.score,
                metadata.percentIdentity,
                metadata.queryCoverage,
                metadata.eValue,
                metadata.bitScore,
                row.sequence,
            ]
        }
        return result
    }

    static func mhcLikePivotRows(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow],
        sampleOrder: [String]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(sampleOrder, with: rows.filter(isMHCLike))
        var result = [[
            "unmatched_sequence_id",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
            "match_source",
            "closest_match_id",
            "closest_reference",
            "match_class",
            "nucleotides_different",
            "percent_identity",
            "query_coverage",
            "evalue",
            "bitscore",
        ] + sampleNames]
        let grouped = Dictionary(grouping: rows.filter(isMHCLike)) { unmatchedSequenceID(for: $0.sequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for unmatchedSequenceID in orderedGroups {
            guard let group = grouped[unmatchedSequenceID] else {
                continue
            }
            let representative = group.sorted(by: mhcLikeSort).first
            let metadata = representative.map(mhcLikeMetadata)
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            let readsBySample = group.reduce(into: [String: Int]()) { totals, item in
                totals[item.sample, default: 0] += item.clusterReads
            }
            let sampleCount = readsBySample.values.filter { $0 > 0 }.count
            result.append([
                unmatchedSequenceID,
                String(group.count),
                String(sampleCount),
                String(totalReads),
                metadata?.matchSource ?? "",
                metadata?.closestMatchID ?? "",
                metadata?.closestReference ?? "",
                metadata?.matchClass ?? "",
                metadata?.nucleotidesDifferent ?? "",
                metadata?.percentIdentity ?? "",
                metadata?.queryCoverage ?? "",
                metadata?.eValue ?? "",
                metadata?.bitScore ?? "",
            ] + sampleNames.map { sample in
                guard let count = readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }
        return result
    }

    static func deduplicatedFASTARecords(
        _ rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]
    ) -> [FullLengthONTMHCClusterFASTARecord] {
        let grouped = Dictionary(grouping: rows) { unmatchedSequenceID(for: $0.candidateSequence) }
        let orderedGroups = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftReads = left.reduce(0) { $0 + $1.clusterReads }
            let rightReads = right.reduce(0) { $0 + $1.clusterReads }
            if leftReads != rightReads { return leftReads > rightReads }
            if left.count != right.count { return left.count > right.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return orderedGroups.compactMap { sequenceID in
            guard let group = grouped[sequenceID],
                  let representative = group.sorted(by: rowSort).first else {
                return nil
            }
            let samples = Set(group.map(\.sample)).sorted(by: localizedStandardLessThan)
            let totalReads = group.reduce(0) { $0 + $1.clusterReads }
            return FullLengthONTMHCClusterFASTARecord(
                name: [
                    sequenceID,
                    "occurrences=\(group.count)",
                    "sample_count=\(samples.count)",
                    "samples=\(samples.joined(separator: ";"))",
                    "total_cluster_reads=\(totalReads)",
                ].joined(separator: "|"),
                sequence: representative.candidateSequence,
                readCount: totalReads
            )
        }
    }

    private static func completeSampleOrder(
        _ sampleOrder: [String],
        with rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sample in sampleOrder where seen.insert(sample).inserted {
            result.append(sample)
        }
        let missing = Set(rows.map(\.sample))
            .subtracting(seen)
            .sorted(by: localizedStandardLessThan)
        result.append(contentsOf: missing)
        return result
    }

    private static func rowSort(
        _ lhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow,
        _ rhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow
    ) -> Bool {
        if lhs.sample != rhs.sample {
            return lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
        }
        let leftID = lhs.closestMatch?.closestMatchID ?? ""
        let rightID = rhs.closestMatch?.closestMatchID ?? ""
        if leftID != rightID {
            return leftID.localizedStandardCompare(rightID) == .orderedAscending
        }
        return lhs.cluster.localizedStandardCompare(rhs.cluster) == .orderedAscending
    }

    private static func isMHCLike(_ row: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow) -> Bool {
        row.closestMatch != nil || row.rescueMatch != nil
    }

    private struct MHCLikeMetadata {
        let matchSource: String
        let closestMatchID: String
        let closestReference: String
        let matchClass: String
        let nucleotidesDifferent: String
        let snpDifferences: String
        let indelBases: String
        let alignedBases: String
        let score: String
        let percentIdentity: String
        let queryCoverage: String
        let eValue: String
        let bitScore: String
    }

    private static func mhcLikeMetadata(for row: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow) -> MHCLikeMetadata {
        if let closest = row.closestMatch {
            return MHCLikeMetadata(
                matchSource: "genotyping-sam",
                closestMatchID: closest.closestMatchID,
                closestReference: closest.closestReference,
                matchClass: closest.matchClass.rawValue,
                nucleotidesDifferent: optionalNumber(closest.nucleotidesDifferent),
                snpDifferences: optionalNumber(closest.snpDifferences),
                indelBases: optionalNumber(closest.indelBases),
                alignedBases: optionalNumber(closest.alignedBases),
                score: optionalNumber(closest.score),
                percentIdentity: "",
                queryCoverage: "",
                eValue: "",
                bitScore: ""
            )
        }
        guard let rescue = row.rescueMatch else {
            return MHCLikeMetadata(
                matchSource: "",
                closestMatchID: "",
                closestReference: "",
                matchClass: "",
                nucleotidesDifferent: "",
                snpDifferences: "",
                indelBases: "",
                alignedBases: "",
                score: "",
                percentIdentity: "",
                queryCoverage: "",
                eValue: "",
                bitScore: ""
            )
        }
        return MHCLikeMetadata(
            matchSource: "local-blast-rescue",
            closestMatchID: rescue.closestMatchID,
            closestReference: rescue.closestReference,
            matchClass: "blast-rescue",
            nucleotidesDifferent: "",
            snpDifferences: "",
            indelBases: "",
            alignedBases: optionalNumber(rescue.alignedBases),
            score: "",
            percentIdentity: formatNumber(rescue.percentIdentity),
            queryCoverage: formatNumber(rescue.queryCoverage),
            eValue: formatNumber(rescue.eValue),
            bitScore: formatNumber(rescue.bitScore)
        )
    }

    private static func mhcLikeSort(
        _ lhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow,
        _ rhs: FullLengthONTMHCUnmatchedClosestMatchWorkbookRow
    ) -> Bool {
        if lhs.closestMatch != nil && rhs.closestMatch == nil { return true }
        if lhs.closestMatch == nil && rhs.closestMatch != nil { return false }
        if let left = lhs.closestMatch, let right = rhs.closestMatch {
            return closestSort(left, right)
        }
        if let left = lhs.rescueMatch, let right = rhs.rescueMatch {
            return FullLengthONTMHCBlastRescueParser.rescueSort(left, right)
        }
        return lhs.cluster.localizedStandardCompare(rhs.cluster) == .orderedAscending
    }

    private static func closestSort(
        _ lhs: FullLengthONTMHCClosestMatch,
        _ rhs: FullLengthONTMHCClosestMatch
    ) -> Bool {
        if lhs.closestMatchID != rhs.closestMatchID {
            return lhs.closestMatchID.localizedStandardCompare(rhs.closestMatchID) == .orderedAscending
        }
        if lhs.closestReference != rhs.closestReference {
            return lhs.closestReference.localizedStandardCompare(rhs.closestReference) == .orderedAscending
        }
        return lhs.matchClass.rawValue.localizedStandardCompare(rhs.matchClass.rawValue) == .orderedAscending
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func optionalNumber(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.3f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    static func unmatchedSequenceID(for sequence: String) -> String {
        let normalized = sequence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        var bytes = Array(SHA256.hash(data: Data(normalized.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
