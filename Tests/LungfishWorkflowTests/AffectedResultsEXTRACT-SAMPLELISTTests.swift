// AffectedResultsEXTRACT-SAMPLELISTTests.swift - The affected row of EXTRACT-SCAN-EXTENDED-ID and the kind it speaks of
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17, lane EXTRACT-SAMPLELIST, BIO-THREE-ROWS item 7. From the scan's landing in 3.4 EXTRACT
// (7fc768ba2, build 12824) to Preview 2026.11.11 (13672), Extract Reads could give a TaxTriage sample with no BAM of its
// own another sample's file whose name fits it, even when the result listed that other sample. The record that
// `lungfish extract reads` writes names the classifier in its `tool` option, so the kind keys on that option and never
// on `bamScanNote`, which builds before 03d2d8c3b lack. `ExtractReadsSampleListRefusalTests` holds the kind against a
// record the command's own parts build.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class AffectedResultsExtractSampleListTests: XCTestCase {
    private let backlogID = "EXTRACT-SCAN-EXTENDED-ID"

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: "Lungfish 2026.11.11 (\(build))", kind: kind).map(\.backlogID)
    }

    func testTheExtractScanRowHoldsItsBuilds() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == backlogID })
        XCTAssertEqual(row.kinds, [.taxTriageReadExtraction])
        XCTAssertEqual(row.firstBuild, 12824, "7fc768ba2, the scan's landing in 3.4 EXTRACT")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest published build, lacks the fix")

        XCTAssertEqual(ids(12823, .taxTriageReadExtraction), [])
        XCTAssertEqual(ids(12824, .taxTriageReadExtraction), [backlogID])
        XCTAssertEqual(ids(12859, .taxTriageReadExtraction), [backlogID], "Preview 2026.11.5, the first with the scan")
        XCTAssertEqual(ids(12896, .taxTriageReadExtraction), [backlogID], "03d2d8c3b, the first with bamScanNote")
        XCTAssertEqual(ids(13672, .taxTriageReadExtraction), [backlogID], "Preview 2026.11.11")
        XCTAssertEqual(ids(13673, .taxTriageReadExtraction), [])
        for kind in AffectedResultKind.allCases where kind != .taxTriageReadExtraction {
            XCTAssertFalse(ids(13672, kind).contains(backlogID), "\(kind)")
        }

        XCTAssertEqual(
            row.words,
            "An extraction of a TaxTriage sample whose own BAM was missing may hold another sample's reads. Extract again."
        )
    }

    /// Only a `lungfish extract reads` record whose `tool` option names TaxTriage is the kind. An extraction from
    /// another classifier, one by read ids, which records no tool, and a record of another name are not.
    func testOnlyAnExtractReadsRecordOfATaxTriageResultIsTheKind() {
        func record(_ workflow: String, _ explicit: [String: ParameterValue]) -> ProvenanceEnvelope {
            var record = ProvenanceEnvelope.fixture()
            record.workflowName = workflow
            record.options = ProvenanceOptions(explicit: explicit)
            return record
        }
        let name = AffectedResults.RecordName.extractReads
        XCTAssertEqual(name, "lungfish extract reads")
        XCTAssertEqual(
            AffectedResults.kind(of: record(name, ["tool": .string("taxtriage"), "result": .string("/r")])),
            .taxTriageReadExtraction
        )
        for tool in ["esviritu", "kraken2", "naomgs", "nvd"] {
            XCTAssertNil(AffectedResults.kind(of: record(name, ["tool": .string(tool)])), tool)
        }
        XCTAssertNil(AffectedResults.kind(of: record(name, ["ids": .string("/ids.txt")])), "by read ids")
        XCTAssertNil(AffectedResults.kind(of: record("Classifier Read Extraction", ["tool": .string("taxtriage")])))

        var affected = record(name, ["tool": .string("taxtriage")])
        affected.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)")
        XCTAssertEqual(AffectedResults.rows(for: affected, kind: .taxTriageReadExtraction).map(\.backlogID), [backlogID])
    }
}
