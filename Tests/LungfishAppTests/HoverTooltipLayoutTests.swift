import AppKit
import XCTest
@testable import LungfishApp

final class HoverTooltipLayoutTests: XCTestCase {
    func testOversizedContentIsContainedNearBottomRightWithNegativeScreenOrigin() {
        let available = NSRect(x: -1200, y: 40, width: 320, height: 210)

        let frame = HoverTooltipLayout.panelFrame(
            contentSize: NSSize(width: 900, height: 2_000),
            anchor: NSPoint(x: -890, y: 50),
            available: available
        )

        XCTAssertTrue(available.contains(frame))
        XCTAssertLessThanOrEqual(frame.width, available.width)
        XCTAssertLessThanOrEqual(frame.height, available.height)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(frame.origin.x.isFinite)
        XCTAssertTrue(frame.origin.y.isFinite)
    }

    func testDocumentSmallerThanPreferredMinimumUsesAvailableSpace() {
        let available = NSRect(x: 10, y: 20, width: 150, height: 100)

        let frame = HoverTooltipLayout.panelFrame(
            contentSize: NSSize(width: 500, height: 500),
            anchor: NSPoint(x: 80, y: 50),
            available: available
        )

        XCTAssertTrue(available.contains(frame))
        XCTAssertLessThanOrEqual(frame.width, available.width)
        XCTAssertLessThanOrEqual(frame.height, available.height)
    }

    func testShortContentUsesPreferredReadableWidthAndShrinksHeight() {
        let available = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        let frame = HoverTooltipLayout.panelFrame(
            contentSize: NSSize(width: 120, height: 74),
            anchor: NSPoint(x: 300, y: 300),
            available: available
        )

        XCTAssertEqual(frame.width, 240, accuracy: 0.001)
        XCTAssertEqual(frame.height, 74, accuracy: 0.001)
    }

    func testEmptyAvailableBoundsSuppressPresentation() {
        XCTAssertEqual(
            HoverTooltipLayout.panelFrame(
                contentSize: NSSize(width: 200, height: 100),
                anchor: .zero,
                available: .zero
            ),
            .zero
        )
    }

    func testTransitRetainsOnlyNarrowRouteToPanel() {
        let anchor = NSPoint(x: 20, y: 20)
        let panel = NSRect(x: 100, y: 80, width: 260, height: 180)

        XCTAssertTrue(
            HoverTooltipLayout.containsTransitPoint(
                NSPoint(x: 60, y: 48),
                anchor: anchor,
                panel: panel
            )
        )
        XCTAssertFalse(
            HoverTooltipLayout.containsTransitPoint(
                NSPoint(x: 60, y: 100),
                anchor: anchor,
                panel: panel
            )
        )
        XCTAssertTrue(
            HoverTooltipLayout.containsTransitPoint(
                NSPoint(x: 104, y: 84),
                anchor: anchor,
                panel: panel
            )
        )
    }
}
