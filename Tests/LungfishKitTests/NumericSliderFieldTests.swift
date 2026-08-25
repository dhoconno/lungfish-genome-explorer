// NumericSliderFieldTests.swift - Typed slider-value resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class NumericSliderFieldTests: XCTestCase {
    func testParsesPlainIntegerWithinBounds() {
        XCTAssertEqual(NumericSliderFieldParser.parse("26", bounds: 1...50, step: 1), 26)
    }

    func testClampsTypedValueAboveUpperBound() {
        // A typed value is explicit intent: clamp it into range rather than
        // discarding the edit.
        XCTAssertEqual(NumericSliderFieldParser.parse("5000", bounds: 1...50, step: 1), 50)
    }

    func testClampsTypedValueBelowLowerBound() {
        XCTAssertEqual(NumericSliderFieldParser.parse("-12", bounds: 1...50, step: 1), 1)
    }

    func testRejectsNonNumericTextSoCurrentValueIsPreserved() {
        XCTAssertNil(NumericSliderFieldParser.parse("abc", bounds: 1...50, step: 1))
        XCTAssertNil(NumericSliderFieldParser.parse("", bounds: 1...50, step: 1))
        XCTAssertNil(NumericSliderFieldParser.parse("   ", bounds: 1...50, step: 1))
    }

    func testRejectsNonFiniteInput() {
        // "inf"/"nan" parse as Double but would corrupt the slider position.
        XCTAssertNil(NumericSliderFieldParser.parse("inf", bounds: 1...50, step: 1))
        XCTAssertNil(NumericSliderFieldParser.parse("nan", bounds: 1...50, step: 1))
    }

    func testAcceptsDecoratedInput() {
        // Values copied from the adjacent read-out carry a percent sign or
        // grouping separators.
        XCTAssertEqual(NumericSliderFieldParser.parse("75%", bounds: 50...99, step: 1), 75)
        XCTAssertEqual(NumericSliderFieldParser.parse("25,000", bounds: 5_000...500_000, step: 5_000), 25_000)
    }

    func testSnapsToNearestStep() {
        // 1004 lies between the 1000 and 1010 stops of a step-10 slider.
        XCTAssertEqual(NumericSliderFieldParser.snap(1004, bounds: 10...2000, step: 10), 1000)
        XCTAssertEqual(NumericSliderFieldParser.snap(1006, bounds: 10...2000, step: 10), 1010)
    }

    func testSnapsRelativeToLowerBoundWhenBoundIsNotAStepMultiple() {
        // Stops are 10, 20, ... 2000; 15 is equidistant and must not land on a
        // position the slider cannot reach.
        let snapped = NumericSliderFieldParser.snap(14, bounds: 10...2000, step: 10)
        XCTAssertEqual(snapped, 10)
        XCTAssertEqual(snapped.truncatingRemainder(dividingBy: 10), 0)
    }

    func testSnappedValueNeverEscapesBounds() {
        // With bounds 50...99 and step 2 the reachable stops are 50, 52 ... 98,
        // so the upper bound itself is not a stop. Snapping must land on a
        // reachable stop and must never exceed the upper bound.
        XCTAssertEqual(NumericSliderFieldParser.snap(98.9, bounds: 50...99, step: 2), 98)
        XCTAssertEqual(NumericSliderFieldParser.snap(50.1, bounds: 50...99, step: 2), 50)
        XCTAssertLessThanOrEqual(NumericSliderFieldParser.snap(1_000, bounds: 50...99, step: 2), 99)
    }

    func testZeroStepFallsBackToPlainClamping() {
        XCTAssertEqual(NumericSliderFieldParser.snap(33.3, bounds: 0...60, step: 0), 33.3)
    }
}
