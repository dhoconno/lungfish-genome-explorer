// BlastVerificationFixesTests.swift - Tax ID matching, per-read errors, persisted rate limit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

// MARK: - Synthetic hits

private let hsv1Clade: Set<Int> = [3050292, 10298]        // Simplexvirus humanalpha1, Human alphaherpesvirus 1
private let hsv1Names = ["Human alphaherpesvirus 1", "Simplexvirus humanalpha1"]
private let simplexGenus = 10294
private let hsv2Species = 3050293
private let hsv2TaxId = 10310
private let ebvTaxId = 10376

private func hit(_ organism: String, taxId: Int?, accession: String, bitScore: Double = 140) -> BlastHit {
    BlastHit(
        accession: accession,
        title: "\(organism), complete genome",
        organism: organism,
        taxId: taxId,
        hsps: [BlastHSP(bitScore: bitScore, evalue: 1e-30, identity: 76, alignLength: 76, queryFrom: 1, queryTo: 76)]
    )
}

private let hsv1Hit = hit("Human alphaherpesvirus 1", taxId: 10298, accession: "MN136523.1")
private let hsv2Hit = hit("Human alphaherpesvirus 2", taxId: hsv2TaxId, accession: "JN561323.2")
private let ebvHit = hit("Human gammaherpesvirus 4", taxId: ebvTaxId, accession: "NC_007605.1")

// MARK: - Tax ID matching

final class BlastTaxIdMatchingTests: XCTestCase {

    private let service = BlastService()

    /// HSV-1 selected, the tree lists no other Simplexvirus (the real
    /// SRR12486983 report has only 3050292 and 10298 under the genus).
    private var hsv1Context: BlastTaxonomyContext {
        BlastTaxonomyContext(
            cladeTaxIds: hsv1Clade,
            cladeNames: hsv1Names,
            relatedNames: ["Simplexvirus"]
        )
    }

