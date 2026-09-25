// SequenceViewerBaseLetterGeometryTests.swift - Base-letter drawing under degenerate geometry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Regression for the unit-gate abort in drawBaseLevelSequence
// ("attempt to insert nil object from objects[0]" from CoreText's attribute copy). Letters
// must be skipped when the cell geometry is not finite, and drawing a sequence with NaN,
// infinite or zero geometry must complete without touching CoreText with a bad font.

import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class SequenceViewerBaseLetterGeometryTests: XCTestCase {
    func testLetterFontSizeMatchesTheHistoricalFormulaForNormalGeometry() {
        // 20 px per base in a 40 pt track: min(15, 32) = 15.
        XCTAssertEqual(SequenceViewerView.baseLetterFontSize(pixelsPerBase: 20, trackHeight: 40), 15)
        // Track-height bound: min(75, 16) = 16.
        XCTAssertEqual(SequenceViewerView.baseLetterFontSize(pixelsPerBase: 100, trackHeight: 20), 16)
        // Too narrow or too short: no letters.
        XCTAssertNil(SequenceViewerView.baseLetterFontSize(pixelsPerBase: 7.9, trackHeight: 40))
        XCTAssertNil(SequenceViewerView.baseLetterFontSize(pixelsPerBase: 20, trackHeight: 7))
    }

    func testLetterFontSizeIsNilForNonFiniteOrZeroGeometry() {
        let cases: [(CGFloat, CGFloat)] = [
            (.nan, 40), (20, .nan), (.nan, .nan),
            (.infinity, .infinity), (.infinity, 40), (20, .infinity),
            (0, 40), (20, 0), (0, 0), (-.infinity, 40),
        ]
        for (ppb, height) in cases {
            let size = SequenceViewerView.baseLetterFontSize(pixelsPerBase: ppb, trackHeight: height)
            XCTAssertNil(size, "ppb \(ppb) height \(height) gave \(String(describing: size))")
        }
    }

    func testDrawBaseLevelSequenceSurvivesDegenerateGeometry() throws {
        let sequence = try Sequence(name: "chr1", alphabet: .dna, bases: "ACGTACGTACGTACGT")
        let geometries: [(trackHeight: CGFloat, trailingInset: CGFloat)] = [
            (.infinity, -.infinity),   // infinite cell width and height
            (.nan, 0),                 // NaN track height
            (0, 0),                    // zero-height track
            (40, .nan),                // NaN data width collapses to the 1 px floor
            (40, 0),                   // normal geometry, letters drawn
        ]
        for geometry in geometries {
            let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
            view.trackHeight = geometry.trackHeight
            let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 16, pixelWidth: 320, sequenceLength: 16)
            frame.trailingInset = geometry.trailingInset

            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            view.drawBaseLevelSequence(sequence, frame: frame, context: graphics.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
