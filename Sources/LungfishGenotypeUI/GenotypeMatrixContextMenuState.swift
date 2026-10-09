import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContextMenuState: Equatable {
    let selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    let visibilityItems: [GenotypeMatrixContextMenuItemState]
    let visibilitySubmenus: [GenotypeMatrixContextMenuSubmenuState]
    let items: [GenotypeMatrixContextMenuItemState]
    let inspectedTargetCount: Int
}
