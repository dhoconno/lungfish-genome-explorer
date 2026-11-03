// AssemblyResultViewController+ResultOnDisk.swift - The viewer stops when its contigs file is not the one it opened
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REPLACED (ruling BIO-ASSEMBLY-REPLACED, Fix A). This viewer holds no bases. The table and the catalog's
// offsets describe the contigs file as it was when the result loaded, while `extract contigs` and the catalog's reader open
// the path again on every call. After a Finder Replace, a sync or a CLI rerun they can disagree with the rows on screen, so the
// stamp of the file is checked before an action and again after the read, and a change stops the action with words.

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// The cause shown in the details when the contigs file changed (ruling BIO-ASSEMBLY-REPLACED).
struct AssemblyContigsChangedOnDisk: LocalizedError {
    var errorDescription: String? {
        "The size, modification time or file number of the contigs file differs from when this assembly opened."
    }
}

extension AssemblyResultViewController {
    /// The contigs file as it is now. The file manager is asked each time, since a held `URL` can keep cached resource
    /// values. The file number makes a same-size replace within a second show. A file that is not there reads as missing.
    static func contigsStamp(of result: AssemblyResult) -> [String] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.contigsPath.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let values: [Any?] = [attributes?[.size], modified, attributes?[.systemFileNumber]]
        return values.map { value in value.map { "\($0)" } ?? "missing" }
    }

    /// Whether the contigs file is no longer the one this view loaded its rows from. A view that holds nothing yet, one whose
    /// load failed and one with no contigs have no file to differ from, so they never read as changed.
    var contigsFileDiffersFromTheOneOpened: Bool {
        guard let result = currentResult, let held = heldContigsStamp else { return false }
        return held != Self.contigsStamp(of: result)
    }

    /// Whether the contigs file is the one this view opened. The table holds that file's rows and the catalog its offsets,
    /// while `extract contigs` reads what is there now, so after a replace no action can promise the contig on screen.
    /// When it is not, the person reads why and the caller stops.
    func contigsAreTheOnesOpened() -> Bool {
        guard contigsFileDiffersFromTheOneOpened else { return true }
        NSSound.beep()
        presentFailure(AssemblyFailureReports.resultChangedOnDisk())
        return false
    }

    /// Puts words in the pane in place of bases when the contigs file changed, and says whether it did. The pane gets words
    /// and no alert, so stepping through rows does not stack alerts.
    func paneStopsForAChangedContigsFile(selectedContigCount: Int) -> Bool {
        guard contigsFileDiffersFromTheOneOpened else { return false }
        detailPane.showUnavailableSelectionSummary(
            selectedContigCount: selectedContigCount,
            fastaPreview: "The contigs file changed on disk after this assembly opened, so no sequence is shown. Select another item in the sidebar, then select this assembly again."
        )
        setDetailPaneVisible(true)
        applyLayoutPreference()
        return true
    }

    /// What the pane shows in place of bases when a contig could not be read although the contigs file did not change.
    static let sequenceNotReadWords = "Lungfish could not read the sequence of this contig from the contigs file. Select another item in the sidebar, then select this assembly again."

    /// The first lines of a many-contig preview when some of the selected contigs could not be read. Empty when all were.
    static func unreadNote(selected: Int, read: Int) -> String {
        guard read < selected else { return "" }
        return "\(selected - read) of the \(selected) selected contigs could not be read from the contigs file, so their sequences are not shown.\n\n"
    }

    /// Shows a failure report, or hands it to the test seam (ALERT-PRESENTER, Phase 3.1).
    func presentFailure(_ report: FailureReport) {
        if let failurePresenter {
            failurePresenter(report)
            return
        }
        FailurePresenter.present(report, in: view.window)
    }

    func presentWarning(title: String, message: String) {
        if let warningPresenter {
            warningPresenter(title, message)
            return
        }

        // Leaf modules use the system default alert icon (the running app icon),
        // matching the LungfishTwelveSUI leaf precedent. App-internal branding
        // helpers stay in LungfishApp.
        WarningPresenter.present(title: title, message: message, in: view.window)
    }
}
