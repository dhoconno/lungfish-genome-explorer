import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCUnmatchedSequenceNormalizer {
    static func workbookRow(
        sample: String,
        record: FullLengthONTMHCClusterFASTARecord,
        closestMatch: FullLengthONTMHCClosestMatch?,
        rescueMatch: FullLengthONTMHCBlastRescueMatch? = nil
    ) -> FullLengthONTMHCUnmatchedClosestMatchWorkbookRow {
        let raw = record.sequence.uppercased()
        guard let closestMatch,
              let trimStart = closestMatch.trimStart,
              let trimEnd = closestMatch.trimEnd else {
            return FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
                sample: sample,
                cluster: record.name,
                clusterReads: record.readCount,
                sequence: raw,
                rawSequence: raw,
                trimStart: nil,
                trimEnd: nil,
                trimSource: "none-no-minimap-hit",
                closestMatch: closestMatch,
                rescueMatch: rescueMatch
            )
        }
        let start = max(1, min(trimStart, trimEnd))
        let end = min(raw.count, max(trimStart, trimEnd))
        var normalized = start <= end ? substring(raw, oneBasedClosedStart: start, oneBasedClosedEnd: end) : raw
        var candidateSequence = raw
        var trimSource = "minimap2-target-interval"
        if closestMatch.isReverse == true {
            normalized = reverseComplement(normalized)
            candidateSequence = reverseComplement(raw)
            trimSource = "minimap2-target-interval-reverse-complement"
        }
        return FullLengthONTMHCUnmatchedClosestMatchWorkbookRow(
            sample: sample,
            cluster: record.name,
            clusterReads: record.readCount,
            sequence: normalized,
            rawSequence: raw,
            candidateSequence: candidateSequence,
            trimStart: start,
            trimEnd: end,
            trimSource: trimSource,
            closestMatch: closestMatch,
            rescueMatch: rescueMatch
        )
    }

    private static func substring(
        _ sequence: String,
        oneBasedClosedStart start: Int,
        oneBasedClosedEnd end: Int
    ) -> String {
        let startIndex = sequence.index(sequence.startIndex, offsetBy: start - 1)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: end)
        return String(sequence[startIndex..<endIndex])
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complemented = sequence.reversed().map { base -> Character in
            switch base {
            case "A", "a": return "T"
            case "C", "c": return "G"
            case "G", "g": return "C"
            case "T", "t": return "A"
            default: return "N"
            }
        }
        return String(complemented).uppercased()
    }
}
