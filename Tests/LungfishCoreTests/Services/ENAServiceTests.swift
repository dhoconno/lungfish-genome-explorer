// ENAServiceTests.swift - Tests for ENA Portal service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class ENAServiceTests: XCTestCase {

    var mockClient: MockHTTPClient!
    var service: ENAService!

    override func setUp() async throws {
        mockClient = MockHTTPClient()
        service = ENAService(httpClient: mockClient)
    }

    // MARK: - FetchFASTA Tests

    func testFetchFASTAReturnsSequence() async throws {
        let fastaContent = """
        >ENA|AB123456|AB123456.1 Test sequence
        ATGCATGCATGCATGC
        GCTAGCTAGCTAGCTA
        """
        await mockClient.registerENAFasta(fasta: fastaContent)

        let fasta = try await service.fetchFASTA(accession: "AB123456")

        XCTAssertTrue(fasta.contains(">ENA|AB123456"))
        XCTAssertTrue(fasta.contains("ATGCATGCATGCATGC"))
    }

    func testFetchFASTABuildsCorrectURL() async throws {
        await mockClient.registerENAFasta(fasta: ">test\nATG")

        _ = try await service.fetchFASTA(accession: "AB123456")

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("ebi.ac.uk"))
        XCTAssertTrue(url.contains("fasta"))
        XCTAssertTrue(url.contains("AB123456"))
    }

    // MARK: - FetchEMBL Tests

    func testFetchEMBLReturnsRecord() async throws {
        let emblContent = """
        ID   AB123456; SV 1; linear; genomic DNA; STD; VRL; 100 BP.
        XX
        AC   AB123456;
        XX
        DE   Test sequence
        //
        """
        await mockClient.register(pattern: "/embl/", response: .text(emblContent))

        let embl = try await service.fetchEMBL(accession: "AB123456")

        XCTAssertTrue(embl.contains("ID   AB123456"))
        XCTAssertTrue(embl.contains("Test sequence"))
    }

    // MARK: - FetchXML Tests

    func testFetchXMLReturnsRecord() async throws {
        let xmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <entry accession="AB123456" version="1">
            <description>Test sequence</description>
            <sequence>ATGCATGC</sequence>
        </entry>
        """
        await mockClient.register(pattern: "/xml/", response: .text(xmlContent))

        let xml = try await service.fetchXML(accession: "AB123456")

        XCTAssertTrue(xml.contains("AB123456"))
        XCTAssertTrue(xml.contains("<sequence>"))
    }

    // MARK: - Search Tests (DatabaseService Protocol)

    func testSearchReturnsResults() async throws {
        // ENA Portal API returns JSON array when format=json
        let searchResponse: [[String: Any]] = [
            [
                "accession": "AB123456",
                "description": "Test sequence 1",
                "base_count": 1000,
                "tax_id": 9606,
                "scientific_name": "Homo sapiens"
            ],
            [
                "accession": "AB789012",
                "description": "Test sequence 2",
                "base_count": 2000,
                "tax_id": 9606,
                "scientific_name": "Homo sapiens"
            ]
        ]
        await mockClient.register(pattern: "portal/api", response: .json(searchResponse))

        let query = SearchQuery(term: "test", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.records.count, 2)
        XCTAssertEqual(results.records[0].accession, "AB123456")
        XCTAssertEqual(results.records[1].accession, "AB789012")
    }

    func testSearchWithOrganismFilter() async throws {
        // ENA Portal API returns JSON array when format=json (empty in this case)
        await mockClient.register(pattern: "portal/api", response: .json([]))

        let query = SearchQuery(term: "genome", organism: "Homo sapiens", limit: 10)
        _ = try await service.search(query)

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("query=") || url.contains("Homo"))
    }

    // MARK: - Fetch Tests (DatabaseService Protocol)

    func testFetchReturnsRecord() async throws {
        await mockClient.registerENAFasta(fasta: ">AB123456 Test\nATGCATGC")

        let record = try await service.fetch(accession: "AB123456")

        XCTAssertEqual(record.accession, "AB123456")
        XCTAssertEqual(record.source, .ena)
        XCTAssertNotNil(record.sequence)
    }

    func testFetchBatchCancelsProducerWhenIterationIsCancelled() async throws {
        await mockClient.setResponseDelayNanoseconds(100_000_000)
        await mockClient.registerENAFasta(fasta: ">AB123456 Test\nATGCATGC")

        let stream = try await service.fetchBatch(accessions: ["AB123456", "AB789012"])
        let consumer = Task<DatabaseRecord?, Error> {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await waitForRecordedRequestCount(1)
        consumer.cancel()
        do {
            _ = try await consumer.value
        } catch is CancellationError {
            // Expected: cancelling iteration terminates the stream and producer.
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - Batch Lookup Tests

    func testSearchReadsBatchPropagatesCancellation() async throws {
        await mockClient.register(pattern: "filereport", response: .cancelled)

        do {
            _ = try await service.searchReadsBatch(
                accessions: ["SRR_CANCELLED"],
                concurrency: 1,
                progress: { _, _ in }
            )
            XCTFail("Expected cancellation to propagate")
        } catch let error as URLError where error.code == .cancelled {
            // Expected
        } catch {
            XCTFail("Expected URLError.cancelled, got \(error)")
        }
    }

    func testSearchReadsBatchSkipsIndividualNonCancellationFailures() async throws {
        let successfulResponse: [[String: Any]] = [
            [
                "run_accession": "ERR_OK",
                "library_layout": "SINGLE"
            ]
        ]
        await mockClient.registerSequence(
            pattern: "filereport",
            responses: [
                .error(statusCode: 500, message: "temporary ENA error"),
                .json(successfulResponse)
            ]
        )

        let progressRecorder = ProgressRecorder()
        let records = try await service.searchReadsBatch(
            accessions: ["ERR_FAILS", "ERR_OK"],
            concurrency: 1,
            progress: { completed, total in
                progressRecorder.append(completed: completed, total: total)
            }
        )

        let progressEvents = progressRecorder.events
        XCTAssertEqual(records.map(\.runAccession), ["ERR_OK"])
        XCTAssertEqual(progressEvents.map(\.0), [1, 2])
        XCTAssertTrue(progressEvents.allSatisfy { $0.1 == 2 })
    }

    func testSearchReadsBatchResolvesAllAccessionsHappyPath() async throws {
        for accession in ["DRR028938", "DRR051810", "DRR052292"] {
            let response: [[String: Any]] = [
                [
                    "run_accession": accession,
                    "library_layout": "PAIRED",
                    "instrument_platform": "ILLUMINA"
                ]
            ]
            await mockClient.register(pattern: "accession=\(accession)", response: .json(response))
        }

        let records = try await service.searchReadsBatch(
            accessions: ["DRR028938", "DRR051810", "DRR052292"],
            concurrency: 2,
            progress: { _, _ in }
        )

        XCTAssertEqual(records.count, 3)
        let resolvedAccessions = Set(records.map(\.runAccession))
        XCTAssertEqual(resolvedAccessions, Set(["DRR028938", "DRR051810", "DRR052292"]))
    }

    func testSearchReadsBatchEmptyAccessionsReturnsEmptyArrayWithoutRequests() async throws {
        let records = try await service.searchReadsBatch(accessions: [], concurrency: 5, progress: { _, _ in })

        XCTAssertTrue(records.isEmpty)
        let requests = await mockClient.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testENADateFormattersUsePOSIXLocale() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/LungfishCore/Services/ENA/ENAService.swift"),
            encoding: .utf8
        )

        let posixLocaleCount = source.components(separatedBy: #"Locale(identifier: "en_US_POSIX")"#).count - 1

        XCTAssertGreaterThanOrEqual(posixLocaleCount, 2)
    }

    func testENASearchRecordDecodesFirstPublicDate() throws {
        let data = """
        {
          "accession": "AB123456",
          "first_public": "2020-03-18"
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(ENASearchRecord.self, from: data)

        XCTAssertNotNil(record.firstPublic)
    }

    func testENAReadRecordDecodesFirstPublicDate() throws {
        let data = """
        {
          "run_accession": "ERR_OK",
          "first_public": "2020-03-18"
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(ENAReadRecord.self, from: data)

        XCTAssertNotNil(record.firstPublic)
    }

    // MARK: - Error Handling Tests

    func testHandles404Error() async throws {
        await mockClient.register(pattern: "/fasta/", response: .error(statusCode: 404, message: "Not Found"))

        do {
            _ = try await service.fetchFASTA(accession: "NONEXISTENT")
            XCTFail("Should have thrown an error")
        } catch let error as DatabaseServiceError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound error, got \(error)")
            }
        }
    }

    func testHandlesServerError() async throws {
        await mockClient.register(pattern: "/fasta/", response: .error(statusCode: 500, message: "Server Error"))

        do {
            _ = try await service.fetchFASTA(accession: "AB123456")
            XCTFail("Should have thrown an error")
        } catch let error as DatabaseServiceError {
            if case .serverError = error {
                // Expected
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        }
    }

    func testFetchFASTAMalformedEncodingThrowsParseError() async throws {
        // Invalid UTF-8 byte sequence cannot be decoded to a String.
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        await mockClient.register(pattern: "/fasta/", response: MockHTTPClient.MockResponse(data: invalidUTF8, statusCode: 200))

        do {
            _ = try await service.fetchFASTA(accession: "AB123456")
            XCTFail("Expected parseError to be thrown")
        } catch let error as DatabaseServiceError {
            if case .parseError = error {
                // Expected
            } else {
                XCTFail("Expected parseError, got \(error)")
            }
        }
    }

    // MARK: - Search Error Handling Tests

    func testSearchHTTPErrorThrows() async throws {
        await mockClient.register(pattern: "portal/api", response: .error(statusCode: 500, message: "Internal Server Error"))

        do {
            _ = try await service.search(SearchQuery(term: "test", limit: 10))
            XCTFail("Expected server error to be thrown")
        } catch let error as DatabaseServiceError {
            if case .serverError = error {
                // Expected
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        }
    }

    func testSearchMalformedPayloadThrowsDecodingError() async throws {
        await mockClient.register(pattern: "portal/api", response: .text("{not valid json"))

        do {
            _ = try await service.search(SearchQuery(term: "test", limit: 10))
            XCTFail("Expected malformed JSON to throw a decoding error")
        } catch is DecodingError {
            // Expected: search() decodes directly with JSONDecoder and does not
            // wrap decode failures in DatabaseServiceError.
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }
    }

    // MARK: - SearchReads Tests

    func testSearchReadsReturnsRecords() async throws {
        let response: [[String: Any]] = [
            [
                "run_accession": "DRR028938",
                "experiment_accession": "DRX026029",
                "sample_accession": "SAMD00027374",
                "study_accession": "PRJDB3502",
                "experiment_title": "Illumina HiSeq 2500 paired end sequencing",
                "library_layout": "PAIRED",
                "library_source": "GENOMIC",
                "library_strategy": "WGS",
                "instrument_platform": "ILLUMINA",
                "base_count": "189300000",
                "read_count": "631000",
                "fastq_ftp": "ftp.sra.ebi.ac.uk/vol1/fastq/DRR028/DRR028938/DRR028938_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/DRR028/DRR028938/DRR028938_2.fastq.gz",
                "fastq_bytes": "1234567;2345678",
                "fastq_md5": "abc123;def456",
                "first_public": "2015-06-01"
            ]
        ]
        await mockClient.register(pattern: "portal/api/filereport", response: .json(response))

        let records = try await service.searchReads(term: "DRR028938", limit: 10)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.runAccession, "DRR028938")
        XCTAssertEqual(record.libraryLayout, "PAIRED")
        XCTAssertTrue(record.isPaired)
        XCTAssertEqual(record.instrumentPlatform, "ILLUMINA")
        XCTAssertEqual(record.readCount, 631000)
        XCTAssertEqual(record.baseCount, 189300000)
        XCTAssertNotNil(record.fastqFTP)
        XCTAssertEqual(record.fastqHTTPURLs.count, 2)
        XCTAssertEqual(
            record.fastqHTTPURLs.first?.absoluteString,
            "https://ftp.sra.ebi.ac.uk/vol1/fastq/DRR028/DRR028938/DRR028938_1.fastq.gz"
        )
        XCTAssertEqual(record.totalFileSizeBytes, 1234567 + 2345678)
    }

    func testSearchReadsBuildsCorrectURL() async throws {
        await mockClient.register(pattern: "portal/api/filereport", response: .json([[String: Any]]()))

        _ = try await service.searchReads(term: "DRR028938", limit: 25, offset: 10)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        let url = try XCTUnwrap(requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("result=read_run"))
        XCTAssertTrue(url.contains("limit=25"))
        XCTAssertTrue(url.contains("offset=10"))
        XCTAssertTrue(url.contains("accession=DRR028938"))
    }

    func testSearchReadsEmptyDataReturnsEmptyArray() async throws {
        await mockClient.register(
            pattern: "portal/api/filereport",
            response: MockHTTPClient.MockResponse(data: Data(), statusCode: 200)
        )

        let records = try await service.searchReads(term: "NONEXISTENT", limit: 10)

        XCTAssertTrue(records.isEmpty)
    }

    func testSearchReadsNoResultsTextReturnsEmptyArray() async throws {
        await mockClient.register(pattern: "portal/api/filereport", response: .text("No results found for query"))

        let records = try await service.searchReads(term: "NONEXISTENT", limit: 10)

        XCTAssertTrue(records.isEmpty)
    }

    func testSearchReadsHTTPErrorThrows() async throws {
        await mockClient.register(pattern: "portal/api/filereport", response: .error(statusCode: 500, message: "Internal Server Error"))

        do {
            _ = try await service.searchReads(term: "DRR028938", limit: 10)
            XCTFail("Expected server error to be thrown")
        } catch let error as DatabaseServiceError {
            if case .serverError = error {
                // Expected
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        }
    }

    func testSearchReadsMalformedPayloadThrowsParseError() async throws {
        await mockClient.register(
            pattern: "portal/api/filereport",
            response: .text("{ this is not valid json and has no known status markers ]")
        )

        do {
            _ = try await service.searchReads(term: "DRR028938", limit: 10)
            XCTFail("Expected malformed payload to throw")
        } catch let error as DatabaseServiceError {
            if case .parseError = error {
                // Expected
            } else {
                XCTFail("Expected parseError, got \(error)")
            }
        } catch {
            XCTFail("Expected DatabaseServiceError.parseError, got \(error)")
        }
    }

    // MARK: - Service Properties Tests

    func testServiceName() async {
        XCTAssertEqual(service.name, "ENA")
    }

    func testServiceBaseURL() async {
        XCTAssertTrue(service.baseURL.absoluteString.contains("ebi.ac.uk"))
    }

    private func waitForRecordedRequestCount(
        _ expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if await mockClient.requests.count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actualCount = await mockClient.requests.count
        XCTFail("Timed out waiting for \(expectedCount) recorded request(s); saw \(actualCount)", file: file, line: line)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [(Int, Int)] = []

    var events: [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func append(completed: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append((completed, total))
    }
}
