import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCUnmatchedClosestMatchWorkbookRow: Sendable, Codable, Equatable {
    let sample: String
    let cluster: String
    let clusterReads: Int
    let rawSequence: String
    let sequence: String
    let candidateSequence: String
    let candidateWasReverseComplemented: Bool
    let trimStart: Int?
    let trimEnd: Int?
    let trimSource: String
    let closestMatch: FullLengthONTMHCClosestMatch?
    let rescueMatch: FullLengthONTMHCBlastRescueMatch?

    private enum CodingKeys: String, CodingKey {
        case sample = "sample_id"
        case cluster = "source_cluster_id"
        case clusterReads = "cluster_read_count"
        case rawSequence = "raw_sequence"
        case sequence = "display_sequence"
        case candidateSequence = "candidate_sequence"
        case candidateWasReverseComplemented = "candidate_was_reverse_complemented"
        case trimStart = "trim_start"
        case trimEnd = "trim_end"
        case trimSource = "trim_source"
        case closestMatch = "closest_match"
        case rescueMatch = "rescue_match"
    }

    var rawLength: Int {
        rawSequence.count
    }

    var trimmedLength: Int {
        sequence.count
    }

    init(
        sample: String,
        cluster: String,
        clusterReads: Int,
        sequence: String,
        rawSequence: String? = nil,
        candidateSequence: String? = nil,
        candidateWasReverseComplemented: Bool? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil,
        trimSource: String = "provided-sequence",
        closestMatch: FullLengthONTMHCClosestMatch?,
        rescueMatch: FullLengthONTMHCBlastRescueMatch? = nil
    ) {
        self.sample = sample
        self.cluster = cluster
        self.clusterReads = clusterReads
        self.rawSequence = rawSequence ?? sequence
        self.sequence = sequence
        self.candidateSequence = candidateSequence ?? rawSequence ?? sequence
        self.candidateWasReverseComplemented = candidateWasReverseComplemented
            ?? (closestMatch?.isReverse == true)
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.trimSource = trimSource
        self.closestMatch = closestMatch
        self.rescueMatch = rescueMatch
    }
}
