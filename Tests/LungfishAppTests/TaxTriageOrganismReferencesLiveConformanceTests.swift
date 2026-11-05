// TaxTriageOrganismReferencesLiveConformanceTests.swift - Extract Reads of an Influenza row writes its reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The live form of `TaxTriageOrganismReferencesTests` (3.2 lane TTACCESSIONS, BIO F7), with the managed samtools
// (2.9 O5). `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a failure. `build-db taxtriage` runs on the
// `taxtriage-ntc-p` fixture, the viewer opens its database, and the regions its Extract Reads sends for each
// Influenza A row go to the extraction the app runs. An extraction writes a read once, at its primary alignment and
// not marked as a duplicate, so it writes the row's Unique Reads. NTC_1's two records on segment 5 start at the same
// base, and markdup marks one of them, so NTC_1 writes 1 read and patient 2.

import AppKit
import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageOrganismReferencesLiveConformanceTests: XCTestCase {

    /// Red at the base, where the regions name segment 4 alone and the extraction finds no read.
    func testTheRegionsExtractReadsSendsForAnInfluenzaRowHoldItsReads() throws {
        let support = TaxTriageOrganismReferencesTests.self
        try support.offMain { _ = try await ToolAvailability.require("samtools", environment: "samtools") }
        let root = try TestTempDirectory.make(prefix: "TaxTriageOrganismReferencesLive")
        defer { TestTempDirectory.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".lungfish", isDirectory: true), withIntermediateDirectories: true
        )
        let result = try support.offMain { try await support.buildFixture(in: root, standIn: false) }
        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let pane = RecordingAlignmentPane()
        let vc = try TaxTriageOrganismReferencesTests.openViewer(
            on: result, pane: pane, defaults: makeTestDefaultsSuite(prefix: "TaxTriageOrganismReferencesLive").defaults
        )
        var request: ClassifierExtractionRequest?
        vc.resultActions.onExtractionRequested = { request = $0 }

        for (sample, written) in [("NTC_1", 1), ("patient", 2)] {
            request = nil
            _ = try TaxTriageOrganismReferencesTests.selectInfluenzaRow(of: sample, in: vc, pane: pane)
            XCTAssertEqual(pane.requests.last?.contig.name, TaxTriageOrganismReferencesTests.segment5, sample)
            vc.testActionBar.extractButton.performClick(nil)
            let sent = try XCTUnwrap(request, "\(sample): Extract Reads made a request")
            let row = try XCTUnwrap(try database.fetchRows(samples: [sample]).first {
                $0.taxId == TaxTriageOrganismReferencesTests.influenzaTaxID
            })
            XCTAssertEqual(row.uniqueReads, written, "\(sample): the row's Unique Reads")

            let output = root.appendingPathComponent("\(sample)-influenza.fastq")
            // The app sends the batch's database as the result path, and the resolver reads the BAM that the database
            // records for the row's sample, in the sample's own folder (3.2 TTEXTRACT, finding F1 of this lane).
            XCTAssertEqual(sent.resultPath.lastPathComponent, "taxtriage.sqlite", sample)
            let (resultPath, selectors) = (sent.resultPath, sent.selectors)
            let readCount = try support.offMain {
                try await ClassifierReadResolver().resolveAndExtract(
                    tool: .taxtriage,
                    resultPath: resultPath,
                    selections: selectors,
                    options: ExtractionOptions(format: .fastq, includeUnmappedMates: false),
                    destination: .file(output)
                ).readCount
            }
            XCTAssertEqual(readCount, written, "\(sample): the extraction writes the row's Unique Reads")
            let records = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").count / 4
            XCTAssertEqual(records, written, "\(sample): the FASTQ holds them")
        }
    }
}
