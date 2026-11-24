// MainWindowController+FASTQDrawerKeep.swift - Closing a project window keeps the FASTQ drawer's waiting edit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension MainWindowController {
    /// FASTQ-DRAWER-EDIT-LOST-ON-QUIT, the close button and Cmd-W. No route clears the viewer on this way out (see
    /// `windowWillClose`), so an edit waiting in the FASTQ drawer is saved first, through Save's own path. When it
    /// cannot be written, the select route's sheet goes on this window and the close waits until the person has read
    /// it, so the words are seen. Then the window closes: the sheet offers no Cancel, as a close is not held for it.
    /// Returns whether the close may go on now.
    func keepFASTQDrawerEditBeforeClose(_ sender: NSWindow) -> Bool {
        guard let viewer = mainSplitViewController?.viewerController,
              let unkept = viewer.keepWaitingFASTQDrawerEditReportingFailure() else { return true }
        let alert = ViewerViewController.unkeptFASTQDrawerEditAlert(unkept)
        ViewerViewController.presentUnkeptFASTQDrawerEditBeforeClose(alert, sender) { [weak viewer, weak sender] in
            // The person has read that the edit was not saved, and the drawer goes with the window.
            viewer?.fastqMetadataDrawerView?.markSettingsKept()
            sender?.performClose(nil)
        }
        return false
    }
}
