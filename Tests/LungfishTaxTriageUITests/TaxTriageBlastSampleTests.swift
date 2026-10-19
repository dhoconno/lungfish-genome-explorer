// TaxTriageBlastSampleTests.swift - A TaxTriage BLAST request names the sample whose reads it searches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2.12 lane 12.09b (review 12.09, Ruling 1). The result view puts the sample on the organism of every BLAST request
// it forwards, so the host can record it. The sample is the one whose BAM goes with the request, and the drawer's
// re-run names the sample of the request it repeats. `TaxTriageBlastRerunTests` holds the BAM half of the same flows.

import XCTest
import LungfishIO
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageBlastSampleTests: XCTestCase {

    func testTheFlatTableRequestNamesTheSampleOfItsRow() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Alpha virus", sample: "sample-1")
        try fixture.request(organism: "Gamma virus", sample: "sample-2")

        XCTAssertEqual(fixture.forwarded.map { $0.organism.sample }, ["sample-1", "sample-2"])
    }

    /// The view holds sample-1's BAM by the time of the re-run, since the user picked that sample after the request.
    /// The re-run still names the sample of the request it repeats (sample-2), not the owner of the BAM held now.
    func testTheDrawerRerunNamesTheSampleOfTheLastRequest() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Gamma virus", sample: "sample-2")
        try fixture.pick(sample: "sample-1")
        try fixture.rerun(taxonName: "Gamma virus", taxId: 2001)

        XCTAssertEqual(fixture.forwarded.map { $0.organism.sample }, ["sample-2", "sample-2"])
        let rerun = try XCTUnwrap(fixture.forwarded.last)
        XCTAssertEqual(rerun.organism.sample, "sample-2")
        XCTAssertNotEqual(rerun.bamURL, fixture.bamURL(for: "sample-1"), "the re-run does not send the BAM the view holds")
    }

    /// The organism table sends the BAM of the sample picked in the view and names the sample that owns it. The
    /// owner rule is pinned apart below. This pins the call that puts it on the request, which nothing covered, since
    /// deleting the `sample:` argument of the organism-table request left every other test green (review 12.09b, Fix 3).
    /// The request enters through the table's own BLAST callback, so no row selection loads the fixture's empty BAM.
    func testTheOrganismTableRequestNamesTheSampleThatOwnsTheBAMItSends() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.pick(sample: "sample-2")
        let row = TaxTriageTableRow(organism: "Gamma virus", tassScore: 0.9, reads: 20, uniqueReads: 10, taxId: 2001)
        fixture.controller.testOrganismTableView.onBlastRequested?(row, 20)

        let request = try XCTUnwrap(fixture.forwarded.last, "the organism table's request reaches the host")
        XCTAssertEqual(request.organism.name, "Gamma virus")
        XCTAssertEqual(request.bamURL, fixture.bamURL(for: "sample-2"), "the view holds the BAM of the sample it picked")
        XCTAssertEqual(request.organism.sample, "sample-2")
    }

    /// The organism table sends the BAM the view holds, so it names the sample that BAM belongs to. A BAM that no
    /// sample owns, or that several share, names none, since a record must not name a sample whose reads it
    /// did not search.
    func testASampleIsNamedOnlyByTheBAMItOwns() {
        let first = URL(fileURLWithPath: "/result/s1.bam")
        let shared = URL(fileURLWithPath: "/result/shared.bam")
        let owners = ["S1": first, "S2": shared, "S3": shared]

        XCTAssertEqual(TaxTriageResultViewController.sample(owning: first, in: owners), "S1")
        XCTAssertNil(TaxTriageResultViewController.sample(owning: shared, in: owners), "two samples share it")
        XCTAssertNil(TaxTriageResultViewController.sample(owning: URL(fileURLWithPath: "/result/other.bam"), in: owners))
        XCTAssertNil(TaxTriageResultViewController.sample(owning: nil, in: owners))
    }

    /// An organism without a sample encodes as it always did, and one with a sample keeps it.
    func testAnOrganismWithoutASampleEncodesWithNoSampleKey() throws {
        let plain = TaxTriageOrganism(name: "Influenza A virus", score: 0.9, reads: 100, coverage: 50, taxId: 11320, rank: "species")
        XCTAssertNil(plain.sample)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("sample"), plainJSON)
        XCTAssertEqual(try JSONDecoder().decode(TaxTriageOrganism.self, from: Data(plainJSON.utf8)), plain)

        let named = TaxTriageOrganism(
            name: "Influenza A virus", score: 0.9, reads: 100, coverage: 50, taxId: 11320, rank: "species", sample: "S1"
        )
        let namedJSON = try JSONEncoder().encode(named)
        XCTAssertEqual(try JSONDecoder().decode(TaxTriageOrganism.self, from: namedJSON).sample, "S1")
    }
}
