// BundleExportGraphicTrackEntryTests.swift - The record's track entry states the cutoffs a track drew under
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row EXPORT-DEPTH-FILTERS (BIO, UX). The record's `resolved.tracks` held each track's id, kind,
// display mode and height only. A depth fact now holds the mapping-quality and base-quality cutoffs its depth counted at
// and an alignment fact the mapping quality its reads were fetched at, as integers and only when set, so a record at the
// defaults holds the four keys it always held.

import Foundation
@testable import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicTrackEntryTests: XCTestCase {
    func testTrackEntryAtTheDefaultsHoldsTheFourKeysItAlwaysHeld() {
        let fact = ViewerGraphicTrackFact(id: "reads", kind: "depth", displayMode: "linear", height: 60)
        XCTAssertEqual(
            BundleExportGraphicRecord.trackEntry(fact),
            .dictionary([
                "id": .string("reads"), "kind": .string("depth"), "displayMode": .string("linear"), "height": .number(60),
            ])
        )
    }

    func testTrackEntryAddsTheCutoffsAsIntegersOnlyWhenSet() {
        let depth = ViewerGraphicTrackFact(
            id: "reads", kind: "depth", displayMode: "linear", height: 76, minMapQ: 30, minBaseQ: 20
        )
        XCTAssertEqual(
            BundleExportGraphicRecord.trackEntry(depth),
            .dictionary([
                "id": .string("reads"), "kind": .string("depth"), "displayMode": .string("linear"), "height": .number(76),
                "minMapQ": .integer(30), "minBaseQ": .integer(20),
            ])
        )
        let reads = ViewerGraphicTrackFact(id: "reads", kind: "alignment", displayMode: "packed", height: 200, minMapQ: 10)
        XCTAssertEqual(
            BundleExportGraphicRecord.trackEntry(reads),
            .dictionary([
                "id": .string("reads"), "kind": .string("alignment"), "displayMode": .string("packed"),
                "height": .number(200), "minMapQ": .integer(10),
            ])
        )
    }
}
