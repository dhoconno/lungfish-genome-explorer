import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public enum AIHaplotypingRevisionPublisherError: Error, LocalizedError, Sendable {
    case noAcceptedValidationReports
    case invalidSlot(String)
    case pendingProvenancePath(String)
    case incompleteSidecarRequest
    case noncanonicalSidecarURL(expected: String, actual: String)
    case sidecarSnapshotMismatch
    case rollbackFailed(originalError: String, rollbackError: String, orphanDirectory: String)

    public var errorDescription: String? {
        switch self {
        case .noAcceptedValidationReports:
            return "AI haplotyping output cannot be published because it has no accepted validation reports."
        case .invalidSlot(let slot):
            return "AI haplotyping output contains an invalid haplotype slot: \(slot)"
        case .pendingProvenancePath(let path):
            return "AI haplotyping output still points at a non-final provenance path: \(path)"
        case .incompleteSidecarRequest:
            return "AI haplotyping publication requires the annotation sidecar URL and decoded sidecar together."
        case .noncanonicalSidecarURL(let expected, let actual):
            return "AI haplotyping publication expected the annotation sidecar at \(expected), not \(actual)."
        case .sidecarSnapshotMismatch:
            return "The AI haplotyping request sidecar does not match the locked annotation sidecar snapshot."
        case .rollbackFailed(let originalError, let rollbackError, let orphanDirectory):
            return "AI haplotyping publish failed (\(originalError)) and rollback could not remove \(orphanDirectory): \(rollbackError)"
        }
    }
}
