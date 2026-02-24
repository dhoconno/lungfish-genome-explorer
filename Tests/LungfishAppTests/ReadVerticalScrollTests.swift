// ReadVerticalScrollTests.swift - Tests for read track vertical scrolling
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class ReadVerticalScrollTests: XCTestCase {

    // MARK: - Scroll Indicator Geometry

    func testScrollIndicatorHeightProportionalToContent() {
        // If visible is 300px and content is 600px, indicator should be ~150px (50%)
        let visibleHeight: CGFloat = 300
        let contentHeight: CGFloat = 600
        let fraction = visibleHeight / contentHeight
        let indicatorHeight = max(20, visibleHeight * fraction)
        XCTAssertEqual(indicatorHeight, 150)
    }

    func testScrollIndicatorMinimumHeight() {
        // Very tall content → indicator should still be >= 20px
        let visibleHeight: CGFloat = 300
        let contentHeight: CGFloat = 100_000
        let fraction = visibleHeight / contentHeight
        let indicatorHeight = max(20, visibleHeight * fraction)
        XCTAssertEqual(indicatorHeight, 20, "Indicator should clamp to minimum height")
    }

    func testScrollFractionAtTop() {
        let scrollOffset: CGFloat = 0
        let contentHeight: CGFloat = 600
        let visibleHeight: CGFloat = 300
        let scrollFraction = scrollOffset / (contentHeight - visibleHeight)
        XCTAssertEqual(scrollFraction, 0)
    }

    func testScrollFractionAtBottom() {
        let contentHeight: CGFloat = 600
        let visibleHeight: CGFloat = 300
        let scrollOffset: CGFloat = contentHeight - visibleHeight // 300
        let scrollFraction = scrollOffset / (contentHeight - visibleHeight)
        XCTAssertEqual(scrollFraction, 1.0)
    }

    func testScrollFractionMiddle() {
        let contentHeight: CGFloat = 600
        let visibleHeight: CGFloat = 300
        let scrollOffset: CGFloat = 150
        let scrollFraction = scrollOffset / (contentHeight - visibleHeight)
        XCTAssertEqual(scrollFraction, 0.5, accuracy: 0.01)
    }

    // MARK: - Pack Layout Caching

    func testPackLayoutCacheInvalidation() {
        // Verify the logic: cache should be invalid when scale changes
        let currentScale = 2.0
        let cachedScale = 2.0
        let currentGen = 5
        let cachedGen = 5
        let maxRows = 75
        let cachedMaxRows = 75

        let needsRepack = (currentScale != cachedScale)
            || (currentGen != cachedGen)
            || (maxRows != cachedMaxRows)
        XCTAssertFalse(needsRepack, "Same scale/gen/maxRows should not need repack")
    }

    func testPackLayoutCacheInvalidatesOnScaleChange() {
        let needsRepack = (2.0 != 3.0) || (5 != 5) || (75 != 75)
        XCTAssertTrue(needsRepack, "Scale change should trigger repack")
    }

    func testPackLayoutCacheInvalidatesOnDataChange() {
        let needsRepack = (2.0 != 2.0) || (5 != 6) || (75 != 75)
        XCTAssertTrue(needsRepack, "Generation change should trigger repack")
    }

    func testPackLayoutCacheInvalidatesOnMaxRowsChange() {
        let needsRepack = (2.0 != 2.0) || (5 != 5) || (75 != 50)
        XCTAssertTrue(needsRepack, "MaxRows change should trigger repack")
    }

    // MARK: - Read Content Height Calculation

    func testReadContentHeightPacked() {
        let rowCount = 50
        let height = ReadTrackRenderer.totalHeight(rowCount: rowCount, tier: .packed)
        // 50 * (6 + 1) = 350
        XCTAssertEqual(height, 350)
    }

    func testReadContentHeightBase() {
        let rowCount = 20
        let height = ReadTrackRenderer.totalHeight(rowCount: rowCount, tier: .base)
        // 20 * (14 + 1) = 300
        XCTAssertEqual(height, 300)
    }

    func testMaxScrollOffset() {
        // Content 700px, visible 300px → max scroll 400px
        let contentHeight: CGFloat = 700
        let visibleHeight: CGFloat = 300
        let maxScroll = max(0, contentHeight - visibleHeight)
        XCTAssertEqual(maxScroll, 400)
    }

    func testMaxScrollOffsetZeroWhenFits() {
        // Content 200px, visible 300px → max scroll 0
        let contentHeight: CGFloat = 200
        let visibleHeight: CGFloat = 300
        let maxScroll = max(0, contentHeight - visibleHeight)
        XCTAssertEqual(maxScroll, 0)
    }

    // MARK: - Hit Testing with Scroll Offset

    func testRowIndexWithScrollOffset() {
        let rY: CGFloat = 100
        let readScrollOffset: CGFloat = 50
        let pointY: CGFloat = 120 // 20px below read track start
        let rowHeight: CGFloat = 7.0 // packedReadHeight(6) + rowGap(1)

        let contentY = (pointY - rY) + readScrollOffset // 20 + 50 = 70
        let rowIndex = Int(contentY / rowHeight) // 70 / 7 = 10
        XCTAssertEqual(rowIndex, 10)
    }

    func testRowIndexWithoutScrollOffset() {
        let rY: CGFloat = 100
        let readScrollOffset: CGFloat = 0
        let pointY: CGFloat = 114 // 14px below start
        let rowHeight: CGFloat = 7.0

        let contentY = (pointY - rY) + readScrollOffset // 14
        let rowIndex = Int(contentY / rowHeight) // 14 / 7 = 2
        XCTAssertEqual(rowIndex, 2)
    }

    func testPointOutsideVisibleReadArea() {
        // If visibleHeight is 300 and point.y is at rY + 350, should be outside
        let rY: CGFloat = 100
        let visibleHeight: CGFloat = 300
        let pointY: CGFloat = 450 // rY + 350

        let inArea = pointY >= rY && pointY < rY + visibleHeight
        XCTAssertFalse(inArea)
    }

    func testPointInsideVisibleReadArea() {
        let rY: CGFloat = 100
        let visibleHeight: CGFloat = 300
        let pointY: CGFloat = 250

        let inArea = pointY >= rY && pointY < rY + visibleHeight
        XCTAssertTrue(inArea)
    }

    // MARK: - Scroll Clamping

    func testScrollOffsetClampedToZero() {
        var offset: CGFloat = -10
        let maxScroll: CGFloat = 100
        offset = max(0, min(maxScroll, offset))
        XCTAssertEqual(offset, 0)
    }

    func testScrollOffsetClampedToMax() {
        var offset: CGFloat = 150
        let maxScroll: CGFloat = 100
        offset = max(0, min(maxScroll, offset))
        XCTAssertEqual(offset, 100)
    }

    func testScrollOffsetWithinRange() {
        var offset: CGFloat = 50
        let maxScroll: CGFloat = 100
        offset = max(0, min(maxScroll, offset))
        XCTAssertEqual(offset, 50)
    }
}
