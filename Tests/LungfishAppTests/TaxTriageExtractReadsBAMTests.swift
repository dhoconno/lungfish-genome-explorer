// TaxTriageExtractReadsBAMTests.swift - Extract Reads on a TaxTriage batch finds the BAM of the row's own sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTEXTRACT (finding F1 of lane TTACCESSIONS, S2). The viewer sends the batch's database as the result
// path, and the resolver looked for `minimap2/` beside it, where an app-made batch keeps `<sample>/minimap2/` instead.
// The request the app sends for the Influenza A row of NTC_1 and of patient on the NTC-P fixture (`taxtriage-ntc-p`)
// must resolve to that sample's BAM, from the toolbar's Extract button and from the batch table's own Extract Reads
// command, which both end in the same request. The stand-in samtools builds the database, and the resolver's layout
// lookup needs no samtools. The live form, which writes the reads, is
// `TaxTriageOrganismReferencesLiveConformanceTests`.

import AppKit
import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishIO
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageExtractReadsBAMTests: XCTestCase {

    /// Red at the base, where the lookup throws `bamNotFound(sampleId:)` for each request.
    func testExtractReadsOfAnInfluenzaRowFindsTheBAMOfItsOwnSample() throws {
        let support = TaxTriageOrganismReferencesTests.self
        let root = try TestTempDirectory.make(prefix: "TaxTriageExtractReadsBAM")
        defer { TestTempDirectory.cleanup(root) }
        let result = try support.offMain { try await support.buildFixture(in: root, standIn: true) }
        let pane = RecordingAlignmentPane()
        let vc = try support.openViewer(
            on: result, pane: pane, defaults: makeTestDefaultsSuite(prefix: "TaxTriageExtractReadsBAM").defaults
        )
        var request: ClassifierExtractionRequest?
        vc.resultActions.onExtractionRequested = { request = $0 }

        for sample in ["NTC_1", "patient"] {
            // One selection serves both routes, since selecting the row again changes nothing and opens nothing.
            _ = try support.selectInfluenzaRow(of: sample, in: vc, pane: pane)
            for byButton in [true, false] {
                let label = "\(sample) by \(byButton ? "the Extract button" : "the batch table's Extract Reads command")"
                request = nil
                if byButton {
                    vc.testActionBar.extractButton.performClick(nil)
                } else {
                    vc.testBatchFlatTableView.extractReadsForSelectedRows(nil)
                }
                let sent = try XCTUnwrap(request, "\(label): Extract Reads made a request")
                XCTAssertEqual(sent.selectors.map(\.sampleId), [sample], label)
                XCTAssertEqual(sent.resultPath.lastPathComponent, "taxtriage.sqlite", "\(label): the app sends the batch's database")

                let (path, named) = (sent.resultPath, sample)
                let found = try support.offMain {
                    try await ClassifierReadResolver().testingResolveBAMURL(tool: .taxtriage, sampleId: named, resultPath: path)
                }
                let expected = result.appendingPathComponent("\(sample)/minimap2/\(sample).\(sample).dwnld.references.bam")
                XCTAssertEqual(
                    found.resolvingSymlinksInPath().path, expected.resolvingSymlinksInPath().path,
                    "\(label): the BAM in the sample's own folder"
                )
            }
        }
    }
}
