// NumericSliderFieldTests.swift - Typed slider-value resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SwiftUI
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

    func testFractionalStepSnapsTypedValueOntoStop() throws {
        // FASTQ entropy threshold: 0.3...0.9 in 0.05 steps, shown as "%.2f".
        let resolved = try XCTUnwrap(NumericSliderFieldParser.parse("0.62", bounds: 0.3...0.9, step: 0.05))
        XCTAssertEqual(resolved, 0.6, accuracy: 1e-9)
        XCTAssertEqual(String(format: "%.2f", resolved), "0.60")
    }

    func testPercentFieldKeepsPercentUnitsWhenTyped() throws {
        // Percent sliders (Primer MSA matches, per-locus dropout) bind the
        // percent value itself, so a typed "7.34%" stays in percent units.
        let resolved = try XCTUnwrap(NumericSliderFieldParser.parse("7.34%", bounds: 0...10, step: 0.1))
        XCTAssertEqual(resolved, 7.3, accuracy: 1e-9)
    }

    // MARK: - Accessibility value

    func testAccessibilityValueAppendsSuffix() {
        XCTAssertEqual(
            NumericSliderFieldParser.accessibilityValue(12, format: { String(Int($0)) }, suffix: "px"),
            "12 px"
        )
        XCTAssertEqual(
            NumericSliderFieldParser.accessibilityValue(0.6, format: { String(format: "%.2f", $0) }, suffix: ""),
            "0.60"
        )
    }

    // MARK: - Binding adapters

    func testCGFloatBindingRoundTrips() {
        var stored: CGFloat = 12
        let source = Binding<CGFloat>(get: { stored }, set: { stored = $0 })
        let adapted = Binding<Double>.numericSlider(source)
        XCTAssertEqual(adapted.wrappedValue, 12)
        adapted.wrappedValue = 27
        XCTAssertEqual(stored, 27)
    }

    func testFloatBindingRoundTrips() {
        var stored: Float = 0.25
        let source = Binding<Float>(get: { stored }, set: { stored = $0 })
        let adapted = Binding<Double>.numericSlider(source)
        XCTAssertEqual(adapted.wrappedValue, 0.25)
        adapted.wrappedValue = 0.75
        XCTAssertEqual(stored, 0.75)
    }

    func testIntBindingRoundsInsteadOfTruncating() {
        var stored = 5
        let source = Binding<Int>(get: { stored }, set: { stored = $0 })
        let adapted = Binding<Double>.numericSlider(source)
        XCTAssertEqual(adapted.wrappedValue, 5)
        adapted.wrappedValue = 7.6
        XCTAssertEqual(stored, 8)
        adapted.wrappedValue = 7.4
        XCTAssertEqual(stored, 7)
    }
}
