// MSADistanceColorScaleTests.swift - ramp, range and text contrast for the distance matrix (rulings P8, U6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishAlignmentUI

final class MSADistanceColorScaleTests: XCTestCase {
    func testCellTextContrastIsAtLeastFourPointFiveAcrossTheRampInBothAppearances() {
        for appearance in MSADistanceAppearance.allCases {
            for step in 0...200 {
                let t = Double(step) / 200
                let fill = MSADistanceColorScale.rampColor(at: t, appearance: appearance)
                let text = MSADistanceColorScale.textColor(on: fill)
                let ratio = MSADistanceColorScale.contrastRatio(fill, text)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance) t=\(t) ratio=\(ratio)")
            }
        }
    }

    func testIntensityMovesAwayFromTheBackgroundAsValueRises() {
        for appearance in MSADistanceAppearance.allCases {
            let background = MSADistanceColorScale.background(appearance)
            var previous = -1.0
            for step in 0...50 {
                let fill = MSADistanceColorScale.rampColor(at: Double(step) / 50, appearance: appearance)
                let distance = abs(MSADistanceOKLab(fill).l - MSADistanceOKLab(background).l)
                XCTAssertGreaterThan(distance, previous, "\(appearance) step \(step)")
                previous = distance
            }
        }
    }

    func testLowestFillIsDistinguishableFromTheEmptyBackground() {
        for appearance in MSADistanceAppearance.allCases {
            let lowest = MSADistanceColorScale.rampColor(at: 0, appearance: appearance)
            XCTAssertNotEqual(lowest, MSADistanceColorScale.background(appearance))
        }
    }

    func testOKLabRoundTripsSRGB() {
        let colour = MSADistanceRGB(red: 0.2, green: 0.6, blue: 0.9)
        let back = MSADistanceOKLab(colour).rgb
        XCTAssertEqual(back.red, 0.2, accuracy: 1e-6)
        XCTAssertEqual(back.green, 0.6, accuracy: 1e-6)
        XCTAssertEqual(back.blue, 0.9, accuracy: 1e-6)
    }

    func testDataRangeIgnoresDiagonalNanAndInf() {
        let values: [[Double]] = [
            [1.0, 0.98, .nan],
            [0.98, 1.0, 0.995],
            [.nan, 0.995, 1.0],
        ]
        let scale = MSADistanceColorScale(values: values, fixedUnitRange: false)
        XCTAssertEqual(scale.lower, 0.98)
        XCTAssertEqual(scale.upper, 0.995)
        XCTAssertEqual(try XCTUnwrap(scale.normalized(0.98)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(scale.normalized(0.995)), 1, accuracy: 1e-12)
        XCTAssertNil(scale.normalized(.nan))
        XCTAssertNil(scale.normalized(.infinity))
    }

    func testFixedUnitRangeUsesZeroToOne() {
        let scale = MSADistanceColorScale(values: [[0, 0.2], [0.2, 0]], fixedUnitRange: true)
        XCTAssertEqual(scale.lower, 0)
        XCTAssertEqual(scale.upper, 1)
        XCTAssertEqual(try XCTUnwrap(scale.normalized(0.2)), 0.2, accuracy: 1e-12)
    }

    func testFlatRangeMapsToTheMiddleOfTheRamp() {
        let scale = MSADistanceColorScale(values: [[1, 0.5], [0.5, 1]], fixedUnitRange: false)
        XCTAssertEqual(try XCTUnwrap(scale.normalized(0.5)), 0.5, accuracy: 1e-12)
    }

    func testFormatting() {
        XCTAssertEqual(MSADistanceValueFormat.cell(0.99851234), "0.9985")
        XCTAssertEqual(MSADistanceValueFormat.cell(.nan), "n/a")
        XCTAssertEqual(MSADistanceValueFormat.cell(.infinity), "∞")
        XCTAssertEqual(MSADistanceValueFormat.full(0.998512345), "0.998512")
        XCTAssertEqual(MSADistanceValueFormat.full(.nan), "nan")
        XCTAssertEqual(MSADistanceValueFormat.full(.infinity), "inf")
        XCTAssertEqual(MSADistanceValueFormat.count(29734), "29,734")
    }
}
