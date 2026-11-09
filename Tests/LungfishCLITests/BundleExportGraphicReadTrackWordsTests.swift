// BundleExportGraphicReadTrackWordsTests.swift - The read track's zoom fact has its own words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row W7-COVERAGE-TIER-FACT (S3, UX). The CLI read the read track's `scaleMode` fact as "drew a
// summary at this zoom", the words of the sequence track and the annotation track, which draw a summary. The read track
// draws no reads at the coverage tier and a line in their place, and the Depth track above it draws the strip. The
// reads' own fact now says it left reads out, and the sequence and annotation facts keep their words.

import Foundation
@testable import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicReadTrackWordsTests: XCTestCase {
    func testReadTrackFactSaysItLeftReadsOutAndOtherTracksKeepTheirSummaryWords() {
        let coverageTier = ViewerFigureOmission(
            trackID: "reads", kind: .scaleMode, reason: "reads and mismatch marks above 2 bases per point", count: 1234
        )
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(coverageTier),
            "The reads track left out reads at this zoom (reads and mismatch marks above 2 bases per point, 1234 left out)."
        )
        let narrow = ViewerFigureOmission(trackID: "reads", kind: .scaleMode, reason: "reads narrower than 2 points", count: 7)
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(narrow),
            "The reads track left out reads at this zoom (reads narrower than 2 points, 7 left out)."
        )
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(coverageTier, image: "chr1.png"),
            "In chr1.png, the reads track left out reads at this zoom "
                + "(reads and mismatch marks above 2 bases per point, 1234 left out)."
        )

        let sequence = ViewerFigureOmission(
            trackID: ViewerFigureSequenceTrack.trackID, kind: .scaleMode,
            reason: "bases drawn as a bar at 12.5 bases per point, 10 or more", count: 400
        )
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(sequence),
            "The \(ViewerFigureSequenceTrack.trackID) track drew a summary at this zoom "
                + "(bases drawn as a bar at 12.5 bases per point, 10 or more, 400 left out)."
        )
        let annotation = ViewerFigureOmission(trackID: "genes", kind: .scaleMode, reason: "region features span the view", count: 3)
        XCTAssertEqual(
            BundleExportGraphicRecord.warning(annotation),
            "The genes track drew a summary at this zoom (region features span the view, 3 left out)."
        )
        XCTAssertFalse(BundleExportGraphicRecord.warns(coverageTier), "the fact stays a note, as UX 2 set it")
    }
}
