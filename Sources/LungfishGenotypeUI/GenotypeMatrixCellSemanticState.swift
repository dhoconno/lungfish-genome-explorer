import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixCellSemanticState: Equatable {
    let text: GenotypeMatrixSemanticTextPresentation
    let evidenceReads: Int?
    let review: GenotypeAnnotationSidecar.MatrixReviewDisposition?
    let chrome: GenotypeMatrixCellChromeState
    let commentCounts: GenotypeMatrixScopedCommentCounts
    let hasNativeCellCommentMarker: Bool
    let isSelected: Bool
    let accessibilityLabel: String
}
