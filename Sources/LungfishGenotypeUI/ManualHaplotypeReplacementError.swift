import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

public enum ManualHaplotypeReplacementError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case readOnly
    case emptySample
    case emptyAuthor
    case emptyCopySource
    case assignmentSampleMismatch(expected: String, actual: String)
    case invalidLocus(String)
    case invalidColorToken(Int)
    case duplicateKey(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    )
    case missingPriorSidecar

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This bundle is read-only."
        case .emptySample:
            return "A manual haplotype assignment sample must not be empty."
        case .emptyAuthor:
            return "A manual haplotype assignment author must not be empty."
        case .emptyCopySource:
            return "A copied manual haplotype assignment source sample must not be empty."
        case let .assignmentSampleMismatch(expected, actual):
            return "Manual haplotype assignment sample \(actual) does not match \(expected)."
        case .invalidLocus(let locus):
            return "Manual haplotype assignment locus \(locus) is not recognized."
        case .invalidColorToken(let index):
            return "Manual haplotype assignment color token \(index) is not in the canonical palette."
        case let .duplicateKey(sample, locus, slot):
            return "Manual haplotype assignment \(sample), \(locus.rawValue), \(slot.rawValue) appears more than once."
        case .missingPriorSidecar:
            return "Manual haplotype assignments require an existing annotation sidecar before they can be saved."
        }
    }
}
