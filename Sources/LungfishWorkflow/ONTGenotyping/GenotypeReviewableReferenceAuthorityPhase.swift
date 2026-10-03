import Foundation
import Darwin
import LungfishCore
import LungfishIO

enum GenotypeReviewableReferenceAuthorityPhase: Equatable, Sendable {
    case afterSnapshotBeforeSemanticLoad
    case beforeFinalVerification
}
