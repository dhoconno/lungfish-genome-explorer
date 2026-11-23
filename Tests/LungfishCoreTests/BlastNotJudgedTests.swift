// BlastNotJudgedTests.swift - No verdict without a species lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Fix BLAST-FIX m2 of the S1 sweep, ruling UX-BLAST-NOTAX items 1, 2, 4 and 8. A verification gives Supported, Not
// specific, Mixed or Unsupported only when NCBI Taxonomy looked up the row's species (`judgedAt` `.species`) or the
// record predates the field (nil). Judged by the row's own tax ID or by names alone it reads Not judged, and the saved
// hits and marks stay as they are. Tax IDs and organism names are the real rows of the NCBI dump of 2026-10-09.

import XCTest
@testable import LungfishCore

final class BlastNotJudgedTests: XCTestCase {

    private func hit(_ organism: String, taxId: Int?, accession: String) -> BlastHit {
        BlastHit(
            accession: accession,
            title: "\(organism), complete genome",
            organism: organism,
            taxId: taxId,
            hsps: [BlastHSP(bitScore: 140, evalue: 1e-30, identity: 76, alignLength: 76, queryFrom: 1, queryTo: 76)]
        )
    }

    /// A Hepatitis B virus row (10407) whose one read is topped by a Woolly monkey hepatitis B virus record (68416, filed
    /// under Orthohepadnavirus lagothricis). The name rule takes the record by the row's name, as it does with no NCBI
    /// Taxonomy installed, and the result is judged at `basis`.
    private func woollyMonkeyRow(judgedAt basis: BlastTaxonomyContext.Basis?, hits: Bool = true) -> BlastVerificationResult {
        let top = hit("Woolly monkey hepatitis B virus", taxId: 68416, accession: "AF046996.1")
        let rows = BlastService().assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "r1", queryLength: 76, hits: hits ? [top] : [])],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Hepatitis B virus",
            acceptedTaxIds: [10407],
            acceptedTaxonNames: ["Hepatitis B virus"]
        )
        return BlastVerificationResult(
            taxonName: "Hepatitis B virus", taxId: 10407, readResults: rows,
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_600),
            rid: "R", blastProgram: "blastn", database: "core_nt"
        ).judged(at: basis)
    }

    /// Item 8, red at `611610d57`: `.supported`. With no species lookup the read's mark cannot tell another species from
    /// this one, so the badge gives no verdict. The raw value is the one `blast verify --format json` prints.
    func testARowJudgedAtItsOwnTaxIdIsNotJudged() {
        let result = woollyMonkeyRow(judgedAt: .rowTaxId)
        XCTAssertEqual(result.supportingCount, 1, "the read keeps its saved mark")
        XCTAssertEqual(result.confidence.rawValue, "notJudged")
    }

    /// Item 8, red at `611610d57`: `.supported`. A row with no tax ID is judged by names alone.
    func testARowJudgedByNamesIsNotJudged() {
        XCTAssertEqual(woollyMonkeyRow(judgedAt: .names).confidence.rawValue, "notJudged")
    }

    /// Guards, green before and after: a lineage-backed verdict keeps its badge, and so does a record from before the
    /// field, which ruling D's affected row covers.
    func testASpeciesLevelRowAndAnOlderRecordKeepTheirBadge() {
        XCTAssertEqual(woollyMonkeyRow(judgedAt: .species).confidence, .supported)
        XCTAssertEqual(woollyMonkeyRow(judgedAt: nil).confidence, .supported, "a record from before the field")
    }

    /// Guard, green before and after: with no significant hit there is nothing to judge, and the badge reads Inconclusive.
    func testARowWithNoSignificantHitStaysInconclusive() {
        let result = woollyMonkeyRow(judgedAt: .rowTaxId, hits: false)
        XCTAssertEqual(result.supportingCount + result.contradictingCount, 0)
        XCTAssertEqual(result.confidence, .inconclusive)
    }

    /// Guard, green before and after: nothing on disk changes. A record judged at the row's tax ID keeps the raw value
    /// `rowTaxId`, which an older build decodes, and its read keeps its saved mark.
    func testARecordJudgedAtTheRowsTaxIdRoundTripsWithItsRawValue() throws {
        let saved = woollyMonkeyRow(judgedAt: .rowTaxId)
        let data = try JSONEncoder().encode(saved)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""judgedAt":"rowTaxId""#), text)

        let reopened = try JSONDecoder().decode(BlastVerificationResult.self, from: data)
        XCTAssertEqual(reopened.judgedAt, .rowTaxId)
        XCTAssertEqual(reopened.readResults.first?.matchesQueriedTaxon, true)
        XCTAssertEqual(reopened.confidence, saved.confidence)
        XCTAssertEqual(BlastTaxonomyContext.Basis(rawValue: "rowTaxId"), .rowTaxId)
        XCTAssertEqual(BlastTaxonomyContext.Basis(rawValue: "names"), .names)
    }
}
