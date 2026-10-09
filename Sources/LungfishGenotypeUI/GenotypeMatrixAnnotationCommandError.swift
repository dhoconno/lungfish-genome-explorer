import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeMatrixAnnotationCommandError: Error, Equatable, LocalizedError {
    case explicitBulkCommentReplaceRequired

    public var errorDescription: String? {
        switch self {
        case .explicitBulkCommentReplaceRequired:
            return "Replacing existing comments on multiple targets requires explicit replace intent."
        }
    }
}
