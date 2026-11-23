import Foundation
import LungfishIO

/// The view the analyst chose for the bundle is view memory, which the store outside every bundle and project keeps
/// (the revisit of plan decision S11, `GenotypeResultViewController+ViewMemory.swift`). No build writes app state
/// into a bundle. An older bundle's `GenotypeResultViewState.filename` is read once, off the main actor, as a starting
/// view while the item has no store entry and no retire mark, and nothing writes or deletes it. A view switch writes
/// no `annotations.json`, record or publication lock.
extension GenotypeAnnotationStore {
    /// The view the sidecar gives the bundle, read from memory with no file read on the main actor. An older
    /// sidecar's fields become the starting view and stay as they are.
    var startingViewState: GenotypeResultViewState {
        GenotypeResultViewState(startingFrom: sidecar.settings)
    }

    /// An older bundle's own view file, or nil when it has none or it cannot be read. It reads the disk, so only the
    /// open's read off the main actor calls it, and only for an item with no store entry and no retire mark.
    nonisolated static func olderViewState(inBundleAt bundleURL: URL) -> GenotypeResultViewState? {
        GenotypeResultViewState.load(fromBundleAt: bundleURL)
    }

    /// Writes nothing. A user's view change is view memory, which the viewer keeps in the store when the visit ends,
    /// so a read-only bundle and a writable one behave alike and no write runs past `isReadOnly` (VS U9).
    ///
    /// - Returns: Always false, since nothing is written.
    @discardableResult
    func recordUserViewChange(_ change: (inout GenotypeResultViewState) -> Void) -> Bool {
        false
    }
}
