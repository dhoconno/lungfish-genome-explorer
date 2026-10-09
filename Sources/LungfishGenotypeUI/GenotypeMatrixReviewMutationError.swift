import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

public enum GenotypeMatrixReviewMutationError: Error, Equatable, LocalizedError {
    case readOnly
    case emptyTargets
    case invalidReviewTargets
    case ineligibleEvidence
    case emptyCommentBody

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This bundle is read-only."
        case .emptyTargets:
            return "Select one or more matrix targets."
        case .invalidReviewTargets:
            return "Review classifications are available only for genotype cells."
        case .ineligibleEvidence:
            return "Every selected cell must satisfy the requested review classification's evidence rule."
        case .emptyCommentBody:
            return "A matrix comment cannot be empty."
        }
    }
}
