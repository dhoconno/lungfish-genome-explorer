// TaxTriageActionBarSpacingTests.swift - Pins where the TaxTriage action bar starts its info text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.53 (UX 1). Deleting the hidden Recompute Unique Reads button moved the info text left by the
// button's 170 pt and its 6 pt gap, so `reserveTheSpaceOfTheDeletedRecomputeButton` adds the 176 pt back to the
// bar's one leading constraint. The helper finds that constraint by its two items, so a change in the bar would make
// it find nothing and move nothing, and this pin fails then. The 186 pt is the 10 pt the bar leaves after its last
// button plus the 176 pt. It is the figure at the lane base (info text at x 596, Open Report ending at 309 + 101).

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
import LungfishKit
import LungfishTestSupport

@MainActor
final class TaxTriageActionBarSpacingTests: XCTestCase {
    func testInfoTextStaysWhereTheDeletedRecomputeButtonPutIt() throws {
        let controller = TaxTriageResultViewController()
        controller.layoutDefaults = makeTestDefaultsSuite(prefix: "TaxTriageActionBarSpacingTests").defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()

        let bars = Self.actionBars(in: controller.view)
        XCTAssertEqual(bars.count, 1)
        let bar = try XCTUnwrap(bars.first)
        XCTAssertEqual(
            bar.infoLabel.frame.minX - controller.testingOpenReportButton.frame.maxX,
            186,
            accuracy: 0.5,
            "the info text starts 186 pt after Open Report, the 10 pt gap plus the 176 pt of the deleted button"
        )
    }

    private static func actionBars(in view: NSView) -> [ClassifierActionBar] {
        view.subviews.flatMap { subview -> [ClassifierActionBar] in
            if let bar = subview as? ClassifierActionBar { return [bar] }
            return actionBars(in: subview)
        }
    }
}