    func testHSV2HitIsARelativeButNotSupportingForHSV1() {
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 2", hitTaxId: hsv2TaxId,
                queriedTaxonName: "Simplexvirus humanalpha1", context: hsv1Context
            ),
            .relative
        )
        XCTAssertFalse(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Human alphaherpesvirus 2", hitTaxId: hsv2TaxId,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: hsv1Clade, acceptedTaxonNames: hsv1Names
        ))
        // The old first-word rule called HSV-2 supporting: "Human" == "Human".
        XCTAssertTrue(BlastService.organismMatchesTaxon(
            hitOrganism: "Human alphaherpesvirus 2",
            queriedTaxonName: "Human alphaherpesvirus 1"
        ))
    }

    func testHSV2HitIsARelativeByTaxIdWhenTheTreeListsIt() {
        let context = BlastTaxonomyContext(
            cladeTaxIds: hsv1Clade,
            cladeNames: hsv1Names,
            relatedTaxIds: [simplexGenus, hsv2Species, hsv2TaxId],
            relatedNames: ["Simplexvirus", "Simplexvirus humanalpha2", "Human alphaherpesvirus 2"]
        )
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 2", hitTaxId: hsv2TaxId,
                queriedTaxonName: "Human alphaherpesvirus 1", context: context
            ),
            .relative
        )
    }

    func testHSV2HitSupportsWhenInsideTheSelectedClade() {
        // The genus Simplexvirus is selected, so HSV-2 is inside the clade.
        let genusClade: Set<Int> = [simplexGenus, 3050292, 10298, hsv2Species, hsv2TaxId]
        let results = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "r1", queryLength: 76, hits: [hsv2Hit])],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Simplexvirus",
            acceptedTaxIds: genusClade,
            acceptedTaxonNames: ["Simplexvirus"]
        )
        XCTAssertEqual(results[0].verdict, .verified)
        XCTAssertTrue(results[0].matchesQueriedTaxon)
        XCTAssertEqual(results[0].topHitRelation, .clade)
    }

    func testEBVHitIsOutsideAndConflicting() {
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human gammaherpesvirus 4", hitTaxId: ebvTaxId,
                queriedTaxonName: "Simplexvirus humanalpha1", context: hsv1Context
            ),
            .outside
        )

        let results = service.assignVerdicts(
            searchResults: [
                BlastSearchResult(queryId: "hsv1_then_ebv", queryLength: 76, hits: [hsv1Hit, ebvHit]),
                BlastSearchResult(queryId: "hsv1_then_hsv2", queryLength: 76, hits: [hsv1Hit, hsv2Hit]),
                BlastSearchResult(queryId: "ebv_top", queryLength: 76, hits: [ebvHit]),
            ],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: hsv1Clade,
            acceptedTaxonNames: hsv1Names,
            relatedTaxonNames: ["Simplexvirus"]
        )

        XCTAssertTrue(results[0].hasLCADisagreement, "HSV-1 beside EBV names conflicting organisms")
        XCTAssertTrue(results[0].matchesQueriedTaxon)
        XCTAssertTrue(results[1].hasLCADisagreement, "a tied HSV-2 is a relative and not in the clade, so the tie is shared")
        XCTAssertTrue(results[1].matchesQueriedTaxon)
        XCTAssertFalse(results[2].matchesQueriedTaxon, "an EBV top hit does not support HSV-1")
        XCTAssertEqual(results[2].topHitRelation, .outside)

        let summary = BlastVerificationResult(
            taxonName: "Simplexvirus humanalpha1", taxId: 3050292, readResults: results,
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "nt"
        )
        XCTAssertEqual(summary.lcaDisagreementCount, 2)
        XCTAssertEqual(summary.supportingCount, 2)
        XCTAssertEqual(summary.contradictingCount, 1)

        // The old first-word rule saw one genus, "Human", and no conflict.
        let summaries = results[0].topHits
        XCTAssertFalse(BlastTaxonMatching.legacyGenusDisagreement(hits: summaries))
    }

    func testStrainTaxIdMissingFromTheReportMatchesByCladeName() {
        // NCBI files many HSV-1 records under strain tax IDs (10299 is
        // strain 17) that a Kraken 2 report never lists.
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 1 strain 17", hitTaxId: 10299,
                queriedTaxonName: "Simplexvirus humanalpha1", context: hsv1Context
            ),
            .clade
        )
        // Word boundaries: serotype 10 is not serotype 1.
        XCTAssertNotEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 10", hitTaxId: 99999,
                queriedTaxonName: "Simplexvirus humanalpha1", context: hsv1Context
            ),
            .clade
        )
    }

    func testHitsWithoutTaxIdsFallBackToTheNameRule() {
        let noTaxId = hit("Human alphaherpesvirus 1 strain KOS", taxId: nil, accession: "JQ673480.1")
        let results = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "r1", queryLength: 76, hits: [noTaxId])],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: hsv1Clade,
            acceptedTaxonNames: hsv1Names
        )
        XCTAssertTrue(results[0].matchesQueriedTaxon)
        XCTAssertNil(results[0].topHitRelation, "no tax ID: the name rule decided")

        XCTAssertNil(BlastTaxonMatching.relation(
            hitOrganism: "Human alphaherpesvirus 1", hitTaxId: 10298,
            queriedTaxonName: "Human alphaherpesvirus 1", context: BlastTaxonomyContext()
        ), "no clade tax IDs: the name rule decides")
    }

    // MARK: - A first-word-only match counts neither way (BLAST-ESVIRITU-FIRST-WORD, BIO-THREE-ROWS items 1 to 3)

    /// One read of 76 bases, all aligned at E 1e-50, so the alignment alone makes the verdict `.verified`.
    private func perfectHit(_ organism: String, taxId: Int?, accession: String) -> BlastHit {
        BlastHit(
            accession: accession,
            title: "\(organism), complete genome",
            organism: organism,
            taxId: taxId,
            hsps: [BlastHSP(bitScore: 140, evalue: 1e-50, identity: 76, alignLength: 76, queryFrom: 1, queryTo: 76)]
        )
    }

    /// A row as EsViritu sends it when no lineage can be read, names and no tax IDs
    /// (`ViralDetection.blastTaxonomyContext`), so the name rule judges the first record.
    private func judgeByNames(
        _ hits: [BlastHit], row: String = "Rotavirus A", names: [String] = ["Rotavirus A"]
    ) -> BlastVerificationResult {
        let context = BlastTaxonomyContext(cladeNames: names, basis: .names)
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "r1", queryLength: 76, hits: hits)],
            eValueThreshold: 1e-10,
            queriedTaxonName: row,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames
        )
        return BlastVerificationResult(
            taxonName: row, taxId: 0, readResults: rows, submittedAt: Date(), completedAt: Date(),
            rid: "R", blastProgram: "blastn", database: "core_nt"
        )
    }

    /// Rotavirus C is another species, and "Rotavirus" is the first word of both names. The read counts as neither
    /// supporting nor contradicting, as a read that cannot be placed does (`listEndedInTheTie`).
    func testAFirstWordOnlyMatchCountsNeitherWayOnTheNamesBasis() throws {
        let result = judgeByNames([perfectHit("Rotavirus C", taxId: 36427, accession: "KX362457.1")])
        let row = try XCTUnwrap(result.readResults.first)
        XCTAssertEqual(row.verdict, .ambiguous, "a best match that shares only the first word cannot say")
        XCTAssertFalse(row.matchesQueriedTaxon)
        XCTAssertNil(row.topHitRelation, "no tax ID in the context, so the name rule decided")
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    /// The same holds for a host-prefixed name. RSV is one species of the genus that the row names `Human orthopneumovirus`,
    /// and no name is shared past "Human", so the read loses its Supported and does not become Contradicted.
    func testAHostWordAloneCountsNeitherWayOnTheNamesBasis() throws {
        let result = judgeByNames(
            [perfectHit("Human respiratory syncytial virus A", taxId: 12814, accession: "MZ515573.1")],
            row: "Human orthopneumovirus", names: ["Human orthopneumovirus"]
        )
        let row = try XCTUnwrap(result.readResults.first)
        XCTAssertEqual(row.verdict, .ambiguous)
        XCTAssertFalse(row.matchesQueriedTaxon)
        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 0)
    }

    /// Green pins. A name that holds the row's name, or one of its accepted names, still supports.
    func testAHitThatHoldsTheRowsNameStillSupportsOnTheNamesBasis() throws {
        let strain = judgeByNames([perfectHit("Rotavirus A strain X", taxId: 28875, accession: "KX362458.1")])
        XCTAssertEqual(strain.readResults.first?.verdict, .verified)
        XCTAssertEqual(strain.readResults.first?.matchesQueriedTaxon, true)
        XCTAssertEqual(strain.supportingCount, 1)

        let species = judgeByNames(
            [perfectHit("Betacoronavirus 1", taxId: nil, accession: "NC_006213.1")],
            row: "Human coronavirus OC43", names: ["Human coronavirus OC43", "Betacoronavirus 1"]
        )
        XCTAssertEqual(species.readResults.first?.verdict, .verified, "the species name is an accepted name")
        XCTAssertEqual(species.supportingCount, 1)
    }

    /// Green pins. A hit with no name in common still contradicts, and a weak alignment is still ambiguous.
    func testNoNameInCommonStillContradictsAndAWeakAlignmentStaysAmbiguous() throws {
        let vector = judgeByNames([perfectHit("Expression vector pHR_SFFV", taxId: 3464302, accession: "PX372844.1")])
        XCTAssertEqual(vector.readResults.first?.verdict, .verified)
        XCTAssertEqual(vector.readResults.first?.matchesQueriedTaxon, false)
        XCTAssertEqual(vector.contradictingCount, 1)

        let belowThresholds = BlastHit(
            accession: "KX362457.1", title: "Rotavirus C", organism: "Rotavirus C", taxId: 36427,
            hsps: [BlastHSP(bitScore: 40, evalue: 1e-4, identity: 30, alignLength: 40, queryFrom: 1, queryTo: 40)]
        )
        let result = judgeByNames([belowThresholds])
        XCTAssertEqual(result.readResults.first?.verdict, .ambiguous)
        XCTAssertEqual(result.readResults.first?.matchesQueriedTaxon, false)
    }

    /// Green pin. With a clade tax ID the tax ID rule decides, so Rotavirus C is a relative that contradicts, as before.
    func testTheSpeciesBasisStillJudgesRotavirusCByItsTaxId() throws {
        let context = BlastTaxonomyContext(
            cladeTaxIds: [28875], cladeNames: ["Rotavirus A"], relatedNames: ["Rotavirus"], basis: .species
        )
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(
                queryId: "r1", queryLength: 76, hits: [perfectHit("Rotavirus C", taxId: 36427, accession: "KX362457.1")]
            )],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Rotavirus A",
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            relatedTaxonNames: context.relatedNames
        )
        XCTAssertEqual(rows[0].verdict, .verified)
        XCTAssertFalse(rows[0].matchesQueriedTaxon)
        XCTAssertEqual(rows[0].topHitRelation, .relative)
    }

    /// A name that holds the row's name only as text is another virus. The queried name counts as whole words, as an
    /// accepted name does, so the read counts neither way (BIO review of BLAST-FIRSTWORD, Finding 1).
    func testANumberedSiblingCountsNeitherWayOnTheNamesBasis() throws {
        let pairs: [(row: String, hit: String)] = [
            ("Alphapapillomavirus 1", "Alphapapillomavirus 10"),
            ("Alphapapillomavirus 10", "Alphapapillomavirus 1"),
            ("Human papillomavirus type 1", "Human papillomavirus type 16"),
            ("Torque teno virus 1", "Torque teno virus 10"),
        ]
        for pair in pairs {
            let result = judgeByNames(
                [perfectHit(pair.hit, taxId: nil, accession: "KX000001.1")], row: pair.row, names: [pair.row]
            )
            let read = try XCTUnwrap(result.readResults.first, pair.row)
            XCTAssertEqual(read.verdict, .ambiguous, "\(pair.hit) is not \(pair.row)")
            XCTAssertFalse(read.matchesQueriedTaxon, "\(pair.hit) is not \(pair.row)")
            XCTAssertEqual(result.supportingCount, 0, "\(pair.hit) for \(pair.row)")
            XCTAssertEqual(result.contradictingCount, 0, "\(pair.hit) for \(pair.row)")
        }
    }

    /// A name that holds the row's letters inside another word has no word in common with it, so it contradicts, and
    /// that is right, since Pseudocowpox virus is not Cowpox virus. This is the one class where a Contradicted count rises.
    func testAHitThatHoldsTheRowsLettersInsideAnotherWordContradictsOnTheNamesBasis() throws {
        let result = judgeByNames(
            [perfectHit("Pseudocowpox virus", taxId: nil, accession: "KX000002.1")], row: "Cowpox virus", names: ["Cowpox virus"]
        )
        let read = try XCTUnwrap(result.readResults.first)
        XCTAssertEqual(read.verdict, .verified)
        XCTAssertFalse(read.matchesQueriedTaxon)
        XCTAssertEqual(result.contradictingCount, 1)
    }

    /// Green pin. The queried name alone, with no accepted names, still supports as whole words.
    func testTheQueriedNameStillSupportsAsWholeWordsOnTheNamesBasis() throws {
        let result = judgeByNames(
            [perfectHit("Oxbow virus isolate ABC", taxId: nil, accession: "KX000003.1")], row: "Oxbow virus", names: []
        )
        XCTAssertEqual(result.readResults.first?.verdict, .verified)
        XCTAssertEqual(result.readResults.first?.matchesQueriedTaxon, true)
        XCTAssertEqual(result.supportingCount, 1)
    }

    /// Green pin. The row-tax-ID basis judges Rotavirus C by its tax ID, so it contradicts, as before.
    func testTheRowTaxIdBasisStillJudgesRotavirusCByItsTaxId() throws {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(
                queryId: "r1", queryLength: 76, hits: [perfectHit("Rotavirus C", taxId: 36427, accession: "KX362457.1")]
            )],
            eValueThreshold: 1e-10, queriedTaxonName: "Rotavirus A", acceptedTaxIds: [28875], acceptedTaxonNames: ["Rotavirus A"]
        )
        XCTAssertEqual(rows[0].verdict, .verified)
        XCTAssertFalse(rows[0].matchesQueriedTaxon)
        XCTAssertEqual(rows[0].topHitRelation, .outside)
    }

    /// A top hit with no tax ID in a context that holds clade tax IDs is judged by the name rule, so a first-word-only
    /// match counts neither way there too (ruling item 1, "wherever the name rule decides a read").
    func testAFirstWordOnlyHitWithNoTaxIdInARowTaxIdContextCountsNeitherWay() throws {
        let rows = service.assignVerdicts(
            searchResults: [BlastSearchResult(
                queryId: "r1", queryLength: 76, hits: [perfectHit("Rotavirus C", taxId: nil, accession: "KX362457.1")]
            )],
            eValueThreshold: 1e-10, queriedTaxonName: "Rotavirus A", acceptedTaxIds: [28875], acceptedTaxonNames: ["Rotavirus A"]
        )
        XCTAssertEqual(rows[0].verdict, .ambiguous)
        XCTAssertFalse(rows[0].matchesQueriedTaxon)
        XCTAssertNil(rows[0].topHitRelation, "no tax ID on the hit, so the name rule decided")
    }

    /// No caller outside the tests reads `hitMatchesQueriedTaxon`, so it follows the verdict rule. A first-word-only
    /// match does not support, while `organismMatchesTaxon` keeps saying that the first words agree.
    func testAFirstWordOnlyMatchIsNoSupportInHitMatchesQueriedTaxon() {
        XCTAssertFalse(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Rotavirus C", hitTaxId: nil, queriedTaxonName: "Rotavirus A",
            acceptedTaxIds: [], acceptedTaxonNames: ["Rotavirus A"]
        ))
        XCTAssertTrue(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Rotavirus A strain X", hitTaxId: nil, queriedTaxonName: "Rotavirus A",
            acceptedTaxIds: [], acceptedTaxonNames: ["Rotavirus A"]
        ))
        XCTAssertTrue(BlastService.organismMatchesTaxon(hitOrganism: "Rotavirus C", queriedTaxonName: "Rotavirus A"))
    }

    /// The `.names` line. UX-BLAST-NOTAX item 5 set the final words: a row judged by names alone gives no verdict, so the
    /// line no longer says what a shared first word counts for.
    func testTheNamesBasisWordsSayThatAFirstWordOnlyMatchCountsNeitherWay() {
        let words = BlastTaxonomyContext.Basis.names.judgedAtWords(taxId: 0) ?? ""
        XCTAssertEqual(
            words,
            "Not judged: this row has no tax ID, so LGE cannot tell its species from another species whose name holds this row's name. "
                + "Each read's best match is listed below."
        )
        XCTAssertFalse(words.contains("happens to share"), "the sentence that said a shared name counts either way")
    }

    func testRequestCarriesRelatedTaxa() {
        let request = BlastVerificationRequest(
            taxonName: "Simplexvirus humanalpha1",
            taxId: 3050292,
            sequences: [("r1", "ACGT")],
            acceptedTaxIds: hsv1Clade,
            acceptedTaxonNames: hsv1Names,
            relatedTaxIds: [simplexGenus, 10298],
            relatedTaxonNames: ["Simplexvirus"]
        )
        XCTAssertEqual(request.relatedTaxIds, [simplexGenus], "clade tax IDs are never also relatives")
        XCTAssertEqual(request.taxonomyContext.cladeTaxIds, hsv1Clade)
        XCTAssertEqual(request.taxonomyContext.relatedNames, ["Simplexvirus"])
    }

    func testJSON2TaxIdIsParsedAsNumberOrString() throws {
        let json = """
        {"BlastOutput2":[{"report":{"results":{"search":{"query_title":"r1","query_len":76,"hits":[
          {"description":[{"accession":"A1","title":"t","sciname":"Human alphaherpesvirus 2","taxid":10310}],
           "hsps":[{"bit_score":140.0,"evalue":1e-30,"identity":76,"align_len":76,"query_from":1,"query_to":76}]},
          {"description":[{"accession":"A2","title":"t","sciname":"Human gammaherpesvirus 4","taxid":"10376"}],
           "hsps":[{"bit_score":120.0,"evalue":1e-25,"identity":70,"align_len":76,"query_from":1,"query_to":76}]}
        ]}}}}]}
        """
        let results = try service.parseJSON2Results(Data(json.utf8))
        XCTAssertEqual(results.first?.hits.map(\.taxId), [10310, 10376])
    }
}

