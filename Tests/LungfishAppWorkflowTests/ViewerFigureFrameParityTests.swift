// ViewerFigureFrameParityTests.swift - The figure frame against the live ReferenceFrame
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling section 2.2 of ARCH-B10-graphics). `ViewerFigureFrame` copies
// the maths of the live `ReferenceFrame`. On each of the 20 pinned regions, at each inset
// setting, the copy and the live class give the same bits, and both give the pinned literal.

import CoreGraphics
import XCTest
import LungfishApp
import LungfishWorkflow

extension ReferenceFramePinCase {
    func figureFrame() -> ViewerFigureFrame {
        ViewerFigureFrame(
            chromosome: pinRegion.chromosome,
            start: pinRegion.start,
            end: pinRegion.end,
            pixelWidth: pinRegion.pixelWidth,
            sequenceLength: pinRegion.sequenceLength,
            leadingInset: CGFloat(leadingInset),
            trailingInset: CGFloat(trailingInset)
        )
    }
}

@MainActor
final class ViewerFigureFrameParityTests: XCTestCase {
    func testDefaultTrailingInsetMatchesTheLiveClass() {
        XCTAssertEqual(ViewerFigureFrame.defaultTrailingInset, ReferenceFrame.defaultTrailingInset)
    }

    func testCopyAndLiveClassGiveEqualValuesOnTheTwentyRegions() {
        XCTAssertEqual(Set(ReferenceFramePinTable.cases.map(\.region)).count, 20)
        for pin in ReferenceFramePinTable.cases {
            let live = pin.liveFrame()
            let copy = pin.figureFrame()
            XCTAssertEqual(copy.chromosome, live.chromosome, pin.label)
            XCTAssertEqual(copy.start, live.start, pin.label)
            XCTAssertEqual(copy.end, live.end, pin.label)
            XCTAssertEqual(copy.pixelWidth, live.pixelWidth, pin.label)
            XCTAssertEqual(copy.sequenceLength, live.sequenceLength, pin.label)
            XCTAssertEqual(copy.leadingInset, live.leadingInset, pin.label)
            XCTAssertEqual(copy.trailingInset, live.trailingInset, pin.label)
            XCTAssertEqual(copy.dataPixelWidth, live.dataPixelWidth, pin.label)
            XCTAssertEqual(copy.scale, live.scale, pin.label)
            XCTAssertEqual(Double(copy.dataPixelWidth), pin.dataPixelWidth, pin.label)
            XCTAssertEqual(copy.scale, pin.scale, pin.label)
            for probe in pin.genomicPositions {
                let x = CGFloat(probe.input)
                XCTAssertEqual(copy.genomicPosition(for: x), live.genomicPosition(for: x), "x \(x), \(pin.label)")
                XCTAssertEqual(copy.genomicPosition(for: x), probe.output, "x \(x), \(pin.label)")
            }
            for probe in pin.screenPositions {
                let position = probe.input
                XCTAssertEqual(
                    copy.screenPosition(for: position), live.screenPosition(for: position),
                    "position \(position), \(pin.label)"
                )
                XCTAssertEqual(Double(copy.screenPosition(for: position)), probe.output, "position \(position), \(pin.label)")
            }
        }
    }
}
