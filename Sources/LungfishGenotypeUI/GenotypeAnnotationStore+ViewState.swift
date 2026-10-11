import Foundation
import LungfishIO

/// The view the analyst chose for the bundle is app state (plan decision
/// S11). It lives in `GenotypeResultViewState.filename`, a hidden file that
/// no directory digest and no record covers. A view switch writes only that
/// file and never `annotations.json`, its record or the publication lock.
extension GenotypeAnnotationStore {
    /// The view the bundle opens with, its app state file when it has one and
    /// otherwise the view fields of its sidecar. Reading never writes, so an
    /// older sidecar's fields become the starting view and stay as they are.
    var startingViewState: GenotypeResultViewState {
        GenotypeResultViewState.starting(forBundleAt: bundleURL, sidecarSettings: sidecar.settings)
    }

    /// Saves a view the analyst chose. Only a user event calls this, never
    /// opening a bundle and never a programmatic restore. A read-only bundle
    /// keeps the choice for the session only, and a choice equal to the saved
    /// view writes nothing. A failed write loses a preference and never data,
    /// so it raises no alert.
    ///
    /// - Returns: Whether the app state file was written.
    @discardableResult
    func recordUserViewChange(_ change: (inout GenotypeResultViewState) -> Void) -> Bool {
        guard !isReadOnly else { return false }
        let saved = startingViewState
        var next = saved
        change(&next)
        guard next != saved else { return false }
        do {
            try next.save(toBundleAt: bundleURL)
            return true
        } catch {
            return false
        }
    }
}
