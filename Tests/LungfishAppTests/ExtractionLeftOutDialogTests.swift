// ExtractionLeftOutDialogTests.swift - The extraction dialog opens once the left-out alert is gone (WALKFIX, W-32)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// W-32 of the 2026-11-05 walk. "Extract 4 Sequences..." with one annotation in the cut part of a reference showed the
/// alert that says the rest will follow, and after OK nothing opened. `FailurePresenter` ran the completion inside the
/// alert sheet's end handler, where the alert is still the window's attached sheet, and the extraction dialog returns
/// with no word while a sheet is attached. These tests end a real alert in a real window.
@MainActor
final class ExtractionLeftOutDialogTests: XCTestCase {
    /// A viewer in a window that is on screen but far outside every display, so that its sheets animate as they do
    /// in the app.
    private func makeHost() -> (viewer: ViewerViewController, window: NSWindow) {
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        return (viewer, window)
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentViewController = nil
        window.close()
    }

    /// The model of the extraction dialog when that is the window's attached sheet, and nil for any other sheet.
    private func extractionDialogModel(in window: NSWindow) -> FASTASequenceExtractionDialogModel? {
        let host = window.attachedSheet?.contentViewController as? NSHostingController<FASTASequenceExtractionDialog>
        return host?.rootView.model
    }

    func testClosingTheLeftOutAlertOpensTheExtractionDialog() async throws {
        let (viewer, window) = makeHost()
        defer { close(window) }
        viewer.viewerView.sequence = try LungfishCore.Sequence(
            name: "chr1", alphabet: .dna, bases: String(repeating: "ACGT", count: 25)
        )
        // KEPT lies inside the 100 bases, and CUT lies past their end, as an annotation does on a reference cut short.
        let kept = SequenceAnnotation(type: .gene, name: "KEPT", chromosome: "chr1", start: 10, end: 40)
        let cut = SequenceAnnotation(type: .gene, name: "CUT", chromosome: "chr1", start: 150, end: 190)

        viewer.viewerView.presentAnnotationSequenceExtractionDialog([kept, cut])

        _ = await waitUntil(budget: .lookup) { window.attachedSheet != nil }
        let alertSheet = try XCTUnwrap(window.attachedSheet, "the left-out alert shows first")
        XCTAssertNil(extractionDialogModel(in: window), "the sheet the person sees first is the alert, not the dialog")

        window.endSheet(alertSheet)

        let opened = await waitUntil(budget: .lookup) { extractionDialogModel(in: window) != nil }
        XCTAssertTrue(
            opened,
            "after the alert closes the attached sheet is the extraction dialog, but the window holds \(String(describing: window.attachedSheet))"
        )
        XCTAssertEqual(extractionDialogModel(in: window)?.selectionCount, 1, "the dialog holds the one record that could be read")
        XCTAssertEqual(extractionDialogModel(in: window)?.name, "selected-annotations")
    }

    func testTheCompletionRunsWithTheAlertSheetGone() async throws {
        let (_, window) = makeHost()
        defer { close(window) }
        let report = FailureReport(failedStep: "Extract the selected annotations", whatHappened: "A.", nextStep: "B.", underlying: nil)
        var sheetSeenByCompletion: NSWindow?
        var completionRan = false

        FailurePresenter.present(report, in: window) {
            sheetSeenByCompletion = window.attachedSheet
            completionRan = true
        }
        _ = await waitUntil(budget: .lookup) { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet, "the alert is attached as a sheet"))

        let finished = await waitUntil(budget: .lookup) { completionRan }
        XCTAssertTrue(finished, "the completion runs once the alert ends")
        XCTAssertNil(sheetSeenByCompletion, "the completion sees no attached sheet, so a dialog it opens is not refused")
    }
}
