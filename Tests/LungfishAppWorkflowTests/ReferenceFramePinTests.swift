// ReferenceFramePinTests.swift - Pins the live ReferenceFrame on 20 regions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, QA 1). The viewer figure renderer copies the maths of the
// live `ReferenceFrame`. These pins were committed and passing before the copy
// existed, so the copy is measured against the live values and never against
// itself. Every comparison is exact, since both sides must give the same bits.

import CoreGraphics
import XCTest
import LungfishApp

extension ReferenceFramePinCase {
    var pinRegion: ReferenceFramePinRegion {
        ReferenceFramePinTable.regions[region]
    }

    var label: String {
        "region \(region) (\(pinRegion.name)), insets \(leadingInset) and \(trailingInset)"
    }

    /// The live class set up as the viewer sets it up for this case.
    @MainActor
    func liveFrame() -> ReferenceFrame {
        let frame = ReferenceFrame(
            chromosome: pinRegion.chromosome,
            start: pinRegion.start,
            end: pinRegion.end,
            pixelWidth: pinRegion.pixelWidth,
            sequenceLength: pinRegion.sequenceLength
        )
        frame.leadingInset = CGFloat(leadingInset)
        frame.trailingInset = CGFloat(trailingInset)
        return frame
    }
}

@MainActor
final class ReferenceFramePinTests: XCTestCase {
    func testTableHoldsTwentyRegionsAtEachInsetSetting() {
        let table = ReferenceFramePinTable.self
        XCTAssertEqual(table.regions.count, 20)
        XCTAssertEqual(table.cases.count, table.regions.count * table.insetSettings.count)
        for (index, _) in table.regions.enumerated() {
            let insets = table.cases.filter { $0.region == index }.map { [$0.leadingInset, $0.trailingInset] }
            XCTAssertEqual(insets, table.insetSettings.map { [$0.leading, $0.trailing] }, "region \(index)")
        }
        for pin in table.cases {
            XCTAssertEqual(pin.genomicPositions.count, 4, pin.label)
            XCTAssertEqual(pin.screenPositions.count, 4, pin.label)
        }
    }

    func testDefaultTrailingInsetIsTheTwelvePinnedHere() {
        XCTAssertEqual(ReferenceFrame.defaultTrailingInset, 12)
        XCTAssertEqual(ReferenceFramePinTable.insetSettings[1].trailing, Double(ReferenceFrame.defaultTrailingInset))
    }

    func testLiveReferenceFrameGivesThePinnedValues() {
        for pin in ReferenceFramePinTable.cases {
            let frame = pin.liveFrame()
            XCTAssertEqual(frame.chromosome, pin.pinRegion.chromosome, pin.label)
            XCTAssertEqual(frame.pixelWidth, max(1, pin.pinRegion.pixelWidth), pin.label)
            XCTAssertEqual(Double(frame.dataPixelWidth), pin.dataPixelWidth, pin.label)
            XCTAssertEqual(frame.scale, pin.scale, pin.label)
            for probe in pin.genomicPositions {
                XCTAssertEqual(
                    frame.genomicPosition(for: CGFloat(probe.input)), probe.output,
                    "genomicPosition(for: \(probe.input)), \(pin.label)"
                )
            }
            for probe in pin.screenPositions {
                XCTAssertEqual(
                    Double(frame.screenPosition(for: probe.input)), probe.output,
                    "screenPosition(for: \(probe.input)), \(pin.label)"
                )
            }
        }
    }
}
