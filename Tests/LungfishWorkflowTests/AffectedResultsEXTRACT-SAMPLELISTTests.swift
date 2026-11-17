// AffectedResultsEXTRACT-SAMPLELISTTests.swift - The affected row of EXTRACT-SCAN-EXTENDED-ID and the kind it speaks of
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17, lane EXTRACT-SAMPLELIST, BIO-THREE-ROWS item 7, moved by the BIO review of the lane (B1 and B2).
// From the first scan of `minimap2/` (bfd396f81, build 1085) to Preview 2026.11.11 (13672), Extract Reads could give a
// TaxTriage sample with no BAM of its own another sample's file whose name fits it, even when the result listed that
// other sample. 7fc768ba2 (build 12824) narrowed the older scan, which took any BAM that began with the sample id and
// said nothing. The kind keys on the classifier that an extraction names and never on `bamScanNote`, which builds
// before 03d2d8c3b lack. `lungfish extract reads` and the File destination of the app name the classifier in the `tool`
// option, and the Bundle destination of the app records it as the tool name of the record. `ExtractReadsSampleListRefusalTests`
// holds the kind against a record the command's own parts build, the last test below against the bundle record that the
// writer of the app made, and `AffectedResultsExtractSampleListAppRecordTests` against the file record of the app.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class AffectedResultsExtractSampleListTests: XCTestCase {
    private let backlogID = "EXTRACT-SCAN-EXTENDED-ID"

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: "Lungfish 2026.11.11 (\(build))", kind: kind).map(\.backlogID)
    }

    func testTheExtractScanRowHoldsItsBuilds() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == backlogID })
        XCTAssertEqual(row.kinds, [.taxTriageReadExtraction])
        XCTAssertEqual(
            row.firstBuild, 1085, "bfd396f81, which began the scan of minimap2/ for any BAM that starts with the sample id"
        )
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest published build, lacks the fix")

        XCTAssertEqual(ids(1084, .taxTriageReadExtraction), [])
        XCTAssertEqual(ids(1085, .taxTriageReadExtraction), [backlogID])
        XCTAssertEqual(ids(4192, .taxTriageReadExtraction), [backlogID], "Preview 2026.8.1, the first published release")
        XCTAssertEqual(ids(12045, .taxTriageReadExtraction), [backlogID], "Stable 2026.10.29")
        XCTAssertEqual(ids(12823, .taxTriageReadExtraction), [backlogID], "the build before the narrowed scan")
        XCTAssertEqual(ids(12824, .taxTriageReadExtraction), [backlogID])
        XCTAssertEqual(ids(12859, .taxTriageReadExtraction), [backlogID], "Preview 2026.11.5, the first with the narrowed scan")
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

    /// Only a read extraction record whose classifier is TaxTriage is the kind. An extraction from another classifier,
    /// one by read ids, which records no tool, and a record of another name are not. The bundle record of the app names
    /// the classifier as its tool name instead, which the test against the record of the writer holds.
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
        XCTAssertEqual(
            AffectedResults.kind(of: record("Classifier Read Extraction", ["tool": .string("taxtriage")])),
            .taxTriageReadExtraction, "the bundle of `lungfish extract reads --bundle` names the tool option too"
        )
        XCTAssertNil(AffectedResults.kind(of: record("Classifier Read Extraction", ["tool": .string("esviritu")])))

        var affected = record(name, ["tool": .string("taxtriage")])
        affected.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)")
        XCTAssertEqual(AffectedResults.rows(for: affected, kind: .taxTriageReadExtraction).map(\.backlogID), [backlogID])
    }

    /// The bundle record of the app. The Bundle destination of the Extract Reads sheet builds its metadata with the display
    /// name of the classifier as the tool name and no `tool` parameter (`TaxonomyReadExtractionAction.swift:414-416`), and
    /// `ReadExtractionService.createBundle` writes the record (`ReadExtractionService.swift:978`). This is the record that
    /// writer made, with no samtools. Red at the base, where the kind knows no such record.
    func testTheBundleRecordOfTheAppForATaxTriageExtractionIsTheKind() async throws {
        let cases: [(ClassifierTool, AffectedResultKind?)] = [(.taxtriage, .taxTriageReadExtraction), (.esviritu, nil)]
        for (tool, expected) in cases {
            let root = try TestTempDirectory.make(prefix: "AffectedExtractBundle")
            defer { TestTempDirectory.cleanup(root) }
            let fastq = root.appendingPathComponent("selected.fastq")
            try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
            let metadata = ExtractionMetadata(
                sourceDescription: "x", toolName: tool.displayName,
                parameters: ["resultPath": root.path, "format": "fastq"]
            )
            let bundle = try await ReadExtractionService().createBundle(
                from: ExtractionResult(fastqURLs: [fastq], readCount: 1, pairedEnd: false),
                sourceName: "x", selectionDescription: "extract", metadata: metadata, in: root
            )
            let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
            XCTAssertEqual(record.workflowName, AffectedResults.RecordName.classifierReadExtraction, "\(tool)")
            XCTAssertEqual(AffectedResults.kind(of: record), expected, "\(tool)")
        }
    }
}
