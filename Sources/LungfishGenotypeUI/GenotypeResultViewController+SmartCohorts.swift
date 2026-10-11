import AppKit
import Foundation
import LungfishIO
import LungfishKit

extension GenotypeResultViewController {
    func observeSmartCohortRestoreRequests() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSmartCohortsRestoreRequested(_:)),
            name: .genotypeResultSmartCohortsRestoreRequested,
            object: nil
        )
    }

    /// Restore Built-In Cohorts from the Inspector brings back the built-in
    /// cohorts the bundle lacks and empties their dismissals, as one recorded
    /// edit (plan decision S13).
    @objc func handleSmartCohortsRestoreRequested(_ notification: Notification) {
        guard ScopedEventFilter.accept(notification, for: windowEventScope) else { return }
        guard hasHaplotypingResult, let store = annotationStore else { return }
        do {
            try store.restoreBuiltInSmartCohorts(author: annotationAuthorProvider())
            refreshVisibleFilterDependentViews(rebuildCohortSummary: true)
            onAnnotationSidecarChanged?(store.sidecar)
        } catch {
            presentSheetAlert(error: error)
        }
    }
}
