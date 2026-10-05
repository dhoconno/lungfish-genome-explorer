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
        do {
            let author = annotationAuthorProvider()
            let store = try shownStore ?? GenotypeAnnotationStore(
                bundleURL: bundleURL,
                author: author,
                seedBuiltInSmartCohorts: false
            )
            let previous = store.sidecar.sampleStatusFlags.first { $0.sample == sample }?.value
            if let value {
                try store.setSampleStatus(value, sample: sample, author: author)
            } else {
                try store.clearSampleStatus(sample: sample, author: author)
            }
            if previous != value, let undoManager = view.window?.undoManager {
                undoManager.registerUndo(withTarget: self) { target in
                    target.writeSampleStatus(
                        previous,
                        sample: sample,
                        bundleURL: bundleURL,
                        actionName: name
                    )
                }
                undoManager.setActionName(name)
            }
        } catch {
            presentSheetAlert(error: error)
        }
        if shownStore != nil {
            refreshAfterSampleStatusChange()
        }
    }
}
