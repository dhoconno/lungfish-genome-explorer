// CDSSegmentPhases.swift - Shared GFF3 phase computation for multi-segment CDS features.
//
// A CDS made of several segments (exons, or the two halves of a -1 ribosomal
// frameshift such as SARS-CoV-2 ORF1ab) needs a GFF3 "phase" column per
// segment: the number of bases of the segment that must be removed from its
// start to reach the first base of the next complete codon. Phase is defined
// in transcription order, which is ascending genomic order for a `+` strand
// feature and descending genomic order for a `-` strand feature (GFF3 spec
// §CDS phase). Getting this wrong changes which reading frame downstream
// tools such as `ivar variants -g` use to translate variants into amino-acid
// consequences.

import Foundation

/// Computes GFF3 CDS phase for each segment of a (possibly multi-segment) CDS.
public enum CDSSegmentPhases {
    /// One CDS segment, in 0-based half-open genomic coordinates.
    public struct Interval: Sendable, Equatable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }

        public var length: Int { end - start }
    }

    /// Computes the GFF3 phase (0, 1, or 2) for each interval.
    ///
    /// - Parameters:
    ///   - intervals: CDS segments in 0-based half-open genomic coordinates,
    ///     in any order. They do not need to be pre-sorted.
    ///   - strand: `"+"` or `"-"`. Any other value is treated as `"+"`.
    /// - Returns: Pairs of `(interval, phase)`, sorted into genomic order
    ///   (ascending `start`), matching the order GFF3 output lines expect.
    ///
    /// Phase is computed from the cumulative length of segments already
    /// consumed, in transcription order. For a `+` strand feature,
    /// transcription order is ascending genomic order, so the first segment
    /// (lowest start) is always phase 0. For a `-` strand feature,
    /// transcription order is descending genomic order, so the segment with
    /// the highest start is phase 0.
    ///
    /// Phase of a segment = `(3 - (cumulativeLengthBeforeSegment % 3)) % 3`,
    /// the standard GFF3 definition (bases to skip from the segment's 5' end,
    /// in transcription direction, before the next codon starts).
    public static func compute(intervals: [Interval], strand: String) -> [(interval: Interval, phase: Int)] {
        guard !intervals.isEmpty else { return [] }

        let ascending = intervals.sorted { $0.start < $1.start }
        let transcriptionOrder = strand == "-" ? ascending.reversed().map { $0 } : ascending

        var cumulative = 0
        var phaseByStart: [Int: Int] = [:]
        for segment in transcriptionOrder {
            let phase = (3 - (cumulative % 3)) % 3
            phaseByStart[segment.start] = phase
            cumulative += segment.length
        }

        return ascending.map { ($0, phaseByStart[$0.start] ?? 0) }
    }
}
