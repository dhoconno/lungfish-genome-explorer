import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum CallOverrideMutationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case readOnly
    case emptyMutations
    case emptyAuthor
    case emptyTarget
    case mixedSamples
    case duplicateTarget(GenotypeEffectiveHaplotypeKey)
    case baselineMismatch(
        target: GenotypeEffectiveHaplotypeKey,
        expected: String,
        actual: String
    )
    case identityRequiredForClear(GenotypeEffectiveHaplotypeKey)
    case missingPriorSidecar

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            "This bundle is read-only."
        case .emptyMutations:
            "A call override Save must contain at least one target."
        case .emptyAuthor:
            "A call override author must not be empty."
        case .emptyTarget:
            "Call override sample, locus, baseline, and after values must not be empty."
        case .mixedSamples:
            "One call override Save may change only one sample."
        case .duplicateTarget(let target):
            "Call override target \(target.sample), \(target.locus), \(target.slot.rawValue) appears more than once."
        case let .baselineMismatch(target, expected, actual):
            "Call override baseline changed for \(target.sample), \(target.locus), \(target.slot.rawValue): expected \(expected), found \(actual)."
        case .identityRequiredForClear(let target):
            "Restoring \(target.sample), \(target.locus), \(target.slot.rawValue) requires the active analysis identity."
        case .missingPriorSidecar:
            "Call overrides require an existing annotation sidecar before they can be saved."
        }
    }
}
