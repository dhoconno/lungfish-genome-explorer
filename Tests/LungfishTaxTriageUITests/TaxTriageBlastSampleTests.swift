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

    /// The selection moves to the other sample between the request and the re-run, and the re-run still names the
    /// sample of the request it repeats.
    func testTheDrawerRerunNamesTheSampleOfTheLastRequest() throws {
        let fixture = try TaxTriageBlastFixture()
        defer { fixture.cleanUp() }

        try fixture.request(organism: "Gamma virus", sample: "sample-2")
        try fixture.select(organism: "Alpha virus", sample: "sample-1")
        try fixture.rerun(taxonName: "Gamma virus", taxId: 2001)

        XCTAssertEqual(fixture.forwarded.map { $0.organism.sample }, ["sample-2", "sample-2"])
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
