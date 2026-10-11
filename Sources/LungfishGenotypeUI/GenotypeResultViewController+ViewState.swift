import Foundation
import LungfishIO

extension GenotypeResultViewController {
    /// Saves the Haplotype Calls or Genotype Matrix choice as app state after
    /// a user event (plan decision S11). Only `applyDisplayState(_:)`, the
    /// entry point of the viewport's own control and of the Inspector, calls
    /// this. Opening a bundle sets the starting view directly, and every
    /// programmatic restore applies its state without passing here, so
    /// neither writes. The choice never reaches `annotations.json` or a
    /// record. A read-only bundle keeps it for the session, and the fallback
    /// matrix of a malformed analysis never replaces a saved choice.
    func recordSummaryViewChoice(from previous: GenotypeSummaryViewMode, to next: GenotypeSummaryViewMode) {
        guard previous != next,
              presentationPolicy?.persistencePolicy != .preserveStoredPreference,
              presentationPolicy?.persistencePolicy != .sessionOnly,
              let store = annotationStore else { return }
        store.recordUserViewChange { $0.preferredSummaryViewMode = next.rawValue }
    }
}
