import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContextMenuItemState: Equatable {
    let title: String
    let command: GenotypeMatrixContextCommand
    let availability: GenotypeMatrixCommandAvailability
    let keyEquivalent: String
    let keyModifierRawValue: UInt
}
