import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
final class GenotypeMatrixImmutableContextMenuSnapshotSource:
    GenotypeMatrixContextMenuSnapshotProviding {
    let cachedSnapshot: GenotypeMatrixContextMenuSnapshot

    init(snapshot: GenotypeMatrixContextMenuSnapshot) {
        cachedSnapshot = snapshot
    }
}
