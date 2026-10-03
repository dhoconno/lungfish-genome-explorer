import Darwin
import CryptoKit
import Foundation
import LungfishIO

public enum GenotypeReviewableRowCatalogPublisherError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidRosterSample(String)
    case duplicateRosterSample(String)
    case invalidInputDescriptor(String)
    case invalidCandidate(String)
    case duplicateReferenceSequenceID(String)
    case duplicateCandidateStableID(String)
    case sampleOutsideRoster(String)
    case duplicateCall(locus: String, genotype: String)
    case duplicateCallSample(locus: String, genotype: String, sample: String)
    case invalidSupport(sample: String, value: Int)
    case callWithoutAuthoritativeRow(locus: String, genotype: String)
    case candidateSupportMismatch(locus: String, genotype: String, sample: String)
    case outputOutsideBundle(String)
    case finalArtifactMismatch(String)
    case authorityChanged(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRosterSample(sample):
            return "The authoritative genotype roster contains invalid sample '\(sample)'."
        case let .duplicateRosterSample(sample):
            return "The authoritative genotype roster contains duplicate sample '\(sample)'."
        case let .invalidInputDescriptor(path):
            return "The genotype review-row authority descriptor is incomplete: \(path)."
        case let .invalidCandidate(stableID):
            return "The genotype review-row candidate is invalid: \(stableID)."
        case let .duplicateReferenceSequenceID(sequenceID):
            return "Duplicate exact-run reference sequence ID: \(sequenceID)."
        case let .duplicateCandidateStableID(stableID):
            return "Duplicate genotype review-row candidate stable ID: \(stableID)."
        case let .sampleOutsideRoster(sample):
            return "Genotype review-row evidence contains sample outside the authoritative roster: \(sample)."
        case let .duplicateCall(locus, genotype):
            return "Duplicate authoritative genotype call: \(locus), \(genotype)."
        case let .duplicateCallSample(locus, genotype, sample):
            return "Duplicate authoritative genotype call evidence: \(locus), \(genotype), \(sample)."
        case let .invalidSupport(sample, value):
            return "Genotype review-row evidence for \(sample) is invalid: \(value)."
        case let .callWithoutAuthoritativeRow(locus, genotype):
            return "Genotype call has no authoritative reference or candidate row: \(locus), \(genotype)."
        case let .candidateSupportMismatch(locus, genotype, sample):
            return "Candidate observation and call evidence disagree: \(locus), \(genotype), \(sample)."
        case let .outputOutsideBundle(path):
            return "The genotype reviewable-row catalog output is outside the result bundle: \(path)."
        case let .finalArtifactMismatch(path):
            return "The published genotype reviewable-row catalog does not match its staged payload: \(path)."
        case let .authorityChanged(path):
            return "The genotype review-row authority changed while it was being read: \(path)."
        }
    }
}
