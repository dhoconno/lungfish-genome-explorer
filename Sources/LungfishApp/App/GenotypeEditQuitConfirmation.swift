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
///
/// With no window to hold the sheet, the app brings one forward (the Welcome window when no project window is left) and
/// asks there. Quit never goes on while an edit waits unless the person answers "Quit Anyway" (UX-QUIT-LOSES-EDIT).
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
    /// Test seam: stands in for the sheet on the window the host provider brought forward, and is handed that window. It
    /// returns `true` for Quit Anyway, so a test never reaches a real sheet.
    static var testingSheetAnswer: (@MainActor (NSWindow) async -> Bool)?
    #endif

    /// Whether Quit may go on. It is `true` at once when no annotation edit is unsaved, and otherwise it is the person's
    /// answer to the sheet. `hostProvider` brings a window into view to hold the sheet, and is called once, only when
    /// an edit waits.
    static func mayQuit(hostProvider: @MainActor () -> NSWindow?) async -> Bool {
        guard GenotypeResultViewController.isSavingAnnotationEdits else { return true }
        #if DEBUG
        if let answer = testingAnswer {
            return await answer()
        }
        #endif
        return await presentSheet(hostProvider: hostProvider)
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

    private static func presentSheet(hostProvider: @MainActor () -> NSWindow?) async -> Bool {
        // The provider runs first, and even when a project window exists, so a hidden or miniaturized host is in view
        // before the sheet goes on it (QUIT-SHEET-UNSEEN). The project rules forbid app-modal runModal, so with no
        // window at all the person cannot be asked: Quit does not go on, the edit stays, and the Dock icon marks it.
        guard let window = hostProvider() else {
            NSApp.requestUserAttention(.criticalRequest)
            return false
        }
        #if DEBUG
        if let answer = testingSheetAnswer {
            return await answer(window)
        }
        #endif
        return await makeAlert().beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

extension AppDelegate {
    /// The window that holds the genotype Quit sheet, in view and in front (UX-QUIT-LOSES-EDIT). The app is unhidden and
    /// activated, a miniaturized window is restored, and the project window is ordered front. With no project window
    /// left, the Welcome window is shown, since the Dock's reopen route shows nothing then. It is `nil` only when no
    /// window can be made.
    func windowForGenotypeQuitSheet() -> NSWindow? {
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = mainWindowController?.window
            ?? NSApp.windows.first(where: { $0.isMiniaturized && $0.canBecomeKey }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return window
        }
        if let welcome = welcomeWindowController {
            welcome.show()
        } else {
            showWelcomeWindow()
        }
        return welcomeWindowController?.window
    }
}
