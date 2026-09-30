// ClassifierBlastVerificationRequestTests.swift - TaxTriage and EsViritu BLAST judged against the row's taxonomy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO

final class ClassifierBlastVerificationRequestTests: XCTestCase {

    private func ncbiHit(_ organism: String, taxId: Int?) -> BlastHit {
        BlastHit(
            accession: "NC_001806.2",
            title: "\(organism), complete genome",
            organism: organism,
            taxId: taxId,
            hsps: [BlastHSP(bitScore: 280, evalue: 1e-70, identity: 150, alignLength: 150, queryFrom: 1, queryTo: 150)]
        )
    }

    private func judge(_ request: BlastVerificationRequest, against top: BlastHit) throws -> BlastVerificationResult {
        try BlastService().buildVerificationResult(
            request: request,
            searchResults: [BlastSearchResult(queryId: "read1", queryLength: 150, hits: [top])],
            rid: "RID",
            submittedAt: Date(),
            completedAt: Date()
        )
    }

    private func detection(name: String, species: String?, subspecies: String? = nil, genus: String?) -> ViralDetection {
        ViralDetection(
            sampleId: "S1", name: name, description: name, length: 11_979, segment: "L",
            accession: "NC_014397.1", assembly: "GCF_000847345.1", assemblyLength: 11_979,
            kingdom: "Orthornavirae", phylum: "Negarnaviricota", tclass: "Ellioviricetes",
            order: "Bunyavirales", family: "Phenuiviridae", genus: genus,
            species: species, subspecies: subspecies,
            rpkmf: 10, readCount: 100, coveredBases: 5_000, meanCoverage: 4,
            avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000_000
        )
    }

    // MARK: - TaxTriage

    func testTaxTriageHitToTheOrganismsTaxIdSupportsItDespiteADifferentName() throws {
        // TaxTriage may use the current binomial while nt records keep the older name.
        let organism = TaxTriageOrganism(name: "Simplexvirus humanalpha1", score: 0.93, reads: 120, taxId: 10298)
        let top = ncbiHit("Human alphaherpesvirus 1", taxId: 10298)

        let result = try judge(organism.blastVerificationRequest(sequences: [("read1", "ACGT")]), against: top)
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)

        // Before, the request carried no tax IDs and the name rule rejected the hit.
        let nameOnly = BlastVerificationRequest(taxonName: organism.name, taxId: 10298, sequences: [("read1", "ACGT")])
        XCTAssertEqual(try judge(nameOnly, against: top).supportingCount, 0)
    }

    func testTaxTriageHitBelowTheOrganismMatchesByName() throws {
        let organism = TaxTriageOrganism(name: "Kocuria rhizophila", score: 0.92, reads: 80, taxId: 72000)
        let result = try judge(
            organism.blastVerificationRequest(sequences: [("read1", "ACGT")]),
            against: ncbiHit("Kocuria rhizophila strain BT304", taxId: 9_999_999)
        )
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    func testTaxTriageHitToAnotherOrganismContradicts() throws {
        let organism = TaxTriageOrganism(name: "Simplexvirus humanalpha1", score: 0.93, reads: 120, taxId: 10298)
        let result = try judge(
            organism.blastVerificationRequest(sequences: [("read1", "ACGT")]),
            against: ncbiHit("Streptococcus agalactiae", taxId: 1311)
        )
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 1)
    }

    func testTaxTriageContext() {
        let request = TaxTriageOrganism(name: " Kocuria rhizophila ", score: 0, reads: 1, taxId: 72000)
            .blastVerificationRequest(sequences: [("read1", "ACGT")])
        XCTAssertEqual(request.taxId, 72000)
        XCTAssertEqual(request.acceptedTaxIds, [72000])
        XCTAssertEqual(request.acceptedTaxonNames, ["Kocuria rhizophila"])
        XCTAssertEqual(request.database, "core_nt")
        XCTAssertNil(request.entrezQuery)

        let withoutTaxId = TaxTriageOrganism(name: "Kocuria rhizophila", score: 0, reads: 1)
            .blastVerificationRequest(sequences: [("read1", "ACGT")])
        XCTAssertEqual(withoutTaxId.taxId, 0)
        XCTAssertTrue(withoutTaxId.acceptedTaxIds.isEmpty)
        XCTAssertEqual(withoutTaxId.acceptedTaxonNames, ["Kocuria rhizophila"])
    }

    // MARK: - EsViritu

    func testEsVirituHitNamedByTheSpeciesSupportsTheDetection() throws {
        let virus = detection(name: "Rift Valley fever virus", species: "Rift Valley fever phlebovirus", genus: "Phlebovirus")
        let top = ncbiHit("Rift Valley fever phlebovirus strain ZH-548", taxId: 11588)

        let result = try judge(virus.blastVerificationRequest(sequences: [("read1", "ACGT")]), against: top)
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    func testEsVirituHitToAnotherVirusContradicts() throws {
        let virus = detection(name: "Rift Valley fever virus", species: "Rift Valley fever phlebovirus", genus: "Phlebovirus")
        let result = try judge(
            virus.blastVerificationRequest(sequences: [("read1", "ACGT")]),
            against: ncbiHit("Human immunodeficiency virus 1", taxId: 11676)
        )
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 1)
    }

    func testEsVirituContextListsEachNameOnce() {
        let request = detection(
            name: "Rift Valley fever phlebovirus",
            species: "Rift Valley fever phlebovirus",
            subspecies: "  ",
            genus: "Phlebovirus"
        ).blastVerificationRequest(sequences: [("read1", "ACGT")])
        XCTAssertEqual(request.taxId, 0)
        XCTAssertTrue(request.acceptedTaxIds.isEmpty)
        XCTAssertEqual(request.acceptedTaxonNames, ["Rift Valley fever phlebovirus"])
        XCTAssertEqual(request.relatedTaxonNames, ["Phlebovirus"])
        XCTAssertEqual(request.database, "core_nt")
    }
}
