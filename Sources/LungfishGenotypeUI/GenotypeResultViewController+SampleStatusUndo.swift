// GenotypeResultViewController+SampleStatusUndo.swift - Undo and Redo for the sample status commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// Undo and Redo for Mark Sample Reviewed, Mark Sample Confirmed and Flag
/// Sample for Review (ruling U15).
extension GenotypeResultViewController {
    /// The Undo and Redo names of the sample status commands, equal to their
    /// menu titles.
    static let sampleStatusUndoActionNames: [GenotypeAnnotationSidecar.StatusValue: String] = [
        .reviewed: "Mark Sample Reviewed",
        .confirmed: "Mark Sample Confirmed",
        .needsReview: "Flag Sample for Review",
    ]

    /// Writes a sample status in the bundle at `bundleURL`, or clears it when
    /// `value` is nil, and registers the reverse write with the window's undo
    /// manager when the status changed. Undo and Redo come back through this
    /// method, so each one registers the other under the command's name.
    ///
    /// The bundle on screen is written through its own store and then gets the
    /// same refresh the command runs. An Undo for a bundle the viewer no longer
    /// shows opens that bundle's annotations and writes them there.
    func writeSampleStatus(
        _ value: GenotypeAnnotationSidecar.StatusValue?,
        sample: String,
        bundleURL: URL,
        actionName: String? = nil
    ) {
        let name = actionName
            ?? value.flatMap { Self.sampleStatusUndoActionNames[$0] }
            ?? "Change Sample Status"
        let shownStore = annotationStore.flatMap {
            $0.bundleURL.standardizedFileURL.path == bundleURL.standardizedFileURL.path ? $0 : nil
        }
        let author = annotationAuthorProvider()
        let store: GenotypeAnnotationStore
        do {
            store = try shownStore ?? GenotypeAnnotationStore(
                bundleURL: bundleURL,
                author: author,
                seedBuiltInSmartCohorts: false
            )
        } catch {
            presentSheetAlert(GenotypeFailureReports.openAnnotationsForSampleStatus(error))
            return
        }
        // The Undo registers in the command's own event, before the edit awaits, so Undo and Redo
        // land on the right stack, and a refused edit takes its Undo back (N3). The edit publishes
        // away from the main actor and the refresh follows it (2.11 S35).
        let previous = store.sidecar.sampleStatusFlags.first { $0.sample == sample }?.value
        let undoManager = previous != value ? view.window?.undoManager : nil
        let undoToken = SampleStatusUndoToken()
        undoManager?.registerUndo(withTarget: undoToken) { [weak self, undoToken] _ in
            withExtendedLifetime(undoToken) {
                self?.writeSampleStatus(previous, sample: sample, bundleURL: bundleURL, actionName: name)
            }
        }
        undoManager?.setActionName(name)
        store.beginEdit { [self] in
            if let value {
                try await store.setSampleStatus(value, sample: sample, author: author)
            } else {
                try await store.clearSampleStatus(sample: sample, author: author)
            }
            if shownStore != nil {
                refreshAfterSampleStatusChange()
            }
        } onFailure: { [self] error in
            undoManager?.removeAllActions(withTarget: undoToken)
            presentSheetAlert(GenotypeFailureReports.changeSampleStatus(error))
            if shownStore != nil {
                refreshAfterSampleStatusChange()
            }
        }
    }
}

/// The target of one sample status Undo, so a refused edit removes its own Undo and no other.
private final class SampleStatusUndoToken {}
