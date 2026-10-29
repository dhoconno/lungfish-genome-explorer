import AppKit
import Foundation
import LungfishIO
import LungfishKit

extension GenotypeResultViewController {
    /// One state, `activeSmartCohort`, drives both places that show the active
    /// cohort (walk star 10). The quick filter bar pill names it with a clear
    /// glyph, and `onActiveSmartCohortChanged` hands it to the Inspector, whose
    /// Smart Cohorts section marks its row with a checkmark.
    func activeSmartCohortDidChange(from previous: GenotypeCohortSmartFilter?) {
        quickFilterBar.setSavedCohortName(activeSmartCohort?.name)
        guard previous != activeSmartCohort else { return }
        onActiveSmartCohortChanged?(activeSmartCohort)
    }

    /// A click on a cohort makes it active, and a second click on the active
    /// cohort, matched by name and scope as the Inspector rows are, clears it.
    static func toggledSmartCohort(
        current: GenotypeCohortSmartFilter?,
        selected: GenotypeCohortSmartFilter
    ) -> GenotypeCohortSmartFilter? {
        guard let current, current.name == selected.name, current.scope == selected.scope else { return selected }
        return nil
    }

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
        store.beginEdit { [self] in
            try await store.restoreBuiltInSmartCohorts(author: annotationAuthorProvider())
            refreshVisibleFilterDependentViews(rebuildCohortSummary: true)
            onAnnotationSidecarChanged?(store.sidecar)
        } onFailure: { [self] error in
            presentSheetAlert(GenotypeFailureReports.restoreBuiltInCohorts(error))
        }
    }
}