// MARK: - Per-read Error verdicts

final class BlastPerReadErrorTests: XCTestCase {

    private let service = BlastService()

    private func request(ids: [String]) -> BlastVerificationRequest {
        BlastVerificationRequest(
            taxonName: "Simplexvirus humanalpha1",
            taxId: 3050292,
            sequences: ids.map { ($0, "ACGTACGT") },
            acceptedTaxIds: hsv1Clade,
            acceptedTaxonNames: hsv1Names
        )
    }

    func testReadMissingFromTheResponseGetsAnErrorVerdictWithoutFailingTheJob() throws {
        let result = try service.buildVerificationResult(
            request: request(ids: ["r1", "r2", "r3"]),
            searchResults: [
                BlastSearchResult(queryId: "r1", queryLength: 76, hits: [hsv1Hit]),
                BlastSearchResult(queryId: "r3", queryLength: 76, hits: []),
            ],
            rid: "RID1",
            submittedAt: Date(),
            completedAt: Date()
        )

        XCTAssertEqual(result.readResults.map(\.id), ["r1", "r2", "r3"], "one row per submitted read, in order")
        XCTAssertEqual(result.readResults.map(\.verdict), [.verified, .error, .unverified])
        XCTAssertEqual(result.readResults[1].errorMessage, BlastService.missingReadResultMessage)
        XCTAssertEqual(result.readResults[1].querySequence, "ACGTACGT")
        XCTAssertEqual(result.totalReads, 3)
        XCTAssertEqual(result.errorCount, 1)
        XCTAssertEqual(result.unverifiedCount, 1)
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.inconclusiveCount, 2)
    }

    func testUnparseableEntryGetsAnErrorVerdict() throws {
        let json = """
        {"BlastOutput2":[
          {"report":{"results":{"search":{"query_title":"r1","query_len":76,"hits":[
            {"description":[{"accession":"A1","title":"t","sciname":"Human alphaherpesvirus 1","taxid":10298}],
             "hsps":[{"bit_score":140.0,"evalue":1e-30,"identity":76,"align_len":76,"query_from":1,"query_to":76}]}]}}}},
          {"error":"Query r2 could not be searched"},
          {"report":{"results":{"search":{"query_title":"r3","query_len":76,"hits":"garbled"}}}}
        ]}
        """
        let parsed = try service.parseJSON2Results(Data(json.utf8))
        XCTAssertEqual(parsed.count, 3, "an unparseable entry is kept, not dropped")
        XCTAssertNotNil(parsed[1].failureMessage)
        XCTAssertNotNil(parsed[2].failureMessage)

        let result = try service.buildVerificationResult(
            request: request(ids: ["r1", "r2", "r3"]),
            searchResults: parsed,
            rid: "RID2",
            submittedAt: Date(),
            completedAt: Date()
        )
        XCTAssertEqual(result.readResults.map(\.verdict), [.verified, .error, .error])
        XCTAssertEqual(result.readResults[1].errorMessage, "Query r2 could not be searched")
        XCTAssertEqual(result.errorCount, 2)
    }

    func testUntitledEntriesLineUpByPosition() throws {
        let result = try service.buildVerificationResult(
            request: request(ids: ["frag_a", "frag_b"]),
            searchResults: [
                BlastSearchResult(queryId: "Query_1", queryLength: 76, hits: [hsv1Hit]),
                BlastSearchResult(queryId: "", queryLength: 0, hits: [], failureMessage: "unparsed"),
            ],
            rid: "RID3",
            submittedAt: Date(),
            completedAt: Date()
        )
        XCTAssertEqual(result.readResults.map(\.id), ["frag_a", "frag_b"])
        XCTAssertEqual(result.readResults.map(\.verdict), [.verified, .error])
    }

    func testEveryReadFailingFailsTheJob() {
        XCTAssertThrowsError(try service.buildVerificationResult(
            request: request(ids: ["r1", "r2"]),
            searchResults: [],
            rid: "RID4",
            submittedAt: Date(),
            completedAt: Date()
        )) { error in
            guard case BlastServiceError.resultParsingFailed = error else {
                return XCTFail("expected resultParsingFailed, got \(error)")
            }
        }
    }

    func testZipMembersKeepSubmissionOrder() {
        let names = ["RID_10.json", "RID_2.json", "RID_1.json"]
        let sorted = names.map { URL(fileURLWithPath: "/tmp/\($0)") }
            .sorted(by: BlastService.zipEntryOrder)
            .map(\.lastPathComponent)
        XCTAssertEqual(sorted, ["RID_1.json", "RID_2.json", "RID_10.json"])
    }

    func testResultsSavedBeforeTheseFieldsStillDecode() throws {
        let json = """
        {"taxonName":"Oxbow virus","taxId":2560178,"totalReads":1,"verifiedCount":0,"ambiguousCount":0,
         "unverifiedCount":0,"errorCount":1,"readResults":[{"id":"r1","verdict":"error","topHits":[],
         "hasLCADisagreement":false,"matchesQueriedTaxon":false}],"submittedAt":0,"rid":"R",
         "blastProgram":"blastn","database":"nt"}
        """
        let decoded = try JSONDecoder().decode(BlastVerificationResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.errorCount, 1)
        XCTAssertEqual(decoded.readResults.first?.verdict, .error)
        XCTAssertNil(decoded.readResults.first?.errorMessage)
        XCTAssertNil(decoded.readResults.first?.topHitRelation)
    }
}

