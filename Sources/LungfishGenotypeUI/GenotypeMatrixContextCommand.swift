import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

enum GenotypeMatrixContextCommand: Int, CaseIterable, Equatable {
    case hideSelectedRows
    case showOnlySelectedRows
    case hideSelectedColumns
    case showOnlySelectedColumns
    case showOnlyColumnsWithSelectedRowCalls
    case resetVisibility
    case markFalsePositive
    case markFalseNegative
    case clearReview
    case editComment
    case removeComments
    case selectSupportedCells
    case editManualHaplotypeAssignments

    var isSelectionTargetedVisibilityCommand: Bool {
        switch self {
        case .hideSelectedRows, .showOnlySelectedRows,
             .hideSelectedColumns, .showOnlySelectedColumns,
             .showOnlyColumnsWithSelectedRowCalls:
            true
        case .resetVisibility, .markFalsePositive, .markFalseNegative, .clearReview,
             .editComment, .removeComments, .selectSupportedCells,
             .editManualHaplotypeAssignments:
            false
        }
    }
}
