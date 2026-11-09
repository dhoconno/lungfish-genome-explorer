// ViewerFigureDepthCutoffLineTests.swift - The Depth track's cutoff line, the track fact and the view state's cutoffs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row EXPORT-DEPTH-FILTERS. The parts of the row that need no samtools: the words of the line
// a figure draws under its Depth strip when a cutoff is set, the height that line adds, the track fact's defaults and the
// view-state file, which holds no cutoff key at the defaults so a state at the defaults writes the bytes it wrote before.
// The depths themselves are in `ViewerFigureDepthFiltersConformanceTests`, against `samtools depth` run directly.

import Foundation
@testable import LungfishWorkflow
import XCTest

final class ViewerFigureDepthCutoffLineTests: XCTestCase {
    private func frame(end: Double) -> ViewerFigureFrame {
        ViewerFigureFrame(
            chromosome: "chr1", start: 0, end: end, pixelWidth: 800, sequenceLength: 3_000_000,
            trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
    }

    func testNoLineAtTheDefaults() {
        XCTAssertNil(ViewerFigureDepthTrack.cutoffLines(minMapQ: 0, minBaseQ: 0))
    }

    func testLineNamesOnlyTheCutoffsThatAreSet() throws {
        let both = try XCTUnwrap(ViewerFigureDepthTrack.cutoffLines(minMapQ: 30, minBaseQ: 20))
        XCTAssertEqual(both.full, "Depth counts reads with mapping quality 30 or more and bases with quality 20 or more.")
        XCTAssertEqual(both.short, "Depth: mapping quality 30+, base quality 20+.")
        let mapQ = try XCTUnwrap(ViewerFigureDepthTrack.cutoffLines(minMapQ: 30, minBaseQ: 0))
        XCTAssertEqual(mapQ.full, "Depth counts reads with mapping quality 30 or more.")
        XCTAssertEqual(mapQ.short, "Depth: mapping quality 30+.")
        let baseQ = try XCTUnwrap(ViewerFigureDepthTrack.cutoffLines(minMapQ: 0, minBaseQ: 20))
        XCTAssertEqual(baseQ.full, "Depth counts bases with quality 20 or more.")
        XCTAssertEqual(baseQ.short, "Depth: base quality 20+.")
    }

    func testTrackHeightHoldsTheLineOnlyWhenACutoffIsSetAndTheStripDraws() {
        let drawn = frame(end: 400)
        let plain = ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: drawn)
        let filtered = ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: drawn, minMapQ: 30, minBaseQ: 20)
        XCTAssertTrue(ViewerFigureDepthTrack.draws(at: drawn))
        XCTAssertEqual(filtered.height - plain.height, ViewerFigureReadTrack.overflowBarHeight, "one bar more for the line")
        XCTAssertEqual(
            ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: drawn, minBaseQ: 20).height,
            filtered.height, "a base-quality cutoff alone adds the same line"
        )
        // Above the scale the track reads no depth and draws its note, so a cutoff adds no line.
        let wide = frame(end: 3_000_000)
        XCTAssertFalse(ViewerFigureDepthTrack.draws(at: wide))
        XCTAssertEqual(
            ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: wide, minMapQ: 30, minBaseQ: 20).height,
            ViewerFigureReadTrack.overflowBarHeight
        )
        XCTAssertEqual(filtered.minMapQ, 30)
        XCTAssertEqual(filtered.minBaseQ, 20)
        XCTAssertEqual(plain.minBaseQ, 0)
    }

    func testTrackFactHoldsNoCutoffUnlessGiven() {
        let plain = ViewerGraphicTrackFact(id: "reads", kind: "depth", displayMode: "linear", height: 60)
        XCTAssertNil(plain.minMapQ)
        XCTAssertNil(plain.minBaseQ)
        let set = ViewerGraphicTrackFact(
            id: "reads", kind: "depth", displayMode: "linear", height: 76, minMapQ: 30, minBaseQ: 20
        )
        XCTAssertEqual(set.minMapQ, 30)
        XCTAssertEqual(set.minBaseQ, 20)
        XCTAssertNotEqual(plain, set)
    }

    func testViewStateAtTheDefaultsHoldsNoCutoffKey() throws {
        let text = String(decoding: try ViewerGraphicViewState(readRowCap: 40).encoded(), as: UTF8.self)
        for key in ["readMinMapQ", "depthMinMapQ", "depthMinBaseQ", "hideHighGapSites"] {
            XCTAssertFalse(text.contains(key), "the file holds no \(key) key at the defaults")
        }
        XCTAssertEqual(
            try ViewerGraphicViewState(readRowCap: 40, readMinMapQ: nil, depthMinMapQ: nil, depthMinBaseQ: nil).encoded(),
            try ViewerGraphicViewState(readRowCap: 40).encoded()
        )
    }

    func testViewStateCarriesTheThreeCutoffsThroughItsFile() throws {
        let state = ViewerGraphicViewState(readMinMapQ: 20, depthMinMapQ: 30, depthMinBaseQ: 15)
        let back = try JSONDecoder().decode(ViewerGraphicViewState.self, from: try state.encoded())
        XCTAssertEqual(back, state)
        XCTAssertEqual([back.readMinMapQ, back.depthMinMapQ, back.depthMinBaseQ], [20, 30, 15])
    }
}
