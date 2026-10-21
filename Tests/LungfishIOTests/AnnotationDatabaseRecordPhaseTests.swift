// AnnotationDatabaseRecordPhaseTests.swift - The 5' phase a bundle CDS row carries into its annotation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 R1 to R3, ARCH 4). `AnnotationDatabaseRecord.toAnnotation` is the
// one reader that sets the phase of a bundle CDS, on the interval that is first in transcription order.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class AnnotationDatabaseRecordPhaseTests: XCTestCase {
    /// The `chrR` CDS of the ruling as a database built before the lane stores it. The two GFF3 lines list the 3'
    /// segment first (`3 7`, phase 2) and the 5' segment second (`11 18`, phase 1), so the merged row keeps the first
    /// line's `lungfish_gff_phase=2`, which is the 3' segment's phase.
    static let reverseRowAtTheBase = AnnotationDatabaseRecord(
        rowID: 1, name: "r", type: "CDS", chromosome: "chrR", start: 2, end: 18, strand: "-",
        attributes: "ID=cds-r;Name=r;lungfish_gff_phase=2", blockCount: 2, blockSizes: "5,8", blockStarts: "0,8"
    )

    /// Pin 10 (ARCH 4). A merged CDS row that holds no `lungfish_cds_phase` reads with no phase on any interval, as
    /// it did before the lane, since its `lungfish_gff_phase` is the first line's in file order and not the 5' one.
    func testABundleBuiltBeforeTheLaneReadsAMergedCDSWithoutAPhase() {
        let annotation = Self.reverseRowAtTheBase.toAnnotation()

        XCTAssertEqual(annotation.intervals.map(\.start), [2, 10])
        XCTAssertEqual(annotation.intervals.map(\.end), [7, 18])
        XCTAssertEqual(annotation.intervals.map(\.phase), [nil, nil])
    }
}
