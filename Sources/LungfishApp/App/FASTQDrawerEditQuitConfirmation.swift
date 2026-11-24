// FASTQDrawerEditQuitConfirmation.swift - Quit and window close keep an edit waiting in the FASTQ drawer (ux-text lane DRAWERS-2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// A FASTQ drawer edit that could not be saved when the person left its dataset, quit or closed its window.
struct UnkeptFASTQDrawerEdit {
    let datasetURL: URL
    /// The system's reason the write failed, as it reads.
    let reason: String
    /// The project window that holds the drawer.
    weak var window: NSWindow?

    /// The dataset's name as the sidebar shows it: the bundle's name for a FASTQ in a bundle.
    var name: String {
        let folder = datasetURL.deletingLastPathComponent()
        return FASTQBundle.isBundleURL(folder) ? folder.deletingPathExtension().lastPathComponent : datasetURL.lastPathComponent
    }
}

/// What Quit does with an edit waiting in a FASTQ drawer (FASTQ-DRAWER-EDIT-LOST-ON-QUIT).
///
/// Quit never reaches the drawer's teardown, so before it goes on it saves each project window's waiting drawer edit
/// through Save's own path, as leaving the dataset does. An edit that cannot be written then is asked about in a Quit
/// sheet of the `GenotypeEditQuitConfirmation` pattern: "Quit Anyway" quits and discards it, and "Don't Quit" keeps the
/// app and the edit in its drawer, so the person can make the folder writable or put the dataset back and press Save.
/// The sheet goes on the window that holds the drawer, never `runModal`.
@MainActor
enum FASTQDrawerEditQuitConfirmation {
    #if DEBUG
    /// Test seam: stands in for the sheet and is handed it with the edits it names, before any window is brought
    /// forward. It returns `true` for Quit Anyway, so a test never reaches a real sheet.
    static var testingSheetAnswer: (@MainActor (NSAlert, [UnkeptFASTQDrawerEdit]) async -> Bool)?
    #endif

    /// Whether Quit may go on. It is `true` at once when every waiting edit was saved, and otherwise it is the person's
    /// answer to the sheet. `hostProvider` brings a window into view to hold the sheet, and is called once, only when
    /// an edit was not saved. With no window at all Quit does not go on, the edit stays, and the Dock icon marks it.
    static func mayQuit(unkept: [UnkeptFASTQDrawerEdit], hostProvider: @MainActor () -> NSWindow?) async -> Bool {
        guard !unkept.isEmpty else { return true }
        let alert = makeAlert(unkept: unkept)
        #if DEBUG
        if let answer = testingSheetAnswer {
            return await answer(alert, unkept)
        }
        #endif
        guard let window = hostProvider() else {
            NSApp.requestUserAttention(.criticalRequest)
            return false
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// The sheet, built and not shown. Only Don't Quit answers Return, as in the genotype Quit sheet, so a stray Return
    /// cannot discard the edit.
    static func makeAlert(unkept: [UnkeptFASTQDrawerEdit]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message(for: unkept)
        alert.informativeText = advice(for: unkept)
        let quitButton = alert.addButton(withTitle: GenotypeEditQuitConfirmation.quitButtonTitle)
        quitButton.hasDestructiveAction = true
        quitButton.keyEquivalent = ""
        alert.addButton(withTitle: GenotypeEditQuitConfirmation.dontQuitButtonTitle).keyEquivalent = "\r"
        alert.applyLungfishBranding()
        return alert
    }

    /// What happened, to which datasets, in the words of the select route's sheet.
    static func message(for unkept: [UnkeptFASTQDrawerEdit]) -> String {
        let names = unkept.map(\.name)
        let listed = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "The FASTQ drawer\u{2019}s edits for \(listed) were not saved."
    }

    /// Why, what each button does, and what to try. Each reason is said once and ends with a full stop.
    static func advice(for unkept: [UnkeptFASTQDrawerEdit]) -> String {
        var reasons: [String] = []
        for reason in unkept.map({ $0.reason.hasSuffix(".") ? $0.reason : $0.reason + "." }) where !reasons.contains(reason) {
            reasons.append(reason)
        }
        let check = unkept.count == 1
            ? "\(unkept[0].name) is still in the project and that its folder"
            : "these datasets are still in the project and that their folders"
        return (reasons + [
            "Quit Anyway discards the edits. If you choose Don't Quit, they stay in the drawer: check that \(check) can be "
                + "written, then press Save.",
        ]).joined(separator: " ")
    }
}

extension AppDelegate {
    /// Saves the edit waiting in each project window's FASTQ drawer through Save's own path before Quit goes on, and
    /// returns the edits that could not be saved, for the Quit sheet (FASTQ-DRAWER-EDIT-LOST-ON-QUIT).
    func keepWaitingFASTQDrawerEdits(in controllers: [MainWindowController]) -> [UnkeptFASTQDrawerEdit] {
        controllers.compactMap { $0.mainSplitViewController?.viewerController?.keepWaitingFASTQDrawerEditReportingFailure() }
    }

    /// The window that holds the drawer's Quit sheet: the project window of the first edit not saved, in view and in
    /// front, or else the genotype Quit sheet's window.
    func windowForFASTQDrawerQuitSheet(_ unkept: [UnkeptFASTQDrawerEdit]) -> NSWindow? {
        guard let window = unkept.lazy.compactMap(\.window).first else { return windowForGenotypeQuitSheet() }
        NSApp.unhide(nil)
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
