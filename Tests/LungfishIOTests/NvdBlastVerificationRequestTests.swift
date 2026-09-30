// NvdBlastVerificationRequestTests.swift - NVD contig BLAST judged against the NVD classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO

final class NvdBlastVerificationRequestTests: XCTestCase {

    private func nvdHit(
        sscinames: String = "Severe acute respiratory syndrome coronavirus 2",
        staxids: String = "2697049"
    ) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "100", blastTask: "megablast", sampleId: "SampleA",
            qseqid: "NODE_1_length_500_cov_10.0", qlen: 500,
            sseqid: "MN908947.3", stitle: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1",
            taxRank: "species:SARS-CoV-2", length: 500, pident: 99.8, evalue: 0, bitscore: 919,
            sscinames: sscinames, staxids: staxids,
            blastDbVersion: "core_nt", snakemakeRunId: "run", mappedReads: 10, totalReads: 1000,
            statDbVersion: "1", adjustedTaxid: "2697049", adjustmentMethod: "dominant",
            adjustedTaxidName: "SARS-CoV-2", adjustedTaxidRank: "no rank", hitRank: 1,
            readsPerBillion: 1
        )
    }

    private func ncbiHit(_ organism: String, taxId: Int?) -> BlastHit {
        BlastHit(
            accession: "MN908947.3",
            title: "\(organism), complete genome",
            organism: organism,
            taxId: taxId,
            hsps: [BlastHSP(bitScore: 919, evalue: 0, identity: 499, alignLength: 500, queryFrom: 1, queryTo: 500)]
        )
    }

    private func verify(_ hit: NvdBlastHit, against top: BlastHit) throws -> BlastVerificationResult {
        let request = hit.blastVerificationRequest(taxonName: hit.adjustedTaxidName, sequence: "ACGT")
        return try BlastService().buildVerificationResult(
            request: request,
            searchResults: [BlastSearchResult(queryId: hit.qseqid, queryLength: 500, hits: [top])],
            rid: "RID",
            submittedAt: Date(),
            completedAt: Date()
        )
    }

    func testHitToTheClassifiedTaxonSupportsItDespiteADifferentName() throws {
        let result = try verify(
            nvdHit(),
            against: ncbiHit("Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1", taxId: 2697049)
        )
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    func testHitBelowTheClassifiedTaxonMatchesByItsScientificName() throws {
        // An isolate-level tax ID the NVD row does not list still carries the
        // species' scientific name.
        let result = try verify(
            nvdHit(),
            against: ncbiHit("Severe acute respiratory syndrome coronavirus 2", taxId: 9_999_999)
        )
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    func testHitToADifferentVirusContradicts() throws {
        let result = try verify(nvdHit(), against: ncbiHit("Human immunodeficiency virus 1", taxId: 11676))
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 1)
    }

    func testTaxonomyContextUsesTheAdjustedTaxonAndItsScientificName() {
        let request = nvdHit().blastVerificationRequest(taxonName: "SARS-CoV-2", sequence: "ACGT")
        XCTAssertEqual(request.taxId, 2697049)
        XCTAssertEqual(request.acceptedTaxIds, [2697049])
        XCTAssertEqual(
            Set(request.acceptedTaxonNames),
            ["SARS-CoV-2", "Severe acute respiratory syndrome coronavirus 2"]
        )
        XCTAssertEqual(request.database, "core_nt")
        XCTAssertNil(request.entrezQuery)
    }

    func testRowForAnotherOrganismDoesNotWidenTheClade() {
        // A lower-ranked row whose subject is not the adjusted classification
        // contributes neither its tax ID nor its name.
        let request = nvdHit(sscinames: "Bat coronavirus RaTG13", staxids: "2709072")
            .blastVerificationRequest(taxonName: "SARS-CoV-2", sequence: "ACGT")
        XCTAssertEqual(request.acceptedTaxIds, [2697049])
        XCTAssertEqual(request.acceptedTaxonNames, ["SARS-CoV-2"])
    }
}
