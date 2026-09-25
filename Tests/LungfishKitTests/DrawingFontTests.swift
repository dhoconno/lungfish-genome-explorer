// DrawingFontTests.swift - DrawingFont never yields nil and matches AppKit for normal sizes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

final class DrawingFontTests: XCTestCase {
    func testFiniteSizesReturnExactlyTheAppKitFont() {
        for size: CGFloat in [6, 9, 10.5, 11, 13, 24] {
            for weight: NSFont.Weight in [.regular, .medium, .semibold, .bold] {
                XCTAssertEqual(DrawingFont.monospaced(ofSize: size, weight: weight),
                               NSFont.monospacedSystemFont(ofSize: size, weight: weight))
                XCTAssertEqual(DrawingFont.monospacedDigit(ofSize: size, weight: weight),
                               NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight))
                XCTAssertEqual(DrawingFont.system(ofSize: size, weight: weight),
                               NSFont.systemFont(ofSize: size, weight: weight))
            }
            XCTAssertEqual(DrawingFont.system(ofSize: size), NSFont.systemFont(ofSize: size))
        }
    }

    func testNonFiniteSizesResolveToAFiniteSystemSize() {
        for size: CGFloat in [.nan, .infinity, -.infinity] {
            let font = DrawingFont.monospaced(ofSize: size, weight: .bold)
            XCTAssertTrue(font.pointSize.isFinite, "size \(size) gave \(font.pointSize)")
            XCTAssertGreaterThan(font.pointSize, 0)
            let measured = ("A" as NSString).size(withAttributes: [.font: font])
            XCTAssertTrue(measured.width.isFinite && measured.height.isFinite)
        }
        XCTAssertEqual(DrawingFont.monospaced(ofSize: .infinity, weight: .bold).pointSize, NSFont.systemFontSize)
    }

    func testNilFromAppKitFallsBackToAUsableFont() {
        var requestedSize: CGFloat?
        let monospaced = DrawingFont.resolve(
            size: 11,
            primary: { requestedSize = $0; return nil },
            monospacedFallback: true
        )
        XCTAssertEqual(requestedSize, 11)
        XCTAssertEqual(monospaced.pointSize, 11)
        XCTAssertTrue(monospaced.isFixedPitch)
        // The fallback must survive the exact CoreText path that aborted in the unit gate.
        let size = ("A" as NSString).size(withAttributes: [.font: monospaced, .foregroundColor: NSColor.white])
        XCTAssertGreaterThan(size.width, 0)

        let proportional = DrawingFont.resolve(size: .nan, primary: { _ in nil }, monospacedFallback: false)
        XCTAssertEqual(proportional.pointSize, NSFont.systemFontSize)
    }

    func testFallbackFontHandlesDegenerateSizes() {
        for monospaced in [true, false] {
            for size: CGFloat in [0, -4, .nan, .infinity] {
                let font = DrawingFont.fallbackFont(ofSize: size, monospaced: monospaced)
                XCTAssertEqual(font.pointSize, NSFont.systemFontSize)
            }
        }
    }

    func testDrawableSize() {
        XCTAssertTrue(DrawingFont.isDrawableSize(6))
        XCTAssertFalse(DrawingFont.isDrawableSize(0))
        XCTAssertFalse(DrawingFont.isDrawableSize(-1))
        XCTAssertFalse(DrawingFont.isDrawableSize(.nan))
        XCTAssertFalse(DrawingFont.isDrawableSize(.infinity))
    }
}
