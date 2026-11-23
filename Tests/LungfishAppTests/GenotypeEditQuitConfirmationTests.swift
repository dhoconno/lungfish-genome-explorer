// GenotypeEditQuitConfirmationTests.swift - The buttons and the host of the Quit sheet for a waiting genotype edit (Phase 3.2 lane QUITEDIT, FIX-QUIT-NO-WINDOW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Quit tests answer the sheet through a seam, so none of them builds it. One test builds the alert and shows
// nothing, and reads which button answers Return, which button is destructive and in what order they stand. The others
// hold a waiting retry the way the genotype matrix does and give `mayQuit` a host provider of their own, with the sheet
// seam in place of the sheet, so no test shows a sheet or a Welcome window (UX-QUIT-LOSES-EDIT).

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// What the host provider and the sheet seam were asked, and how the sheet seam answers.
@MainActor
private final class QuitHostRecorder {
    var hostAsked = 0
    var sheetWindows: [NSWindow] = []
    var quitAnyway = false
}

@MainActor
final class GenotypeEditQuitConfirmationTests: XCTestCase {
    /// UX-QUIT-LOSES-EDIT. With an edit waiting and no window to host the sheet, Quit must not go on unasked. At the
    /// base `mayQuit(presentingOn: nil)` returned `true` here and the queued edit, held only in memory, was gone.
    func testQuitWithAWaitingEditAndNoWindowDoesNotGoOnWithoutAnAnswer() async throws {
        try requireNoPendingAnnotationEditsForTest()
        _ = NSApplication.shared
        GenotypeEditQuitConfirmation.testingAnswer = nil
        let recorder = QuitHostRecorder()
        GenotypeEditQuitConfirmation.testingSheetAnswer = { window in
            recorder.sheetWindows.append(window)
            return true
        }
        defer { GenotypeEditQuitConfirmation.testingSheetAnswer = nil }
        let hold = GenotypeWaitingRetryHold()
        defer { hold.release() }
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "a waiting retry counts as saving")

        let mayQuit = await GenotypeEditQuitConfirmation.mayQuit(hostProvider: {
            recorder.hostAsked += 1
            return nil
        })

        XCTAssertFalse(mayQuit, "Quit went on with a genotype edit waiting and nobody asked the person")
        XCTAssertEqual(recorder.hostAsked, 1, "the host provider is asked exactly once")
        XCTAssertTrue(recorder.sheetWindows.isEmpty, "with no window there is no sheet to show")
    }

    /// The sheet goes on the window the host provider brought forward, and the person's answer decides Quit.
    func testTheSheetGoesToTheWindowTheHostProviderBroughtForwardAndTheAnswerDecidesQuit() async throws {
        try requireNoPendingAnnotationEditsForTest()
        _ = NSApplication.shared
        GenotypeEditQuitConfirmation.testingAnswer = nil
        let host = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        host.isReleasedWhenClosed = false
        let recorder = QuitHostRecorder()
        GenotypeEditQuitConfirmation.testingSheetAnswer = { window in
            recorder.sheetWindows.append(window)
            return recorder.quitAnyway
        }
        defer { GenotypeEditQuitConfirmation.testingSheetAnswer = nil }
        let hold = GenotypeWaitingRetryHold()
        defer { hold.release() }

        recorder.quitAnyway = true
        let quitAnyway = await GenotypeEditQuitConfirmation.mayQuit(hostProvider: {
            recorder.hostAsked += 1
            return host
        })
        recorder.quitAnyway = false
        let dontQuit = await GenotypeEditQuitConfirmation.mayQuit(hostProvider: {
            recorder.hostAsked += 1
            return host
        })

        XCTAssertTrue(quitAnyway, "Quit Anyway lets Quit go on")
        XCTAssertFalse(dontQuit, "Don't Quit keeps the app and the edit")
        XCTAssertEqual(recorder.hostAsked, 2, "each Quit brings its host forward once")
        XCTAssertEqual(recorder.sheetWindows.count, 2, "each Quit asks once")
        XCTAssertTrue(
            recorder.sheetWindows.allSatisfy { $0 === host },
            "the sheet went to the window the provider brought forward"
        )
    }

    /// With no edit waiting Quit goes on at once, and no window is brought forward for a sheet nobody needs.
    func testQuitGoesOnAtOnceAndNoWindowIsBroughtForwardWhenNoEditWaits() async throws {
        try requireNoPendingAnnotationEditsForTest()
        let recorder = QuitHostRecorder()

        let mayQuit = await GenotypeEditQuitConfirmation.mayQuit(hostProvider: {
            recorder.hostAsked += 1
            return nil
        })

        XCTAssertTrue(mayQuit, "nothing is waiting, so Quit is not held")
        XCTAssertEqual(recorder.hostAsked, 0, "no host is brought forward when no edit waits")
    }

    func testTheQuitSheetGivesReturnToDontQuitOnlyAndKeepsQuitAnywayDestructiveAndFirst() {
        let alert = GenotypeEditQuitConfirmation.makeAlert()
        XCTAssertEqual(
            alert.buttons.map(\.title),
            [GenotypeEditQuitConfirmation.quitButtonTitle, GenotypeEditQuitConfirmation.dontQuitButtonTitle]
        )
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["", "\r"], "only Don't Quit may answer Return")
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction, "Quit Anyway discards the edit")
        XCTAssertFalse(alert.buttons[1].hasDestructiveAction, "Don't Quit keeps it")
    }
}
