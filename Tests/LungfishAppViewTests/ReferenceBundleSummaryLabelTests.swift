// ReferenceBundleSummaryLabelTests.swift - A long summary line never widens the window (WALKFIX, W-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// W-26 of the 2026-11-05 walk. The summary line above the reference viewport was a plain label with no truncation and
/// the default horizontal compression resistance, chained across the bar. A long line, such as the words of an
/// alignment summary that could not be measured, set a minimum width and the window grew to 4387 points on a 2560 point
/// screen, with its toolbar and Inspector off screen. The label now truncates in the middle, since the warning sits at
/// the tail of the line, yields to the window, and holds the whole line in its tooltip.
@MainActor
final class ReferenceBundleSummaryLabelTests: XCTestCase {
    /// About 460 characters, the shape of the line the walk saw when it could not measure the alignment statistics.
    private static let longLine = String(
        repeating: "Measuring the alignment statistics for HG002 minimap2 [unmarked], ", count: 7
    )

    /// A window 760 points wide, on screen but far outside every display, holding the viewport.
    private func makeHost() -> (controller: ReferenceBundleViewportController, window: NSWindow) {
        let controller = ReferenceBundleViewportController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 520))
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        return (controller, window)
    }

    func testLongSummaryLineDoesNotGrowTheWindow() {
        let (controller, window) = makeHost()
        defer {
            window.contentViewController = nil
            window.close()
        }
        XCTAssertEqual(window.frame.width, 760, accuracy: 0.5, "the host starts 760 points wide")

        controller.summaryLabel.stringValue = Self.longLine
        window.layoutIfNeeded()

        XCTAssertEqual(
            window.frame.width, 760, accuracy: 0.5,
            "a \(Self.longLine.count) character summary line widened the window to \(window.frame.width) points"
        )
        XCTAssertLessThanOrEqual(
            controller.summaryLabel.frame.width, window.frame.width,
            "the label is cut to the window and does not run past it"
        )
    }

    func testSummaryToolTipHoldsTheWholeLine() {
        let controller = ReferenceBundleViewportController()
        _ = controller.view

        controller.summaryLabel.stringValue = Self.longLine
        XCTAssertEqual(controller.summaryLabel.toolTip, Self.longLine, "the tooltip is the whole line, not the cut one")

        controller.summaryLabel.stringValue = "Reference Bundle"
        XCTAssertEqual(controller.summaryLabel.toolTip, "Reference Bundle", "the tooltip follows every write")
    }

    /// The tips the mapping words set (`alignmentSummaryTip` holds the reason and the next step) stay readable under
    /// the whole line, whichever of the two is written first.
    func testATipSetByTheWriterStaysBeneathTheWholeLine() {
        let controller = ReferenceBundleViewportController()
        _ = controller.view
        let tip = "The total number of reads was not stored. Run the mapping again to count its reads."

        controller.summaryLabel.toolTip = tip
        controller.summaryLabel.stringValue = Self.longLine
        XCTAssertEqual(controller.summaryLabel.toolTip, Self.longLine + "\n\n" + tip)

        controller.summaryLabel.stringValue = "Reference Bundle"
        XCTAssertEqual(controller.summaryLabel.toolTip, "Reference Bundle" + "\n\n" + tip)

        controller.summaryLabel.toolTip = nil
        XCTAssertEqual(controller.summaryLabel.toolTip, "Reference Bundle", "clearing the tip leaves the whole line")
    }
}
