import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContextMenuSubmenuState: Equatable {
    enum Kind: Equatable {
        case rowVisibility
        case columnVisibility
    }

    let kind: Kind
    let title: String
    let items: [GenotypeMatrixContextMenuItemState]
}
