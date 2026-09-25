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
        XCTAssertFalse(results[1].hasLCADisagreement, "HSV-2 is a relative, not a conflict")
        XCTAssertTrue(results[1].matchesQueriedTaxon)
        XCTAssertFalse(results[2].matchesQueriedTaxon, "an EBV top hit does not support HSV-1")
        XCTAssertEqual(results[2].topHitRelation, .outside)

        let summary = BlastVerificationResult(
            taxonName: "Simplexvirus humanalpha1", taxId: 3050292, readResults: results,
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "nt"
        )
        XCTAssertEqual(summary.lcaDisagreementCount, 1)
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
        minSubmitInterval: 0,
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
        } catch BlastServiceError.rateLimitExceeded(let retryAfter) {
            XCTAssertEqual(retryAfter, 3000, accuracy: 0.5, "the first submission expires 50 minutes later")
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
        try await ledger.reserve(count: 50, at: clock.now, limit: 50)
        do {
            try await ledger.reserve(count: 1, at: clock.now, limit: 50)
            XCTFail("the 51st read in an hour must be refused")
        } catch BlastServiceError.rateLimitExceeded {}
        let fresh = InMemoryBlastSubmissionLedger()
        try await fresh.reserve(count: 1, at: clock.now, limit: 50)
    }

    func testUnreadableLedgerFileDoesNotBlockBlast() async throws {
        let ledgerURL = FileBlastSubmissionLedger.fileURL(storageRoot: tempDir)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ledgerURL)
        let ledger = FileBlastSubmissionLedger(fileURL: ledgerURL)
        try await ledger.reserve(count: 10, at: Date(), limit: 50)
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
            guard case BlastServiceError.rateLimitExceeded(let retryAfter) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(retryAfter, 1800, accuracy: 0.001)
        }
        XCTAssertNoThrow(try BlastSubmissionBudget.reserve(&events, count: 10, at: start.addingTimeInterval(1800), limit: 50))
        XCTAssertEqual(events.count, 3)
    }
}
