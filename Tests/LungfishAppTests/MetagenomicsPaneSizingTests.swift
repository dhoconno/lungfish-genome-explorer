import XCTest
@testable import LungfishApp

@MainActor
final class MetagenomicsPaneSizingViewerBehaviorTests: XCTestCase {
    func testAnnotationDrawerDragLeavesVisibleHostStrip() {
        let viewerVC = ViewerViewController()
        _ = viewerVC.view
        viewerVC.view.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)

        let heightConstraint = NSLayoutConstraint(
            item: viewerVC.view,
            attribute: .height,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 950
        )
        viewerVC.annotationDrawerHeightConstraint = heightConstraint

        viewerVC.annotationDrawerDidDragDivider(AnnotationTableDrawerView(), deltaY: 100)

        XCTAssertEqual(heightConstraint.constant, 920)
    }

    func testFASTQDrawerDragLeavesVisibleHostStrip() {
        let viewerVC = ViewerViewController()
        _ = viewerVC.view
        viewerVC.view.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)

        let heightConstraint = NSLayoutConstraint(
            item: viewerVC.view,
            attribute: .height,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 950
        )
        viewerVC.fastqMetadataDrawerHeightConstraint = heightConstraint

        viewerVC.fastqMetadataDrawerDidDragDivider(FASTQMetadataDrawerView(), deltaY: 100)

        XCTAssertEqual(heightConstraint.constant, 920)
    }
}

final class MetagenomicsPaneSizingTests: XCTestCase {
    func testClampedDrawerExtentLeavesVisibleHostStrip() {
        let height = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: 960,
            containerExtent: 1000,
            minimumDrawerExtent: 140,
            minimumSiblingExtent: 120
        )

        XCTAssertEqual(height, 880)
    }

    func testClampedDrawerExtentHonorsMinimumDrawerHeight() {
        let height = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: 50,
            containerExtent: 1000,
            minimumDrawerExtent: 140,
            minimumSiblingExtent: 120
        )

        XCTAssertEqual(height, 140)
    }

    func testClampedDrawerExtentPrefersVisibleSiblingStripInUndersizedContainer() {
        let height = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: 200,
            containerExtent: 220,
            minimumDrawerExtent: 140,
            minimumSiblingExtent: 120
        )

        XCTAssertEqual(height, 100)
    }

    func testClampedDividerPositionLeavesVisibleTrailingPane() {
        let position = MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: 980,
            containerExtent: 1000,
            minimumLeadingExtent: 120,
            minimumTrailingExtent: 120
        )

        XCTAssertEqual(position, 880)
    }
}
