// DefaultZoomWindowWiringTests.swift - FEA-10 regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Before this fix, `AppSettings.defaultZoomWindow` had no reader anywhere outside
// `AppSettings` itself and the General settings tab's stepper: navigating to a single
// position (no explicit end) in either "Sequence > Go to Location" or the coordinate
// ruler's locus field always opened a hardcoded window (1000 bp and 10000 bp
// respectively, two different values for what a user would expect to be the same
// setting), ignoring whatever the user set "Default zoom window" to.
//
// `AppDelegate.singlePositionWindow(centeredOn:chromosomeLength:defaultWindow:)` is the
// pure windowing math `navigateSequenceViewer` (Go to Location) now calls with
// `AppSettings.shared.defaultZoomWindow`; `EnhancedCoordinateRulerView`'s locus field and
// "reset zoom" action were changed the same way. This test exercises the pure function
// directly (no bundle fixture needed) to prove the window is actually driven by the
// passed-in default, including the boundary-clamping behavior it inherited unchanged
// from the original hardcoded logic.

import XCTest
@testable import LungfishApp

@MainActor
final class DefaultZoomWindowWiringTests: XCTestCase {
    func testWindowIsCenteredOnPositionUsingTheGivenDefault() {
        let (start, end) = AppDelegate.singlePositionWindow(
            centeredOn: 5_000,
            chromosomeLength: 20_000,
            defaultWindow: 2_000
        )
        XCTAssertEqual(start, 4_000)
        XCTAssertEqual(end, 6_000)
        XCTAssertEqual(end - start, 2_000)
    }

    func testADifferentDefaultProducesADifferentWindowAtTheSamePosition() {
        // The actual bug: two entry points computed this with two different hardcoded
        // constants. Once both read the same setting, the SAME setting value must
        // produce the SAME window width for both -- this is the direct proof that the
        // window width is driven by the parameter, not a residual hardcoded constant.
        let narrow = AppDelegate.singlePositionWindow(centeredOn: 5_000, chromosomeLength: 20_000, defaultWindow: 1_000)
        let wide = AppDelegate.singlePositionWindow(centeredOn: 5_000, chromosomeLength: 20_000, defaultWindow: 10_000)
        XCTAssertEqual(narrow.end - narrow.start, 1_000)
        XCTAssertEqual(wide.end - wide.start, 10_000)
    }

    func testWindowClampsToTheStartOfTheChromosome() {
        let (start, end) = AppDelegate.singlePositionWindow(
            centeredOn: 100,
            chromosomeLength: 20_000,
            defaultWindow: 1_000
        )
        XCTAssertEqual(start, 0, "a position near the start must not produce a negative window start")
        XCTAssertEqual(end, 1_000)
    }

    func testWindowClampsToTheEndOfTheChromosome() {
        let (start, end) = AppDelegate.singlePositionWindow(
            centeredOn: 19_900,
            chromosomeLength: 20_000,
            defaultWindow: 1_000
        )
        XCTAssertEqual(end, 20_000, "a position near the end must not produce a window past the chromosome")
        XCTAssertEqual(start, 19_000)
    }

    func testWindowWiderThanTheChromosomeIsClampedToTheWholeChromosome() {
        let (start, end) = AppDelegate.singlePositionWindow(
            centeredOn: 500,
            chromosomeLength: 800,
            defaultWindow: 10_000
        )
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 800)
    }
}
