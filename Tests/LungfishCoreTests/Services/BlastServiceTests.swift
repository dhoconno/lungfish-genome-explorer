// BlastServiceTests.swift - Tests for BLAST verification service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

// MARK: - BLAST Result Model Tests

final class BlastResultModelTests: XCTestCase {

    // MARK: - BlastReadResult

    func testBlastReadResultCreation() {
        let result = BlastReadResult(
            id: "read_001",
            verdict: .verified,
            topHitOrganism: "Oxbow virus",
            topHitAccession: "MN552435.1",
            percentIdentity: 99.3,
            queryCoverage: 98.0,
            eValue: 0.0,
            alignmentLength: 147,
            bitScore: 265.0
        )

        XCTAssertEqual(result.id, "read_001")
        XCTAssertEqual(result.verdict, .verified)
        XCTAssertEqual(result.topHitOrganism, "Oxbow virus")
        XCTAssertEqual(result.topHitAccession, "MN552435.1")
        XCTAssertEqual(result.percentIdentity, 99.3)
        XCTAssertEqual(result.queryCoverage, 98.0)
        XCTAssertEqual(result.eValue, 0.0)
        XCTAssertEqual(result.alignmentLength, 147)
        XCTAssertEqual(result.bitScore, 265.0)
    }

    func testBlastReadResultUnverified() {
        let result = BlastReadResult(id: "read_002", verdict: .unverified)

        XCTAssertEqual(result.id, "read_002")
        XCTAssertEqual(result.verdict, .unverified)
        XCTAssertNil(result.topHitOrganism)
        XCTAssertNil(result.topHitAccession)
        XCTAssertNil(result.percentIdentity)
        XCTAssertNil(result.queryCoverage)
        XCTAssertNil(result.eValue)
        XCTAssertNil(result.alignmentLength)
        XCTAssertNil(result.bitScore)
    }

    func testBlastReadResultCodable() throws {
        let original = BlastReadResult(
            id: "read_003",
            verdict: .ambiguous,
            topHitOrganism: "Hantaan virus",
            topHitAccession: "AB027523.1",
            percentIdentity: 85.0,
            queryCoverage: 60.0,
            eValue: 1e-20,
            alignmentLength: 90,
            bitScore: 150.0
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlastReadResult.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.verdict, original.verdict)
        XCTAssertEqual(decoded.topHitOrganism, original.topHitOrganism)
        XCTAssertEqual(decoded.topHitAccession, original.topHitAccession)
        XCTAssertEqual(decoded.percentIdentity, original.percentIdentity)
        XCTAssertEqual(decoded.eValue, original.eValue)
    }

    // MARK: - BlastVerdict

    func testBlastVerdictRawValues() {
        XCTAssertEqual(BlastVerdict.verified.rawValue, "verified")
        XCTAssertEqual(BlastVerdict.ambiguous.rawValue, "ambiguous")
        XCTAssertEqual(BlastVerdict.unverified.rawValue, "unverified")
        XCTAssertEqual(BlastVerdict.error.rawValue, "error")
    }

    func testBlastVerdictCodable() throws {
        for verdict in BlastVerdict.allCases {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(BlastVerdict.self, from: data)
            XCTAssertEqual(decoded, verdict)
        }
    }

    // MARK: - BlastVerificationResult Confidence

