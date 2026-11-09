// ViewerGraphicsExportCutoffsTests.swift - The cutoffs the app writes into the view-state file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row EXPORT-DEPTH-FILTERS. The window fetches its reads at `minMapQSetting` alone and counts
// its depth at the larger of that and `consensusMinMapQSetting`, with `consensusMinBaseQSetting`
// (`SequenceViewerView+Alignment.swift:40,360-361,696`). The app writes those three numbers, nil at 0, so the figure's
// reads and depth are the window's and a window at the defaults writes the file it wrote before.

import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class ViewerGraphicsExportCutoffsTests: XCTestCase {
    func testReadsTakeTheirOwnMappingQualityAndDepthTakesTheLargerOne() {
        let consensusLarger = AppDelegate.viewerGraphicsExportCutoffs(minMapQ: 20, consensusMinMapQ: 30, consensusMinBaseQ: 0)
        XCTAssertEqual(consensusLarger.readMinMapQ, 20)
        XCTAssertEqual(consensusLarger.depthMinMapQ, 30)
        XCTAssertNil(consensusLarger.depthMinBaseQ)
        let windowLarger = AppDelegate.viewerGraphicsExportCutoffs(minMapQ: 40, consensusMinMapQ: 10, consensusMinBaseQ: 25)
        XCTAssertEqual(windowLarger.readMinMapQ, 40)
        XCTAssertEqual(windowLarger.depthMinMapQ, 40)
        XCTAssertEqual(windowLarger.depthMinBaseQ, 25)
    }

    func testConsensusMappingQualityAloneReachesTheDepthAndNotTheReads() {
        let cutoffs = AppDelegate.viewerGraphicsExportCutoffs(minMapQ: 0, consensusMinMapQ: 30, consensusMinBaseQ: 0)
        XCTAssertNil(cutoffs.readMinMapQ)
        XCTAssertEqual(cutoffs.depthMinMapQ, 30)
    }

    func testWindowAtTheDefaultsWritesTheFileItWroteBefore() throws {
        let cutoffs = AppDelegate.viewerGraphicsExportCutoffs(minMapQ: 0, consensusMinMapQ: 0, consensusMinBaseQ: 0)
        XCTAssertNil(cutoffs.readMinMapQ)
        XCTAssertNil(cutoffs.depthMinMapQ)
        XCTAssertNil(cutoffs.depthMinBaseQ)
        let made = ViewerGraphicViewState(
            readMinMapQ: cutoffs.readMinMapQ, depthMinMapQ: cutoffs.depthMinMapQ, depthMinBaseQ: cutoffs.depthMinBaseQ
        )
        XCTAssertEqual(try made.encoded(), try ViewerGraphicViewState().encoded())
    }

    func testNegativeSettingsAreTheDefaults() {
        let cutoffs = AppDelegate.viewerGraphicsExportCutoffs(minMapQ: -5, consensusMinMapQ: -1, consensusMinBaseQ: -3)
        XCTAssertNil(cutoffs.readMinMapQ)
        XCTAssertNil(cutoffs.depthMinMapQ)
        XCTAssertNil(cutoffs.depthMinBaseQ)
    }
}
