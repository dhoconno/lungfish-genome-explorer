// CoverageScaleModeTests.swift - Coverage axis scaling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class CoverageScaleModeTests: XCTestCase {
    func testDefaultIsLinear() {
        XCTAssertEqual(CoverageScaleMode.default, .linear)
    }

    func testAllModesAreOfferedInAStableOrder() {
        XCTAssertEqual(CoverageScaleMode.allCases, [.linear, .log10, .squareRoot])
    }

    func testLinearHeightIsProportionalToDepth() {
        XCTAssertEqual(CoverageScaleMode.linear.normalizedHeight(depth: 50, maxDepth: 100), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CoverageScaleMode.linear.normalizedHeight(depth: 100, maxDepth: 100), 1.0, accuracy: 1e-9)
    }

    func testZeroDepthIsFlatInEveryMode() {
        // Uncovered positions must sit on the baseline; log10 of 0 would be
        // -infinity without the +1 offset.
        for mode in CoverageScaleMode.allCases {
            XCTAssertEqual(mode.normalizedHeight(depth: 0, maxDepth: 1000), 0, accuracy: 1e-9, "\(mode)")
        }
    }

    func testMaxDepthAlwaysFillsTheTrackInEveryMode() {
        for mode in CoverageScaleMode.allCases {
            XCTAssertEqual(mode.normalizedHeight(depth: 900, maxDepth: 900), 1.0, accuracy: 1e-9, "\(mode)")
        }
    }

    func testCompressingModesLiftLowCoverageAboveLinear() {
        // The motivating case: depth 5 against a 5000x peak is invisible on a
        // linear axis but must be discernible once compressed.
        let linear = CoverageScaleMode.linear.normalizedHeight(depth: 5, maxDepth: 5000)
        let root = CoverageScaleMode.squareRoot.normalizedHeight(depth: 5, maxDepth: 5000)
        let log = CoverageScaleMode.log10.normalizedHeight(depth: 5, maxDepth: 5000)

        XCTAssertLessThan(linear, 0.01)
        XCTAssertGreaterThan(root, linear)
        XCTAssertGreaterThan(log, root)
        XCTAssertGreaterThan(log, 0.2)
    }

    func testHeightIsMonotonicInDepth() {
        // A deeper position must never render shorter than a shallower one.
        for mode in CoverageScaleMode.allCases {
            var previous = -1.0
            for depth in stride(from: 0.0, through: 500.0, by: 25.0) {
                let height = mode.normalizedHeight(depth: depth, maxDepth: 500)
                XCTAssertGreaterThanOrEqual(height, previous, "\(mode) at depth \(depth)")
                previous = height
            }
        }
    }

    func testHeightIsClampedWhenDepthExceedsMax() {
        // Binned columns can exceed the summarized max; the path must stay
        // inside the track rather than overflow it.
        for mode in CoverageScaleMode.allCases {
            XCTAssertEqual(mode.normalizedHeight(depth: 10_000, maxDepth: 100), 1.0, accuracy: 1e-9, "\(mode)")
        }
    }

    func testDegenerateAxisProducesNoHeightRatherThanNaN() {
        for mode in CoverageScaleMode.allCases {
            let height = mode.normalizedHeight(depth: 10, maxDepth: 0)
            XCTAssertEqual(height, 0, "\(mode)")
            XCTAssertFalse(height.isNaN, "\(mode)")
        }
    }

    func testNegativeDepthIsClampedNotPropagatedAsNaN() {
        for mode in CoverageScaleMode.allCases {
            let height = mode.normalizedHeight(depth: -5, maxDepth: 100)
            XCTAssertEqual(height, 0, accuracy: 1e-9, "\(mode)")
            XCTAssertFalse(height.isNaN, "\(mode)")
        }
    }

    func testOnlyCompressingModesAnnotateTheAxis() {
        XCTAssertNil(CoverageScaleMode.linear.axisLabel)
        XCTAssertNotNil(CoverageScaleMode.log10.axisLabel)
        XCTAssertNotNil(CoverageScaleMode.squareRoot.axisLabel)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(CoverageScaleMode.linear.rawValue, "linear")
        XCTAssertEqual(CoverageScaleMode.log10.rawValue, "log10")
        XCTAssertEqual(CoverageScaleMode.squareRoot.rawValue, "squareRoot")
        XCTAssertEqual(CoverageScaleMode(rawValue: "log10"), .log10)
    }
}
