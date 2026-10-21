// TaxTriageBlastRerunTests.swift - The BLAST drawer's re-run searches the reads of the request it repeats
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2.12 lane 12.09b (review 12.09, Ruling 1 and note 1). The drawer's re-run used to send the BAM the result view
// holds now. In a result of several samples a changed selection between the request and the re-run could send
// another sample's reads, or none, since the view holds no BAM until a sample is picked. The view keeps the BAM of
// the last request, and the re-run sends it.

import LungfishTestSupport
import XCTest
import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishTaxTriageUI

/// A two-sample TaxTriage result in the database form every production result opens in, and the BLAST requests its
/// result view forwards to the host.
@MainActor
final class TaxTriageBlastFixture {
    typealias Forwarded = (organism: TaxTriageOrganism, readCount: Int, accessions: [String]?, bamURL: URL?, bamIndexURL: URL?)

    static let samples = ["sample-1", "sample-2"]

    let root: URL
    lazy var controller: TaxTriageResultViewController = { let view = TaxTriageResultViewController(); view.layoutDefaults = TestDefaultsSuite(prefix: "TaxTriageBlastRerunTests").defaults; return view }()
    private(set) var forwarded: [Forwarded] = []
    private var runPopover: ((Int) -> Void)?

    /// - Parameter extraGammaAccession: When given, sample-2 holds a second organism under tax ID 2001 with this
    ///   accession. The database form builds its accession maps from the rows, so the tax ID map of sample-2 then
    ///   gives 2001 two accessions where the name map gives `Gamma virus` one.
    init(extraGammaAccession: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageBlast-\(UUID().uuidString)", isDirectory: true)
        for sample in Self.samples {
            let folder = root.appendingPathComponent("\(sample)/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("\(sample).bam"))
            try Data().write(to: folder.appendingPathComponent("\(sample).bam.bai"))
        }
        var rows = [
            Self.row(sample: "sample-1", organism: "Alpha virus", taxId: 1001, accession: "NC_1001"),
            Self.row(sample: "sample-2", organism: "Gamma virus", taxId: 2001, accession: "NC_2001"),
        ]
        if let extraGammaAccession {
            rows.append(Self.row(sample: "sample-2", organism: "Gamma virus subtype B", taxId: 2001, accession: extraGammaAccession))
        }
        let database = try TaxTriageDatabase.create(
            at: root.appendingPathComponent("taxtriage.sqlite"),
            rows: rows,
            metadata: ["tool": "taxtriage"]
        )
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: root)
        controller.onBlastVerification = { [weak self] organism, readCount, accessions, bamURL, bamIndexURL in
            self?.forwarded.append((organism, readCount, accessions, bamURL, bamIndexURL))
        }
        controller.blastConfigPopoverPresenter = { [weak self] _, _, _, onRun in self?.runPopover = onRun }
        // A ceiling, not a speed check: the rows load on a detached task and the loop returns as soon as they show.
        let deadline = Date().addingTimeInterval(60)
        while controller.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.testBatchFlatTableView.displayedRows.count, rows.count, "the rows did not load")
    }

    func bamURL(for sample: String) -> URL {
        root.appendingPathComponent("\(sample)/minimap2/\(sample).bam")
    }

    /// Selects the flat table's row of `organism` in `sample`.
    func select(organism: String, sample: String) throws {
        let index = try XCTUnwrap(
            controller.testBatchFlatTableView.displayedRows.firstIndex { $0.organism == organism && $0.sample == sample }
        )
        controller.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(index)
    }

    /// Picks `sample` in the result view's sample filter, so the view holds that sample's BAM. The database form
    /// routes a pick to the Inspector's filter and holds no BAM at all, since `bamURL` is assigned only by the filter
    /// that the batch-group flag bypasses. The helper turns the flag off and picks, as the form that holds a BAM does.
    /// A request or a re-run after it can then tell the BAM of its own sample from the BAM the view holds.
    func pick(sample: String) throws {
        controller.isBatchGroupMode = false
        let segment = try XCTUnwrap(Self.samples.firstIndex(of: sample), "the fixture has no \(sample)") + 1
        let control = controller.testSampleFilterControl
        control.selectedSegment = segment
        _ = control.sendAction(control.action, to: control.target)
    }

    /// BLAST Verify on the row, as the action bar does it. The bar opens the read-count popover and the user runs
    /// it with 20 reads.
    func request(organism: String, sample: String) throws {
        try select(organism: organism, sample: sample)
        runPopover = nil
        controller.testActionBar.blastButton.performClick(nil)
        let run = try XCTUnwrap(runPopover, "BLAST Verify opens the read-count popover")
        run(20)
    }

    /// The drawer's Re-run button, once the drawer shows the result of the last request.
    func rerun(taxonName: String, taxId: Int) throws {
        let drawer = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? BlastResultsDrawerTab }.first,
            "the result view holds its BLAST drawer"
        )
        controller.showBlastResults(
            BlastVerificationResult(
                taxonName: taxonName, taxId: taxId, readResults: [], submittedAt: Date(), completedAt: Date(),
                rid: "RID0001", blastProgram: "megablast", database: "core_nt"
            ),
            recordURL: nil
        )
        let rerun = try XCTUnwrap(drawer.onRerunBlast, "the drawer offers Re-run")
        rerun()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func row(sample: String, organism: String, taxId: Int, accession: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
            primaryAccession: accession, accessionLength: 10_000
        )
    }
}

