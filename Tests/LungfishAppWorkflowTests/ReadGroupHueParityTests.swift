// ReadGroupHueParityTests.swift - The read group hues against AppKit's HSB colours
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishWorkflow

/// `ViewerFigureColor(hue:saturation:brightness:)` against `NSColor(hue:saturation:brightness:alpha:)`
/// in sRGB, the colour the read track gave each read group before lane 13.29.
final class ReadGroupHueParityTests: XCTestCase {
    func testReadGroupHuesMatchAppKitInSRGB() throws {
        for count in 1...12 {
            for index in 0..<count {
                let hue = Double(index) / Double(count)
                let live = try XCTUnwrap(
                    NSColor(hue: CGFloat(hue), saturation: 0.55, brightness: 0.75, alpha: 1).usingColorSpace(.sRGB)
                )
                let figure = ViewerFigureColor(hue: hue, saturation: 0.55, brightness: 0.75)
                XCTAssertEqual(figure.red, Double(live.redComponent), accuracy: 0.001, "red at hue \(hue)")
                XCTAssertEqual(figure.green, Double(live.greenComponent), accuracy: 0.001, "green at hue \(hue)")
                XCTAssertEqual(figure.blue, Double(live.blueComponent), accuracy: 0.001, "blue at hue \(hue)")
                XCTAssertEqual(figure.alpha, 1)
            }
        }
    }

    func testTheOldCGColorWasSRGB() throws {
        let live = NSColor(hue: 0.25, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor
        XCTAssertEqual(live.colorSpace?.name, CGColorSpace.sRGB)
    }
}