    func testConfidenceHigh() {
        let result = makeVerificationResult(verified: 18, ambiguous: 1, unverified: 1, error: 0)

        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.verificationRate, 0.9, accuracy: 0.01)
    }

    func testConfidenceHighAtBoundary() {
        // Exactly 80%
        let result = makeVerificationResult(verified: 16, ambiguous: 2, unverified: 2, error: 0)

        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.verificationRate, 0.8, accuracy: 0.01)
    }

    func testConfidenceModerate() {
        let result = makeVerificationResult(verified: 12, ambiguous: 3, unverified: 5, error: 0)

        XCTAssertEqual(result.confidence, .moderate)
        XCTAssertEqual(result.verificationRate, 0.6, accuracy: 0.01)
    }

    func testConfidenceLow() {
        let result = makeVerificationResult(verified: 5, ambiguous: 5, unverified: 10, error: 0)

        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.verificationRate, 0.25, accuracy: 0.01)
    }

    func testConfidenceSuspect() {
        let result = makeVerificationResult(verified: 1, ambiguous: 2, unverified: 17, error: 0)

        XCTAssertEqual(result.confidence, .suspect)
        XCTAssertEqual(result.verificationRate, 0.05, accuracy: 0.01)
    }

    func testConfidenceZeroReads() {
        let result = BlastVerificationResult(
            taxonName: "Test",
            taxId: 1,
            totalReads: 0,
            verifiedCount: 0,
            ambiguousCount: 0,
            unverifiedCount: 0,
            errorCount: 0,
            readResults: [],
            submittedAt: Date(),
            completedAt: Date(),
            rid: "TEST001",
            blastProgram: "blastn",
            database: "nt"
        )

        XCTAssertEqual(result.verificationRate, 0)
        XCTAssertEqual(result.confidence, .suspect)
    }

    func testConfidenceAllErrors() {
        let result = makeVerificationResult(verified: 0, ambiguous: 0, unverified: 0, error: 20)

        XCTAssertEqual(result.confidence, .suspect)
        XCTAssertEqual(result.verificationRate, 0)
    }

    func testVerificationResultAutoCountInit() {
        let readResults = [
            BlastReadResult(id: "r1", verdict: .verified),
            BlastReadResult(id: "r2", verdict: .verified),
            BlastReadResult(id: "r3", verdict: .ambiguous),
            BlastReadResult(id: "r4", verdict: .unverified),
            BlastReadResult(id: "r5", verdict: .error),
        ]

        let result = BlastVerificationResult(
            taxonName: "Test",
            taxId: 1,
            readResults: readResults,
            submittedAt: Date(),
            completedAt: Date(),
            rid: "TEST001",
            blastProgram: "blastn",
            database: "nt"
        )

        XCTAssertEqual(result.totalReads, 5)
        XCTAssertEqual(result.verifiedCount, 2)
        XCTAssertEqual(result.ambiguousCount, 1)
        XCTAssertEqual(result.unverifiedCount, 1)
        XCTAssertEqual(result.errorCount, 1)
    }

    func testVerificationResultCodable() throws {
        let result = makeVerificationResult(verified: 5, ambiguous: 3, unverified: 2, error: 0)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BlastVerificationResult.self, from: data)

        XCTAssertEqual(decoded.taxonName, result.taxonName)
        XCTAssertEqual(decoded.taxId, result.taxId)
        XCTAssertEqual(decoded.totalReads, result.totalReads)
        XCTAssertEqual(decoded.verifiedCount, result.verifiedCount)
        XCTAssertEqual(decoded.confidence, result.confidence)
        XCTAssertEqual(decoded.rid, result.rid)
    }

    // MARK: - BlastHSP

    func testBlastHSPPercentIdentity() {
        let hsp = BlastHSP(
            bitScore: 200.0,
            evalue: 1e-50,
            identity: 140,
            alignLength: 150,
            queryFrom: 1,
            queryTo: 150
        )

        XCTAssertEqual(hsp.percentIdentity, 140.0 / 150.0 * 100.0, accuracy: 0.01)
    }

    func testBlastHSPPercentIdentityZeroLength() {
        let hsp = BlastHSP(
            bitScore: 0,
            evalue: 1.0,
            identity: 0,
            alignLength: 0,
            queryFrom: 0,
            queryTo: 0
        )

        XCTAssertEqual(hsp.percentIdentity, 0)
    }

    func testBlastHSPQueryCoverage() {
        let hsp = BlastHSP(
            bitScore: 200.0,
            evalue: 1e-50,
            identity: 140,
            alignLength: 150,
            queryFrom: 1,
            queryTo: 120
        )

        // Coverage = (120 - 1 + 1) / 150 * 100 = 80%
        XCTAssertEqual(hsp.queryCoverage(queryLength: 150), 80.0, accuracy: 0.01)
    }

    func testBlastHSPQueryCoverageZeroLength() {
        let hsp = BlastHSP(
            bitScore: 0, evalue: 1.0, identity: 0, alignLength: 0,
            queryFrom: 0, queryTo: 0
        )

        XCTAssertEqual(hsp.queryCoverage(queryLength: 0), 0)
    }

    // MARK: - Helpers

    private func makeVerificationResult(
        verified: Int,
        ambiguous: Int,
        unverified: Int,
        error: Int
    ) -> BlastVerificationResult {
        var readResults: [BlastReadResult] = []
        for i in 0..<verified {
            readResults.append(BlastReadResult(id: "v_\(i)", verdict: .verified))
        }
        for i in 0..<ambiguous {
            readResults.append(BlastReadResult(id: "a_\(i)", verdict: .ambiguous))
        }
        for i in 0..<unverified {
            readResults.append(BlastReadResult(id: "u_\(i)", verdict: .unverified))
        }
        for i in 0..<error {
            readResults.append(BlastReadResult(id: "e_\(i)", verdict: .error))
        }

        return BlastVerificationResult(
            taxonName: "Test Organism",
            taxId: 12345,
            readResults: readResults,
            submittedAt: Date(),
            completedAt: Date(),
            rid: "TEST_RID_001",
            blastProgram: "blastn",
            database: "nt"
        )
    }
}

// MARK: - BLAST Request Tests

final class BlastVerificationRequestTests: XCTestCase {

    func testRequestCreation() {
        let request = BlastVerificationRequest(
            taxonName: "Oxbow virus",
            taxId: 2560178,
            sequences: [("read1", "ATGCGATCGA"), ("read2", "GCTAGCTAGC")]
        )

        XCTAssertEqual(request.taxonName, "Oxbow virus")
        XCTAssertEqual(request.taxId, 2560178)
        XCTAssertEqual(request.sequences.count, 2)
        XCTAssertEqual(request.program, "blastn")
        XCTAssertEqual(request.database, "nt")
        XCTAssertEqual(request.entrezQuery, "txid2560178[Organism:exp]")
        XCTAssertEqual(request.maxTargetSeqs, 10)
        XCTAssertEqual(request.eValueThreshold, 1e-10)
    }