@MainActor
final class TaxTriageBlastRerunTests: XCTestCase {

    /// Each flat-table request sends the BAM of its row's sample, the pin the re-run test below builds on.
    func testTheFlatTableRequestSendsTheBAMOfItsRowsSample() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Alpha virus", sample: "sample-1")
        try fixture.request(organism: "Gamma virus", sample: "sample-2")

        XCTAssertEqual(fixture.forwarded.map { $0.organism.name }, ["Alpha virus", "Gamma virus"])
        XCTAssertEqual(fixture.forwarded.map { $0.bamURL }, [fixture.bamURL(for: "sample-1"), fixture.bamURL(for: "sample-2")])
    }

    /// Review 12.09, note 1. The view holds sample-1's BAM by the time of the re-run, since the user picked that
    /// sample after the request. The re-run still searches the BAM and index of the request it repeats (sample-2's).
    /// A re-run that sent the BAM the view holds would send the reads of another sample (review 12.09b, Fix 3).
    func testTheDrawerRerunSearchesTheBAMOfTheLastRequestNotTheOneTheViewHoldsNow() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Gamma virus", sample: "sample-2")
        let first = try XCTUnwrap(fixture.forwarded.last)
        XCTAssertEqual(first.bamURL, fixture.bamURL(for: "sample-2"))
        XCTAssertNotNil(first.bamIndexURL, "the fixture's BAM has its index beside it")

        try fixture.pick(sample: "sample-1")
        try fixture.rerun(taxonName: "Gamma virus", taxId: 2001)

        XCTAssertEqual(fixture.forwarded.count, 2, "the re-run reaches the host")
        let rerun = try XCTUnwrap(fixture.forwarded.last)
        XCTAssertEqual(rerun.organism.name, "Gamma virus")
        XCTAssertEqual(rerun.organism.sample, "sample-2", "the re-run names the sample of the request it repeats")
        XCTAssertEqual(rerun.bamURL, first.bamURL, "the re-run searches the BAM of the request it repeats")
        XCTAssertNotEqual(rerun.bamURL, fixture.bamURL(for: "sample-1"), "the re-run does not send the BAM the view holds")
        XCTAssertEqual(rerun.bamIndexURL, first.bamIndexURL)
    }

    /// Review 12.09b, Fix 4. The first request takes its accessions from the tax ID map before the name map, so the two
    /// lists can differ for one organism. Sample-2 holds tax ID 2001 under two organisms, so its tax ID map gives 2001
    /// two accessions and its name map gives `Gamma virus` one. The re-run sends the list of the request it repeats
    /// and does not look the organism up by name again.
    func testTheDrawerRerunSendsTheAccessionsOfTheLastRequest() throws {
        let fixture = try TaxTriageBlastFixture(extraGammaAccession: "NC_2002")
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Gamma virus", sample: "sample-2")
        let first = try XCTUnwrap(fixture.forwarded.last)
        XCTAssertEqual(first.accessions?.count, 2, "the tax ID map gives 2001 two accessions")

        try fixture.pick(sample: "sample-1")
        try fixture.rerun(taxonName: "Gamma virus", taxId: 2001)

        XCTAssertEqual(fixture.forwarded.count, 2, "the re-run reaches the host")
        let rerun = try XCTUnwrap(fixture.forwarded.last)
        XCTAssertEqual(rerun.accessions, first.accessions, "the re-run sends the accessions of the request it repeats")
    }
}
