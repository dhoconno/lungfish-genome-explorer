// GenotypeEditQuitConfirmation.swift - The Quit sheet for a genotype comment or review that is still unsaved (Phase 3.2 lane QUITEDIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishGenotypeUI

/// What Quit does when its wait for the genotype annotation edits ends and an edit is still unsaved
/// (GENOTYPE-QUIT-LOSES-WAITING-EDIT).
///
/// A comment or review made while a result's workbook is being updated waits for the update, and Quit waits for it up to
/// `ProjectTaskTerminationRegistry.annotationSaveTimeout`. An edit that is still waiting then is lost if the app quits,
/// so Quit asks first. "Quit Anyway" quits and "Don't Quit" keeps the app. A publication lock that never clears keeps its
/// retry, so the person sees this sheet on every Quit in that state, and "Quit Anyway" still leaves.
@MainActor
enum GenotypeEditQuitConfirmation {
    static let message =
        "A comment or review in a genotype result has not been saved because its workbook is still updating."
    static let advice =
        "Quit Anyway discards it. If you choose Don't Quit, Lungfish keeps trying to save it until the update ends."
    static let quitButtonTitle = "Quit Anyway"
    static let dontQuitButtonTitle = "Don't Quit"

    #if DEBUG
    /// Test seam: answers the sheet without UI. It returns `true` for Quit Anyway.
    static var testingAnswer: (@MainActor () async -> Bool)?
    #endif

    /// Whether Quit may go on. It is `true` at once when no annotation edit is unsaved, and otherwise it is the person's
    /// answer to the sheet.
    static func mayQuit(presentingOn window: NSWindow?) async -> Bool {
        guard GenotypeResultViewController.isSavingAnnotationEdits else { return true }
        #if DEBUG
        if let answer = testingAnswer {
            return await answer()
        }
        #endif
        return await presentSheet(on: window)
    }

    /// The sheet, built and not shown. Only `Don't Quit` answers Return. `NSAlert` gives Return to the first button it
    /// is given, so `Quit Anyway` lets go of it, and a stray Return cannot discard a person's edit.
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = advice
        let quitButton = alert.addButton(withTitle: quitButtonTitle)
        quitButton.hasDestructiveAction = true
        quitButton.keyEquivalent = ""
        let dontQuitButton = alert.addButton(withTitle: dontQuitButtonTitle)
        dontQuitButton.keyEquivalent = "\r"
        alert.applyLungfishBranding()
        return alert
    }

    private static func presentSheet(on window: NSWindow?) async -> Bool {
        let alert = makeAlert()
        // With no visible window there is nothing to present a sheet on, and the project rules forbid app-modal
        // runModal. Let the quit proceed, as the sheet for running operations does.
        guard let window = window
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
            return true
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}
