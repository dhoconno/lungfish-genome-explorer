import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
protocol GenotypeMatrixContextMenuSnapshotProviding: AnyObject {
    var cachedSnapshot: GenotypeMatrixContextMenuSnapshot { get }
}