// MARK: - Persisted hourly rate limit

final class BlastSubmissionLedgerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastSubmissionLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    private let limits = BlastRateLimitConfiguration(
        maxSequencesPerHour: 50,
        submissionSlotPollInterval: 0.001
    )

    private func submission(rid: String) -> String {
        "<html><body><!--QBlastInfoBegin\n    RID = \(rid)\n    RTOE = 30\nQBlastInfoEnd--></body></html>"
    }

    func testBudgetSurvivesARestartThroughTheFileLedger() async throws {
        let ledgerURL = FileBlastSubmissionLedger.fileURL(storageRoot: tempDir)
        XCTAssertEqual(ledgerURL.path, tempDir.appendingPathComponent("blast/submission-ledger.json").path)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))

        let client = MockHTTPClient()
        await client.registerSequence(pattern: "blast/Blast.cgi", responses: [
            .text(submission(rid: "FIRST")),
            .text(submission(rid: "THIRD")),
        ])

        // First "launch": 30 reads.
        let first = BlastService(
            httpClient: client,
            rateLimits: limits,
            submissionLedger: FileBlastSubmissionLedger(fileURL: ledgerURL),
            now: { clock.now }
        )
        _ = try await first.submit(
            query: ">r\nACGT", program: "blastn", database: "nt", entrezQuery: nil,
            evalue: 1e-10, maxTargetSeqs: 5, megablast: true, sequenceCount: 30
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))

        // Second "launch" ten minutes later: a fresh service, same storage root.
        clock.advance(600)
        let second = BlastService(
            httpClient: client,
            rateLimits: limits,
            submissionLedger: FileBlastSubmissionLedger(fileURL: ledgerURL),
            now: { clock.now }
        )
        do {
            _ = try await second.submit(
                query: ">r\nACGT", program: "blastn", database: "nt", entrezQuery: nil,
                evalue: 1e-10, maxTargetSeqs: 5, megablast: true, sequenceCount: 21
            )
            XCTFail("30 + 21 reads within an hour must be refused after a restart")
        } catch BlastServiceError.rateLimitExceeded(let refusal) {
            XCTAssertEqual(refusal.retryAfter ?? 0, 3000, accuracy: 0.5, "the first submission expires 50 minutes later")
        }
        let afterRefusal = await client.requests.count
        XCTAssertEqual(afterRefusal, 1, "a refused submission never reaches NCBI")

        // An hour after the first submission the budget is free again.
        clock.advance(3001)
        _ = try await second.submit(
            query: ">r\nACGT", program: "blastn", database: "nt", entrezQuery: nil,
            evalue: 1e-10, maxTargetSeqs: 5, megablast: true, sequenceCount: 21
        )
        let events = await FileBlastSubmissionLedger(fileURL: ledgerURL).events(at: clock.now)
        XCTAssertEqual(events.map(\.count), [21], "expired events are pruned from the file")
    }

    func testInMemoryLedgerIsTheDefaultAndForgetsOnRestart() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = InMemoryBlastSubmissionLedger()
        try await ledger.reserve(count: 50, kind: .first, at: clock.now, limit: 50)
        do {
            try await ledger.reserve(count: 1, kind: .first, at: clock.now, limit: 50)
            XCTFail("the 51st read in an hour must be refused")
        } catch BlastServiceError.rateLimitExceeded {}
        let fresh = InMemoryBlastSubmissionLedger()
        try await fresh.reserve(count: 1, kind: .first, at: clock.now, limit: 50)
    }

    func testUnreadableLedgerFileDoesNotBlockBlast() async throws {
        let ledgerURL = FileBlastSubmissionLedger.fileURL(storageRoot: tempDir)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ledgerURL)
        let ledger = FileBlastSubmissionLedger(fileURL: ledgerURL)
        try await ledger.reserve(count: 10, kind: .first, at: Date(), limit: 50)
        let events = await ledger.events(at: Date())
        XCTAssertEqual(events.map(\.count), [10], "the corrupt file is replaced by a valid ledger")
    }

    func testBudgetRuleReportsWhenTheOldestSubmissionExpires() {
        let start = Date(timeIntervalSince1970: 0)
        var events = [
            BlastSubmissionLedgerEvent(date: start, count: 20),
            BlastSubmissionLedgerEvent(date: start.addingTimeInterval(1200), count: 20),
        ]
        XCTAssertThrowsError(try BlastSubmissionBudget.reserve(&events, count: 11, at: start.addingTimeInterval(1800), limit: 50)) { error in
            guard case BlastServiceError.rateLimitExceeded(let refusal) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(refusal.retryAfter ?? 0, 1800, accuracy: 0.001)
        }
        XCTAssertNoThrow(try BlastSubmissionBudget.reserve(&events, count: 10, at: start.addingTimeInterval(1800), limit: 50))
        XCTAssertEqual(events.count, 3)
    }
}
