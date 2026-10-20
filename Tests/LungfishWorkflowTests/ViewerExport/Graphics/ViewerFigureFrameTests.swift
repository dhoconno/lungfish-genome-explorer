// ViewerFigureFrameTests.swift - The figure frame as a value
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0). The parity with the live class is in LungfishAppWorkflowTests
// (`ViewerFigureFrameParityTests`). These tests hold what the value adds, a width clamp that
// survives a decode, sorted-key encoding and use off the main actor.

import CoreGraphics
import XCTest
@testable import LungfishWorkflow

final class ViewerFigureFrameTests: XCTestCase {
    func testWidthBelowOneClampsToOneAsTheLiveClassDoes() {
        let frame = ViewerFigureFrame(chromosome: "contig_7", start: 0, end: 100, pixelWidth: 0)
        XCTAssertEqual(frame.pixelWidth, 1)
        XCTAssertEqual(frame.dataPixelWidth, 1)
        XCTAssertEqual(frame.scale, 100)
        XCTAssertEqual(frame.sequenceLength, Int.max)
        XCTAssertEqual(frame.leadingInset, 0)
        XCTAssertEqual(frame.trailingInset, 0)
    }

    func testRoundTripKeepsEveryFieldAndEncodesSortedKeys() throws {
        let frame = ViewerFigureFrame(
            chromosome: "MN908947.3", start: 21562, end: 25384, pixelWidth: 1000,
            sequenceLength: 29903, leadingInset: 96, trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frame)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"chromosome":"MN908947.3","end":25384,"leadingInset":96,"pixelWidth":1000,"#
                + #""sequenceLength":29903,"start":21562,"trailingInset":12}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(ViewerFigureFrame.self, from: data), frame)
    }

    func testDecodedWidthBelowOneIsClampedAsABuiltOneIs() throws {
        let json = #"{"chromosome":"c","end":10,"leadingInset":0,"pixelWidth":-5,"sequenceLength":10,"start":0,"trailingInset":0}"#
        let frame = try JSONDecoder().decode(ViewerFigureFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.pixelWidth, 1)
        XCTAssertEqual(frame, ViewerFigureFrame(chromosome: "c", start: 0, end: 10, pixelWidth: -5, sequenceLength: 10))
    }

    func testMapsOffTheMainActor() async {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 1_000_000, end: 1_000_150, pixelWidth: 900)
        let mapped = await Task.detached { () -> (Double, CGFloat) in
            XCTAssertFalse(Thread.isMainThread)
            return (frame.genomicPosition(for: 450), frame.screenPosition(for: 1_000_075))
        }.value
        XCTAssertEqual(mapped.0, 1_000_075)
        XCTAssertEqual(mapped.1, 450)
    }
}