    func testRequestCustomParameters() {
        let request = BlastVerificationRequest(
            taxonName: "SARS-CoV-2",
            taxId: 2697049,
            sequences: [("r1", "ATGC")],
            program: "blastn",
            database: "core_nt",
            entrezQuery: "txid2697049[Organism:exp] AND biomol_genomic[PROP]",
            maxTargetSeqs: 5,
            eValueThreshold: 1e-5
        )

        XCTAssertEqual(request.database, "core_nt")
        XCTAssertEqual(request.entrezQuery, "txid2697049[Organism:exp] AND biomol_genomic[PROP]")
        XCTAssertEqual(request.maxTargetSeqs, 5)
        XCTAssertEqual(request.eValueThreshold, 1e-5)
    }

    func testRequestToMultiFASTA() {
        let request = BlastVerificationRequest(
            taxonName: "Test",
            taxId: 1,
            sequences: [
                ("read_001", "ATGCGATCGA"),
                ("read_002", "GCTAGCTAGC"),
                ("read_003", "TTTTAAAACCC"),
            ]
        )

        let fasta = request.toMultiFASTA()
        let lines = fasta.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[0], ">read_001")
        XCTAssertEqual(lines[1], "ATGCGATCGA")
        XCTAssertEqual(lines[2], ">read_002")
        XCTAssertEqual(lines[3], "GCTAGCTAGC")
        XCTAssertEqual(lines[4], ">read_003")
        XCTAssertEqual(lines[5], "TTTTAAAACCC")
    }

    func testRequestToMultiFASTASingleRead() {
        let request = BlastVerificationRequest(
            taxonName: "Test",
            taxId: 1,
            sequences: [("single_read", "ATGCGATCGA")]
        )

        let fasta = request.toMultiFASTA()
        XCTAssertEqual(fasta, ">single_read\nATGCGATCGA")
    }

    func testRequestDefaultEntrezQuery() {
        let request = BlastVerificationRequest(
            taxonName: "Test",
            taxId: 9606,
            sequences: []
        )

        XCTAssertEqual(request.entrezQuery, "txid9606[Organism:exp]")
    }
}

// MARK: - Subsample Strategy Tests

final class SubsampleStrategyTests: XCTestCase {

    func testLongestFirstTotalCount() {
        let strategy = SubsampleStrategy.longestFirst(count: 10)
        XCTAssertEqual(strategy.totalCount, 10)
    }

    func testRandomTotalCount() {
        let strategy = SubsampleStrategy.random(count: 15)
        XCTAssertEqual(strategy.totalCount, 15)
    }

    func testMixedTotalCount() {
        let strategy = SubsampleStrategy.mixed(longest: 5, random: 15)
        XCTAssertEqual(strategy.totalCount, 20)
    }

    func testDefaultStrategy() {
        let strategy = SubsampleStrategy.default
        XCTAssertEqual(strategy, .mixed(longest: 5, random: 15))
        XCTAssertEqual(strategy.totalCount, 20)
    }
}

// MARK: - BLAST Service Tests

final class BlastServiceTests: XCTestCase {

    var mockClient: MockHTTPClient!
    var service: BlastService!

    override func setUp() async throws {
        mockClient = MockHTTPClient()
        service = BlastService(httpClient: mockClient)
    }

    // MARK: - Submission Tests

    func testSubmitBuildsPOSTRequest() async throws {
        await mockClient.register(
            pattern: "blast/Blast.cgi",
            response: .text(mockSubmissionResponse(rid: "TEST123", rtoe: 30))
        )

        let submission = try await service.submit(
            query: ">read1\nATGC",
            program: "blastn",
            database: "nt",
            entrezQuery: "txid12345[Organism:exp]",
            evalue: 1e-10,
            maxTargetSeqs: 10,
            megablast: true
        )

        XCTAssertEqual(submission.rid, "TEST123")
        XCTAssertEqual(submission.rtoe, 30)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )

        // Verify body contains expected parameters
        let body = String(data: requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("CMD=Put"))
        XCTAssertTrue(body.contains("PROGRAM=blastn"))
        XCTAssertTrue(body.contains("DATABASE=nt"))
        XCTAssertTrue(body.contains("MEGABLAST=on"))
        XCTAssertTrue(body.contains("FORMAT_TYPE=JSON2"))
        XCTAssertTrue(body.contains("TOOL=lungfish"))
    }

    func testSubmitWithoutMegablast() async throws {
        await mockClient.register(
            pattern: "blast/Blast.cgi",
            response: .text(mockSubmissionResponse(rid: "TEST456", rtoe: 60))
        )

        _ = try await service.submit(
            query: ">read1\nATGC",
            program: "blastp",
            database: "nr",
            entrezQuery: nil,
            evalue: 1e-5,
            maxTargetSeqs: 5,
            megablast: false
        )

        let requests = await mockClient.requests
        let body = String(data: requests[0].httpBody!, encoding: .utf8)!
        XCTAssertFalse(body.contains("MEGABLAST"))
        XCTAssertFalse(body.contains("ENTREZ_QUERY"))
    }

    func testSubmitHTTPError() async throws {
        await mockClient.register(
            pattern: "blast/Blast.cgi",
            response: .error(statusCode: 500, message: "Internal Server Error")
        )

        do {
            _ = try await service.submit(
                query: ">read1\nATGC",
                program: "blastn",
                database: "nt",
                entrezQuery: nil,
                evalue: 1e-10,
                maxTargetSeqs: 10,
                megablast: true
            )
            XCTFail("Expected error")
        } catch let error as BlastServiceError {
            if case .httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 500)
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - RID Parsing Tests

    func testRIDParsing() async throws {
        let response = mockSubmissionResponse(rid: "8KVDA5Y2014", rtoe: 45)
        let submission = try await service.parseSubmissionResponse(response)

        XCTAssertEqual(submission.rid, "8KVDA5Y2014")
        XCTAssertEqual(submission.rtoe, 45)
    }

    func testRIDParsingWithExtraWhitespace() async throws {
        let response = """
        <!DOCTYPE html>
        <html>
        <body>
        <!--QBlastInfoBegin
            RID =   ABCDEF123456
            RTOE =  120
        QBlastInfoEnd-->
        </body>
        </html>
        """

        let submission = try await service.parseSubmissionResponse(response)
        XCTAssertEqual(submission.rid, "ABCDEF123456")
        XCTAssertEqual(submission.rtoe, 120)
    }

    func testRIDParsingFailsWithoutRID() async throws {
        let response = """
        <!--QBlastInfoBegin
            RTOE = 30
        QBlastInfoEnd-->
        """

        do {
            _ = try await service.parseSubmissionResponse(response)
            XCTFail("Expected ridParsingFailed error")
        } catch let error as BlastServiceError {
            if case .ridParsingFailed = error {
                // Expected
            } else {
                XCTFail("Expected ridParsingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRIDParsingDefaultRTOE() async throws {
        let response = """
        <!--QBlastInfoBegin
            RID = MYRID123
        QBlastInfoEnd-->
        """

        let submission = try await service.parseSubmissionResponse(response)
        XCTAssertEqual(submission.rid, "MYRID123")
        XCTAssertEqual(submission.rtoe, 30) // default
    }

    // MARK: - Status Parsing Tests

    func testStatusParsingReady() async {
        let body = """
        <!--QBlastInfoBegin
            Status=READY
        QBlastInfoEnd-->
        """

        let status = await service.parseStatusResponse(body)
        XCTAssertEqual(status, .ready)
    }

    func testStatusParsingWaiting() async {
        let body = """
        <!--QBlastInfoBegin
            Status=WAITING
        QBlastInfoEnd-->
        """

        let status = await service.parseStatusResponse(body)
        XCTAssertEqual(status, .waiting)
    }

    func testStatusParsingFailed() async {
        let body = """
        <!--QBlastInfoBegin
            Status=FAILED
        QBlastInfoEnd-->
        """

        let status = await service.parseStatusResponse(body)
        if case .error(let message) = status {
            XCTAssertTrue(message.contains("FAILED"))
        } else {
            XCTFail("Expected error status")
        }
    }

    func testStatusParsingUnknown() async {
        let body = "Some random HTML without QBlastInfo"
        let status = await service.parseStatusResponse(body)
        XCTAssertEqual(status, .unknown)
    }

    // MARK: - JSON2 Parsing Tests

    func testParseBlastJSON2Response() async throws {
        let json = mockBlastJSON2Response()
        let data = json.data(using: .utf8)!

        let results = try await service.parseJSON2Results(data)

        XCTAssertEqual(results.count, 2)

        // First query
        let first = results[0]
        XCTAssertEqual(first.queryId, "read_001")
        XCTAssertEqual(first.queryLength, 150)
        XCTAssertEqual(first.hits.count, 2)
        XCTAssertEqual(first.hits[0].accession, "MN552435.1")
        XCTAssertEqual(first.hits[0].organism, "Oxbow virus")
        XCTAssertEqual(first.hits[0].hsps.count, 1)
        XCTAssertEqual(first.hits[0].hsps[0].identity, 148)
        XCTAssertEqual(first.hits[0].hsps[0].alignLength, 150)
        XCTAssertEqual(first.hits[0].hsps[0].bitScore, 270.0)
        XCTAssertEqual(first.hits[0].hsps[0].evalue, 1e-70)

        // Second query - no hits
        let second = results[1]
        XCTAssertEqual(second.queryId, "read_002")
        XCTAssertEqual(second.queryLength, 100)
        XCTAssertTrue(second.hits.isEmpty)
    }

    func testParseBlastJSON2WithHTMLWrapper() async throws {
        let json = mockBlastJSON2Response()
        let htmlWrapped = """
        <!DOCTYPE html>
        <html><body>
        <pre>\(json)</pre>
        </body></html>
        """
        let data = htmlWrapped.data(using: .utf8)!

        // The parser should extract JSON from the HTML wrapper
        let results = try await service.parseJSON2Results(data)
        XCTAssertEqual(results.count, 2)
    }

    func testParseBlastJSON2InvalidJSON() async {
        let data = "this is not json".data(using: .utf8)!

        do {
            _ = try await service.parseJSON2Results(data)
            XCTFail("Expected parsing error")
        } catch let error as BlastServiceError {
            if case .resultParsingFailed = error {
                // Expected
            } else {
                XCTFail("Expected resultParsingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testParseBlastJSON2MissingBlastOutput2() async {
        let json = "{\"other\": \"data\"}"
        let data = json.data(using: .utf8)!

        do {
            _ = try await service.parseJSON2Results(data)
            XCTFail("Expected parsing error")
        } catch let error as BlastServiceError {
            if case .resultParsingFailed(let msg) = error {
                XCTAssertTrue(msg.contains("BlastOutput2"))
            } else {
                XCTFail("Expected resultParsingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Verdict Assignment Tests

    func testVerdictVerified() async {
        let searchResult = BlastSearchResult(
            queryId: "read1",
            queryLength: 150,
            hits: [
                BlastHit(
                    accession: "MN552435.1",
                    title: "Oxbow virus segment 1",
                    organism: "Oxbow virus",
                    hsps: [
                        BlastHSP(
                            bitScore: 270.0,
                            evalue: 1e-70,
                            identity: 148,
                            alignLength: 150,
                            queryFrom: 1,
                            queryTo: 150
                        ),
                    ]
                ),
            ]
        )

        let results = await service.assignVerdicts(
            searchResults: [searchResult],
            eValueThreshold: 1e-10
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].verdict, .verified)
        XCTAssertEqual(results[0].topHitOrganism, "Oxbow virus")
        XCTAssertEqual(results[0].topHitAccession, "MN552435.1")
    }

    func testVerdictAmbiguousLowCoverage() async {
        // High identity but low query coverage -> ambiguous
        let searchResult = BlastSearchResult(
            queryId: "read2",
            queryLength: 150,
            hits: [
                BlastHit(
                    accession: "AB123456.1",
                    title: "Some virus",
                    organism: "Some virus",
                    hsps: [
                        BlastHSP(
                            bitScore: 100.0,
                            evalue: 1e-20,
                            identity: 95,
                            alignLength: 100,
                            queryFrom: 1,
                            queryTo: 100 // only 100/150 = 66% coverage
                        ),
                    ]
                ),
            ]
        )

        let results = await service.assignVerdicts(
            searchResults: [searchResult],
            eValueThreshold: 1e-10
        )

        XCTAssertEqual(results[0].verdict, .ambiguous)
    }

    func testVerdictAmbiguousLowIdentity() async {
        // Low identity but good coverage -> ambiguous
        let searchResult = BlastSearchResult(
            queryId: "read3",
            queryLength: 150,
            hits: [
                BlastHit(
                    accession: "CD789012.1",
                    title: "Another virus",
                    organism: "Another virus",
                    hsps: [
                        BlastHSP(
                            bitScore: 80.0,
                            evalue: 1e-15,
                            identity: 120, // 120/150 = 80% identity
                            alignLength: 150,
                            queryFrom: 1,
                            queryTo: 148  // ~99% coverage
                        ),
                    ]
                ),
            ]
        )

        let results = await service.assignVerdicts(
            searchResults: [searchResult],
            eValueThreshold: 1e-10
        )

        XCTAssertEqual(results[0].verdict, .ambiguous)
    }

    func testVerdictAmbiguousHighEValue() async {
        // Good identity and coverage but E-value above threshold -> ambiguous
        let searchResult = BlastSearchResult(
            queryId: "read4",
            queryLength: 150,
            hits: [
                BlastHit(
                    accession: "EF345678.1",
                    title: "Virus X",
                    organism: "Virus X",
                    hsps: [
                        BlastHSP(
                            bitScore: 50.0,
                            evalue: 1e-5, // above 1e-10 threshold
                            identity: 148,
                            alignLength: 150,
                            queryFrom: 1,
                            queryTo: 150
                        ),
                    ]
                ),
            ]
        )

        let results = await service.assignVerdicts(
            searchResults: [searchResult],
            eValueThreshold: 1e-10
        )

        XCTAssertEqual(results[0].verdict, .ambiguous)
    }

    func testVerdictUnverifiedNoHits() async {
        let searchResult = BlastSearchResult(
            queryId: "read5",
            queryLength: 150,
            hits: []
        )

        let results = await service.assignVerdicts(
            searchResults: [searchResult],
            eValueThreshold: 1e-10
        )

        XCTAssertEqual(results[0].verdict, .unverified)
        XCTAssertNil(results[0].topHitOrganism)
    }

    func testVerdictMixedResults() async {
        let searchResults = [
            // Verified: high identity, good coverage, low e-value
            BlastSearchResult(
                queryId: "read_a",
                queryLength: 150,
                hits: [
                    BlastHit(
                        accession: "ACC1",
                        title: "Target organism",
                        organism: "Target",
                        hsps: [BlastHSP(bitScore: 270.0, evalue: 0.0, identity: 149, alignLength: 150, queryFrom: 1, queryTo: 150)]
                    ),
                ]
            ),
            // Unverified: no hits
            BlastSearchResult(queryId: "read_b", queryLength: 100, hits: []),
            // Ambiguous: partial match
            BlastSearchResult(
                queryId: "read_c",
                queryLength: 200,
                hits: [
                    BlastHit(
                        accession: "ACC2",
                        title: "Related organism",
                        organism: "Related",
                        hsps: [BlastHSP(bitScore: 80.0, evalue: 1e-15, identity: 80, alignLength: 100, queryFrom: 1, queryTo: 100)]
                    ),
                ]
            ),
        ]

        let results = await service.assignVerdicts(searchResults: searchResults, eValueThreshold: 1e-10)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].verdict, .verified)
        XCTAssertEqual(results[1].verdict, .unverified)
        XCTAssertEqual(results[2].verdict, .ambiguous)
    }

    // MARK: - Subsample Tests

    func testSubsampleLongestFirst() async {
        let reads = makeTestReads(count: 10, baseLengths: [100, 200, 50, 300, 150, 250, 80, 120, 180, 90])

        let result = await service.subsampleReads(
            from: reads,
            strategy: .longestFirst(count: 3)
        )

        XCTAssertEqual(result.count, 3)
        // Should be the 3 longest: 300bp (read_3), 250bp (read_5), 200bp (read_1)
        XCTAssertTrue(result[0].sequence.count >= result[1].sequence.count)
        XCTAssertTrue(result[1].sequence.count >= result[2].sequence.count)
        XCTAssertEqual(result[0].sequence.count, 300)
        XCTAssertEqual(result[1].sequence.count, 250)
        XCTAssertEqual(result[2].sequence.count, 200)
    }

    func testSubsampleRandom() async {
        let reads = makeTestReads(count: 20, baseLengths: nil)

        let result = await service.subsampleReads(
            from: reads,
            strategy: .random(count: 5),
            seed: 42
        )

        XCTAssertEqual(result.count, 5)

        // Verify same seed gives same results
        let result2 = await service.subsampleReads(
            from: reads,
            strategy: .random(count: 5),
            seed: 42
        )

        XCTAssertEqual(result.map(\.id), result2.map(\.id))
    }

    func testSubsampleRandomDifferentSeeds() async {
        let reads = makeTestReads(count: 50, baseLengths: nil)

        let result1 = await service.subsampleReads(
            from: reads,
            strategy: .random(count: 10),
            seed: 42
        )

        let result2 = await service.subsampleReads(
            from: reads,
            strategy: .random(count: 10),
            seed: 99
        )

        // Different seeds should (very likely) produce different selections
        let ids1 = Set(result1.map(\.id))
        let ids2 = Set(result2.map(\.id))
        XCTAssertNotEqual(ids1, ids2)
    }

    func testSubsampleMixed() async {
        let reads = makeTestReads(
            count: 100,
            baseLengths: (0..<100).map { i in 50 + i * 3 }  // lengths 50, 53, 56, ... 347
        )

        let result = await service.subsampleReads(
            from: reads,
            strategy: .mixed(longest: 5, random: 15),
            seed: 12345
        )

        XCTAssertEqual(result.count, 20)

        // The first 5 should be the longest reads
        let longestFive = result.prefix(5)
        for read in longestFive {
            // The 5 longest are: indices 99, 98, 97, 96, 95
            // lengths: 347, 344, 341, 338, 335
            XCTAssertGreaterThanOrEqual(read.sequence.count, 335)
        }

        // Verify no duplicates
        let ids = result.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Subsample should not contain duplicates")
    }

    func testSubsampleFewerReadsThanRequested() async {
        let reads = makeTestReads(count: 3, baseLengths: [100, 200, 150])

        let result = await service.subsampleReads(
            from: reads,
            strategy: .mixed(longest: 5, random: 15)
        )

        // Should return all 3 reads
        XCTAssertEqual(result.count, 3)
    }

    func testSubsampleExactCountMatch() async {
        let reads = makeTestReads(count: 20, baseLengths: nil)

        let result = await service.subsampleReads(
            from: reads,
            strategy: .mixed(longest: 5, random: 15)
        )

        // Exactly 20 reads available, requesting 20
        XCTAssertEqual(result.count, 20)
    }

    func testSubsampleEmptyInput() async {
        let result = await service.subsampleReads(
            from: [],
            strategy: .mixed(longest: 5, random: 15)
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSubsampleSingleRead() async {
        let reads: [(id: String, sequence: String)] = [("read_0", "ATGCGATCGA")]

        let result = await service.subsampleReads(
            from: reads,
            strategy: .mixed(longest: 5, random: 15)
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "read_0")
    }

    // MARK: - Verify (Integration with Mock)

    func testVerifyNoSequencesThrows() async {
        let request = BlastVerificationRequest(
            taxonName: "Test",
            taxId: 1,
            sequences: []
        )

        do {
            _ = try await service.verify(request: request)
            XCTFail("Expected noSequences error")
        } catch let error as BlastServiceError {
            if case .noSequences = error {
                // Expected
            } else {
                XCTFail("Expected noSequences, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Error Model Tests

    func testBlastServiceErrorDescriptions() {
        let errors: [BlastServiceError] = [
            .submissionFailed(message: "Server busy"),
            .ridParsingFailed(responseBody: "<html>"),
            .timeout(rid: "ABC123", elapsed: 600),
            .jobFailed(rid: "DEF456", message: "Search expired"),
            .resultParsingFailed(message: "Invalid JSON"),
            .noSequences,
            .rateLimitExceeded(retryAfter: 30),
            .httpError(statusCode: 503, body: "Service Unavailable"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testTimeoutErrorContainsRID() {
        let error = BlastServiceError.timeout(rid: "XYZRID", elapsed: 600)
        let description = error.errorDescription!
        XCTAssertTrue(description.contains("XYZRID"))
    }

    // MARK: - BlastJobStatus Equatable

    func testJobStatusEquatable() {
        XCTAssertEqual(BlastJobStatus.waiting, BlastJobStatus.waiting)
        XCTAssertEqual(BlastJobStatus.ready, BlastJobStatus.ready)
        XCTAssertEqual(BlastJobStatus.unknown, BlastJobStatus.unknown)
        XCTAssertNotEqual(BlastJobStatus.waiting, BlastJobStatus.ready)
        XCTAssertEqual(BlastJobStatus.error(message: "x"), BlastJobStatus.error(message: "x"))
        XCTAssertNotEqual(BlastJobStatus.error(message: "x"), BlastJobStatus.error(message: "y"))
    }

    // MARK: - Helpers

    /// Creates test reads with specified or generated lengths.
    private func makeTestReads(
        count: Int,
        baseLengths: [Int]?
    ) -> [(id: String, sequence: String)] {
        (0..<count).map { i in
            let length = baseLengths?[i] ?? (100 + i * 10)
            let sequence = String(repeating: "ATGC", count: length / 4 + 1).prefix(length)
            return (id: "read_\(i)", sequence: String(sequence))
        }
    }

    /// Generates a mock NCBI BLAST submission response with QBlastInfo block.
    private func mockSubmissionResponse(rid: String, rtoe: Int) -> String {
        """
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" \
        "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>NCBI Blast</title></head>
        <body>
        <!--QBlastInfoBegin
            RID = \(rid)
            RTOE = \(rtoe)
        QBlastInfoEnd-->
        </body>
        </html>
        """
    }

    /// Generates a mock BLAST JSON2 response with 2 query results.
    private func mockBlastJSON2Response() -> String {
        """
        {
          "BlastOutput2": [
            {
              "report": {
                "program": "blastn",
                "version": "BLASTN 2.16.0+",
                "results": {
                  "search": {
                    "query_title": "read_001",
                    "query_len": 150,
                    "hits": [
                      {
                        "description": [
                          {
                            "title": "Oxbow virus segment 1, complete sequence",
                            "accession": "MN552435.1",
                            "sciname": "Oxbow virus"
                          }
                        ],
                        "hsps": [
                          {
                            "bit_score": 270.0,
                            "evalue": 1e-70,
                            "identity": 148,
                            "align_len": 150,
                            "query_from": 1,
                            "query_to": 150,
                            "hit_from": 1001,
                            "hit_to": 1150,
                            "qseq": "ATGCGATCGA",
                            "hseq": "ATGCGATCGA",
                            "midline": "||||||||||"
                          }
                        ]
                      },
                      {
                        "description": [
                          {
                            "title": "Hantaan virus strain 76-118, segment L",
                            "accession": "AB027523.1",
                            "sciname": "Hantaan virus"
                          }
                        ],
                        "hsps": [
                          {
                            "bit_score": 50.0,
                            "evalue": 1e-5,
                            "identity": 80,
                            "align_len": 100,
                            "query_from": 25,
                            "query_to": 124,
                            "hit_from": 500,
                            "hit_to": 599,
                            "qseq": "ATGCGATCGA",
                            "hseq": "ATGCGATCGA",
                            "midline": "|||| |||||"
                          }
                        ]
                      }
                    ]
                  }
                }
              }
            },
            {
              "report": {
                "program": "blastn",
                "version": "BLASTN 2.16.0+",
                "results": {
                  "search": {
                    "query_title": "read_002",
                    "query_len": 100,
                    "hits": []
                  }
                }
              }
            }
          ]
        }
        """
    }
}

// MARK: - SeededRandomNumberGenerator Tests

final class SeededRandomNumberGeneratorTests: XCTestCase {

    func testDeterministic() {
        var rng1 = SeededRandomNumberGenerator(seed: 42)
        var rng2 = SeededRandomNumberGenerator(seed: 42)

        for _ in 0..<100 {
            XCTAssertEqual(rng1.next(), rng2.next())
        }
    }

    func testDifferentSeeds() {
        var rng1 = SeededRandomNumberGenerator(seed: 42)
        var rng2 = SeededRandomNumberGenerator(seed: 43)

        var allSame = true
        for _ in 0..<10 {
            if rng1.next() != rng2.next() {
                allSame = false
                break
            }
        }
        XCTAssertFalse(allSame)
    }

    func testZeroSeedDoesNotDegenerate() {
        var rng = SeededRandomNumberGenerator(seed: 0)

        // With seed=0, the state is remapped to 1 to avoid xorshift degeneration
        var values = Set<UInt64>()
        for _ in 0..<100 {
            values.insert(rng.next())
        }
        // Should produce varied output, not stuck on 0
        XCTAssertGreaterThan(values.count, 50)
    }
}

// MARK: - buildVerificationRequest Tests

final class BlastBuildRequestTests: XCTestCase {

    private var service: BlastService!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        service = BlastService()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastBuildRequestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        service = nil
        try await super.tearDown()
    }

    func testNoClassificationFileThrowsNoSequences() async {
        let classURL = tempDir.appendingPathComponent("missing.kraken")
        let sourceURL = tempDir.appendingPathComponent("reads.fastq")

        do {
            _ = try await service.buildVerificationRequest(
                taxonName: "E. coli", taxId: 562,
                targetTaxIds: [562],
                classificationOutputURL: classURL,
                sourceURL: sourceURL
            )
            XCTFail("Expected noSequences error for missing classification file")
        } catch {
            XCTAssertTrue(error is BlastServiceError, "Expected BlastServiceError, got \(error)")
        }
    }

    func testMatchingIdsButMissingFASTQThrowsNoSequences() async throws {
        // Classification output has a matching read but FASTQ file is missing
        let classURL = tempDir.appendingPathComponent("output.kraken")
        try "C\tread_001\t562\t150\t562:150\n"
            .write(to: classURL, atomically: true, encoding: .utf8)

        let sourceURL = tempDir.appendingPathComponent("missing.fastq")

        do {
            _ = try await service.buildVerificationRequest(
                taxonName: "E. coli", taxId: 562,
                targetTaxIds: [562],
                classificationOutputURL: classURL,
                sourceURL: sourceURL
            )
            XCTFail("Expected noSequences when FASTQ is missing")
        } catch {
            XCTAssertTrue(error is BlastServiceError, "Expected BlastServiceError, got \(error)")
        }
    }

    func testMatchingIdsButNonMatchingFASTQThrowsNoSequences() async throws {
        // Classification output has matching read IDs but FASTQ has different reads
        let classURL = tempDir.appendingPathComponent("output.kraken")
        try "C\tread_001\t562\t150\t562:150\n"
            .write(to: classURL, atomically: true, encoding: .utf8)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try "@other_read\nATGC\n+\nIIII\n"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        do {
            _ = try await service.buildVerificationRequest(
                taxonName: "E. coli", taxId: 562,
                targetTaxIds: [562],
                classificationOutputURL: classURL,
                sourceURL: sourceURL
            )
            XCTFail("Expected noSequences when FASTQ reads don't match")
        } catch {
            XCTAssertTrue(error is BlastServiceError, "Expected BlastServiceError, got \(error)")
        }
    }

    func testSuccessfulBuildVerificationRequest() async throws {
        // Classification output with matching reads
        let classURL = tempDir.appendingPathComponent("output.kraken")
        var classLines = ""
        for i in 0..<25 {
            classLines += "C\tread_\(i)\t562\t150\t562:150\n"
        }
        try classLines.write(to: classURL, atomically: true, encoding: .utf8)

        // FASTQ with matching reads
        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        var fastqContent = ""
        for i in 0..<25 {
            let seq = String(repeating: "ATGC", count: 10 + i)
            let qual = String(repeating: "I", count: seq.count)
            fastqContent += "@read_\(i)\n\(seq)\n+\n\(qual)\n"
        }
        try fastqContent.write(to: sourceURL, atomically: true, encoding: .utf8)

        let request = try await service.buildVerificationRequest(
            taxonName: "E. coli", taxId: 562,
            targetTaxIds: [562],
            classificationOutputURL: classURL,
            sourceURL: sourceURL,
            readCount: 20
        )

        XCTAssertEqual(request.taxonName, "E. coli")
        XCTAssertEqual(request.taxId, 562)
        XCTAssertEqual(request.sequences.count, 20, "Should subsample to 20 reads")
    }

    func testPairedEndSuffixStripping() async throws {
        // Kraken2 output uses /1 suffix, FASTQ uses /1 suffix — both should be stripped
        let classURL = tempDir.appendingPathComponent("output.kraken")
        try "C\tread_001/1\t562\t150\t562:150\nC\tread_002/2\t562\t150\t562:150\n"
            .write(to: classURL, atomically: true, encoding: .utf8)

        let sourceURL = tempDir.appendingPathComponent("reads.fastq")
        try """
            @read_001/1 length=150
            ATGCATGCATGCATGCATGC
            +
            IIIIIIIIIIIIIIIIIIII
            @read_002/2 length=150
            GCTAGCTAGCTAGCTAGCTA
            +
            IIIIIIIIIIIIIIIIIIII

            """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let request = try await service.buildVerificationRequest(
            taxonName: "E. coli", taxId: 562,
            targetTaxIds: [562],
            classificationOutputURL: classURL,
            sourceURL: sourceURL,
            readCount: 20
        )

        XCTAssertEqual(request.sequences.count, 2)
    }

    func testGzipCompressedFASTQExtraction() async throws {
        // Classification output with matching reads
        let classURL = tempDir.appendingPathComponent("output.kraken")
        var classLines = ""
        for i in 0..<5 {
            classLines += "C\tread_\(i)\t562\t150\t562:150\n"
        }
        try classLines.write(to: classURL, atomically: true, encoding: .utf8)

        // Create uncompressed FASTQ, then gzip it
        let rawURL = tempDir.appendingPathComponent("reads.fastq")
        var fastqContent = ""
        for i in 0..<5 {
            let seq = String(repeating: "ATGC", count: 10)
            let qual = String(repeating: "I", count: seq.count)
            fastqContent += "@read_\(i)\n\(seq)\n+\n\(qual)\n"
        }
        try fastqContent.write(to: rawURL, atomically: true, encoding: .utf8)

        let gzURL = tempDir.appendingPathComponent("reads.fastq.gz")
        let gzipProc = Process()
        gzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzipProc.arguments = ["-c", rawURL.path]
        let outPipe = Pipe()
        gzipProc.standardOutput = outPipe
        try gzipProc.run()
        let compressed = outPipe.fileHandleForReading.readDataToEndOfFile()
        gzipProc.waitUntilExit()
        try compressed.write(to: gzURL)

        let request = try await service.buildVerificationRequest(
            taxonName: "E. coli", taxId: 562,
            targetTaxIds: [562],
            classificationOutputURL: classURL,
            sourceURL: gzURL,
            readCount: 20
        )

        XCTAssertEqual(request.sequences.count, 5, "Should extract all 5 reads from gzipped FASTQ")
    }
}
