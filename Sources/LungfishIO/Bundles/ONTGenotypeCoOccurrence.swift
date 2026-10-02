import CryptoKit
import Darwin
import Foundation
import LungfishCore

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
