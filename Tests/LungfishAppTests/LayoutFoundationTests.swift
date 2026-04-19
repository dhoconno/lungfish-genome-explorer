import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class LayoutFoundationTests: XCTestCase {
    func testFillSplitPaneContainerKeepsFillSubviewSizedToBounds() {
        let fillSubview = NSView(frame: .zero)
        let container = SplitPaneFillContainerView()
        container.addSubview(fillSubview)
        container.fillSubview = fillSubview

        container.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(fillSubview.frame, container.bounds)

        container.setFrameSize(NSSize(width: 520, height: 300))
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(fillSubview.frame, container.bounds)
    }

    func testFlippedFillSplitPaneContainerUsesFlippedCoordinates() {
        XCTAssertTrue(FlippedSplitPaneFillContainerView().isFlipped)
    }
}
