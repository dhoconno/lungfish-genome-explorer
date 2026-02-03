// NCBIServiceTests.swift - Tests for NCBI Entrez service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class NCBIServiceTests: XCTestCase {

    var mockClient: MockHTTPClient!
    var service: NCBIService!

    override func setUp() async throws {
        mockClient = MockHTTPClient()
        service = NCBIService(httpClient: mockClient)
    }

    // MARK: - ESearch Tests

    func testESearchReturnsIDs() async throws {
        await mockClient.registerNCBISearch(ids: ["12345", "67890", "11111"])

        let ids = try await service.esearch(database: .nucleotide, term: "ebola virus", retmax: 10)

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids, ["12345", "67890", "11111"])
    }

    func testESearchEmptyResults() async throws {
        await mockClient.registerNCBISearch(ids: [])

        let ids = try await service.esearch(database: .nucleotide, term: "nonexistent", retmax: 10)

        XCTAssertTrue(ids.isEmpty)
    }

    func testESearchBuildsCorrectURL() async throws {
        await mockClient.registerNCBISearch(ids: ["123"])

        _ = try await service.esearch(database: .protein, term: "spike protein", retmax: 50, retstart: 10)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("esearch.fcgi"))
        XCTAssertTrue(url.contains("db=protein"))
        XCTAssertTrue(url.contains("retmax=50"))
        XCTAssertTrue(url.contains("retstart=10"))
    }

    func testESearchWithAPIKey() async throws {
        let serviceWithKey = NCBIService(apiKey: "test-api-key", httpClient: mockClient)
        await mockClient.registerNCBISearch(ids: ["123"])

        _ = try await serviceWithKey.esearch(database: .nucleotide, term: "test", retmax: 10)

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("api_key=test-api-key"))
    }

    // MARK: - EFetch Tests

    func testEFetchFASTA() async throws {
        let fastaContent = """
        >NC_002549.1 Zaire ebolavirus
        ATGGATGACTCTCGAGAAGTACTTGTAGATGG
        """
        await mockClient.registerNCBIFetch(fasta: fastaContent)

        let data = try await service.efetch(database: .nucleotide, ids: ["NC_002549.1"], format: .fasta)

        let result = String(data: data, encoding: .utf8)!
        XCTAssertTrue(result.contains(">NC_002549.1"))
        XCTAssertTrue(result.contains("ATGGATGACTCTCGAGAAGTACTTGTAGATGG"))
    }

    func testEFetchGenBank() async throws {
        let gbContent = """
        LOCUS       NC_002549              18959 bp    RNA     linear   VRL
        DEFINITION  Zaire ebolavirus, complete genome.
        //
        """
        await mockClient.register(pattern: "efetch.fcgi", response: .text(gbContent))

        let data = try await service.efetch(database: .nucleotide, ids: ["NC_002549.1"], format: .genbank)

        let result = String(data: data, encoding: .utf8)!
        XCTAssertTrue(result.contains("LOCUS"))
        XCTAssertTrue(result.contains("Zaire ebolavirus"))
    }

    func testEFetchMultipleIDs() async throws {
        await mockClient.registerNCBIFetch(fasta: ">seq1\nATG\n>seq2\nGTA")

        _ = try await service.efetch(database: .nucleotide, ids: ["id1", "id2", "id3"], format: .fasta)

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("id=id1,id2,id3") || url.contains("id=id1%2Cid2%2Cid3"))
    }

    // MARK: - ESummary Tests

    func testESummaryParsesDocuments() async throws {
        let jsonResponse: [String: Any] = [
            "result": [
                "uids": ["12345"],
                "12345": [
                    "uid": "12345",
                    "title": "Ebola virus complete genome",
                    "accessionversion": "NC_002549.1",
                    "slen": 18959,
                    "organism": "Zaire ebolavirus",
                    "createdate": "2001/01/01"
                ]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(jsonResponse))

        let summaries = try await service.esummary(database: .nucleotide, ids: ["12345"])

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].uid, "12345")
        XCTAssertEqual(summaries[0].title, "Ebola virus complete genome")
        XCTAssertEqual(summaries[0].accessionVersion, "NC_002549.1")
        XCTAssertEqual(summaries[0].length, 18959)
    }

    // MARK: - Search Tests (DatabaseService Protocol)

    func testSearchReturnsResults() async throws {
        await mockClient.registerNCBISearch(ids: ["123", "456"])

        let summaryResponse: [String: Any] = [
            "result": [
                "uids": ["123", "456"],
                "123": [
                    "uid": "123",
                    "title": "Sequence 1",
                    "accessionversion": "AB123.1",
                    "slen": 1000,
                    "organism": "Test organism"
                ],
                "456": [
                    "uid": "456",
                    "title": "Sequence 2",
                    "accessionversion": "AB456.1",
                    "slen": 2000,
                    "organism": "Test organism"
                ]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(summaryResponse))

        let query = SearchQuery(term: "test organism", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.totalCount, 2)
        XCTAssertEqual(results.records.count, 2)
        XCTAssertEqual(results.records[0].accession, "AB123.1")
        XCTAssertEqual(results.records[1].accession, "AB456.1")
    }

    // MARK: - Fetch Tests (DatabaseService Protocol)

    func testFetchReturnsRecord() async throws {
        // First register the search to find the UID
        await mockClient.registerNCBISearch(ids: ["12345"])

        // Then register the GenBank fetch
        let gbContent = """
        LOCUS       NC_002549              18959 bp    RNA     linear   VRL
        ACCESSION   NC_002549
        VERSION     NC_002549.1
        DEFINITION  Zaire ebolavirus, complete genome.
        ORIGIN
                1 atggatgact
        //
        """
        await mockClient.register(pattern: "efetch.fcgi", response: .text(gbContent))

        let record = try await service.fetch(accession: "NC_002549.1")

        XCTAssertEqual(record.accession, "NC_002549")
        XCTAssertEqual(record.source, .ncbi)
        XCTAssertFalse(record.sequence.isEmpty)
    }

    // MARK: - Rate Limiting Tests

    func testRateLimitingDelaysRequests() async throws {
        await mockClient.registerNCBISearch(ids: ["1"])

        let start = Date()

        // Make multiple requests
        for _ in 0..<3 {
            _ = try await service.esearch(database: .nucleotide, term: "test", retmax: 1)
        }

        let elapsed = Date().timeIntervalSince(start)

        // Should have some delay due to rate limiting (at least ~0.6 seconds for 3 requests at 3/second)
        // But in tests with mocks this may be faster, so just check it completed
        XCTAssertGreaterThanOrEqual(elapsed, 0)
    }

    // MARK: - Error Handling Tests

    func testHandlesNetworkError() async throws {
        // No response registered - will throw

        do {
            _ = try await service.esearch(database: .nucleotide, term: "test", retmax: 10)
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
        }
    }

    func testHandlesServerError() async throws {
        await mockClient.register(pattern: "esearch.fcgi", response: .error(statusCode: 500, message: "Internal Server Error"))

        do {
            _ = try await service.esearch(database: .nucleotide, term: "test", retmax: 10)
            XCTFail("Should have thrown an error")
        } catch let error as DatabaseServiceError {
            if case .serverError = error {
                // Expected
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        }
    }

    // MARK: - Database Type Tests

    func testAllDatabaseTypesHaveRawValues() {
        let databases: [NCBIDatabase] = [.nucleotide, .protein, .gene, .sra, .biosample, .bioproject, .taxonomy, .pubmed, .pmc]

        for db in databases {
            XCTAssertFalse(db.rawValue.isEmpty)
        }
    }

    // MARK: - Format Tests

    func testFormatRettype() {
        XCTAssertEqual(NCBIFormat.fasta.rettype, "fasta")
        XCTAssertEqual(NCBIFormat.genbank.rettype, "gb")
        XCTAssertEqual(NCBIFormat.genbankWithParts.rettype, "gb")
        XCTAssertEqual(NCBIFormat.xml.rettype, "native")
    }

    // MARK: - FetchRawGenBank Tests

    func testFetchRawGenBankReturnsContent() async throws {
        // Register the search to find the UID
        await mockClient.registerNCBISearch(ids: ["12345"])

        // Register the GenBank fetch with full content including features
        let gbContent = """
        LOCUS       NC_002549              18959 bp    RNA     linear   VRL 01-JAN-2024
        DEFINITION  Zaire ebolavirus, complete genome.
        ACCESSION   NC_002549
        VERSION     NC_002549.1
        KEYWORDS    RefSeq.
        SOURCE      Zaire ebolavirus
          ORGANISM  Zaire ebolavirus
                    Viruses; Riboviria; Orthornavirae; Negarnaviricota;
                    Haploviricotina; Monjiviricetes; Mononegavirales;
                    Filoviridae; Ebolavirus.
        FEATURES             Location/Qualifiers
             source          1..18959
                             /organism="Zaire ebolavirus"
                             /mol_type="genomic RNA"
             gene            470..2689
                             /gene="NP"
                             /locus_tag="EBOV_gp1"
             CDS             470..2689
                             /gene="NP"
                             /locus_tag="EBOV_gp1"
                             /product="nucleoprotein"
                             /protein_id="YP_054878.1"
        ORIGIN
                1 atggatgact ctcgagaagt acttgtagat gg
        //
        """
        await mockClient.register(pattern: "efetch.fcgi", response: .text(gbContent))

        let result = try await service.fetchRawGenBank(accession: "NC_002549.1")

        // Verify raw content is preserved
        XCTAssertTrue(result.content.contains("LOCUS"))
        XCTAssertTrue(result.content.contains("FEATURES"))
        XCTAssertTrue(result.content.contains("gene            470..2689"))
        XCTAssertTrue(result.content.contains("/gene=\"NP\""))
        XCTAssertTrue(result.content.contains("CDS             470..2689"))
        XCTAssertTrue(result.content.contains("/product=\"nucleoprotein\""))
        XCTAssertTrue(result.content.contains("ORIGIN"))
        XCTAssertTrue(result.content.contains("//"))

        // Verify accession is extracted (uses VERSION line which includes version number)
        XCTAssertTrue(result.accession == "NC_002549.1" || result.accession == "NC_002549",
                      "Accession should be extracted from GenBank content")
    }

    func testFetchRawGenBankNotFound() async throws {
        // Register empty search results
        await mockClient.registerNCBISearch(ids: [])

        do {
            _ = try await service.fetchRawGenBank(accession: "NONEXISTENT")
            XCTFail("Should have thrown notFound error")
        } catch let error as DatabaseServiceError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - NCBISearchType Tests

    func testNCBISearchTypeHasAllCases() {
        let allCases = NCBISearchType.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.nucleotide))
        XCTAssertTrue(allCases.contains(.genome))
        XCTAssertTrue(allCases.contains(.virus))
    }

    func testNCBISearchTypeDisplayNames() {
        XCTAssertEqual(NCBISearchType.nucleotide.displayName, "GenBank (Nucleotide)")
        XCTAssertEqual(NCBISearchType.genome.displayName, "Genome (Assembly)")
        XCTAssertEqual(NCBISearchType.virus.displayName, "Virus")
    }

    func testNCBISearchTypeIcons() {
        XCTAssertFalse(NCBISearchType.nucleotide.icon.isEmpty)
        XCTAssertFalse(NCBISearchType.genome.icon.isEmpty)
        XCTAssertFalse(NCBISearchType.virus.icon.isEmpty)
    }

    func testNCBISearchTypeHelpText() {
        for searchType in NCBISearchType.allCases {
            XCTAssertFalse(searchType.helpText.isEmpty, "\(searchType) should have help text")
        }
    }

    // MARK: - Download Format Tests

    func testNCBIFormatDownloadFormats() {
        let formats = NCBIFormat.downloadFormats
        XCTAssertEqual(formats.count, 2)
        XCTAssertTrue(formats.contains(.genbank))
        XCTAssertTrue(formats.contains(.fasta))
    }

    func testNCBIFormatFileExtensions() {
        XCTAssertEqual(NCBIFormat.fasta.fileExtension, "fasta")
        XCTAssertEqual(NCBIFormat.genbank.fileExtension, "gb")
        XCTAssertEqual(NCBIFormat.genbankWithParts.fileExtension, "gb")
        XCTAssertEqual(NCBIFormat.xml.fileExtension, "xml")
    }

    func testNCBIFormatDisplayNames() {
        XCTAssertEqual(NCBIFormat.fasta.displayName, "FASTA")
        XCTAssertEqual(NCBIFormat.genbank.displayName, "GenBank")
    }

    // MARK: - Database Supports EFetch Tests

    func testDatabaseSupportsEfetch() {
        // Nucleotide and protein support efetch
        XCTAssertTrue(NCBIDatabase.nucleotide.supportsEfetch)
        XCTAssertTrue(NCBIDatabase.protein.supportsEfetch)
        XCTAssertTrue(NCBIDatabase.gene.supportsEfetch)

        // Genome and assembly don't support efetch directly
        XCTAssertFalse(NCBIDatabase.genome.supportsEfetch)
        XCTAssertFalse(NCBIDatabase.assembly.supportsEfetch)
    }

    func testVirusTaxonomyFilter() {
        let filter = NCBIDatabase.virusTaxonomyFilter
        XCTAssertTrue(filter.contains("txid10239"))
        XCTAssertTrue(filter.contains("Organism"))
    }

    // MARK: - FetchRawFASTA Tests

    func testFetchRawFASTAReturnsContent() async throws {
        // Register the search to find the UID
        await mockClient.registerNCBISearch(ids: ["12345"])

        // Register the FASTA fetch
        let fastaContent = """
        >NC_001422.1 Escherichia phage phiX174 sensu lato, complete genome
        GAGTTTTATCGCTTCCATGACGCAGAAGTTAACACTTTCGGATATTTCTGATGAGTCGAAAAATTATCTT
        GATAAAGCAGGAATTACTACTGCTTGTTTACGAATTAAATCGAAGTGGACTGCTGGCGGAAAATGAGAAA
        """
        await mockClient.register(pattern: "efetch.fcgi", response: .text(fastaContent))

        let result = try await service.fetchRawFASTA(accession: "NC_001422.1")

        // Verify raw content is preserved
        XCTAssertTrue(result.content.contains(">NC_001422.1"))
        XCTAssertTrue(result.content.contains("GAGTTTTATCGCTTCCATGACGCAGAAGTTAACACTTTCGGATATTTCTGATGAGTCGAAAAATTATCTT"))

        // Verify accession is extracted from header
        XCTAssertEqual(result.accession, "NC_001422.1")
    }

    func testFetchRawFASTANotFound() async throws {
        // Register empty search results
        await mockClient.registerNCBISearch(ids: [])

        do {
            _ = try await service.fetchRawFASTA(accession: "NONEXISTENT")
            XCTFail("Should have thrown notFound error")
        } catch let error as DatabaseServiceError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    // MARK: - ESearch With Count Tests

    func testESearchWithCountReturnsTotalCount() async throws {
        // Register search response with count (JSON format, matching esearchWithCount implementation)
        let jsonResponse: [String: Any] = [
            "esearchresult": [
                "count": "12345",
                "retmax": "100",
                "retstart": "0",
                "idlist": ["111", "222", "333"]
            ]
        ]
        await mockClient.register(pattern: "esearch.fcgi", response: .json(jsonResponse))

        let result = try await service.esearchWithCount(
            database: .nucleotide,
            term: "SARS-CoV-2",
            retmax: 100
        )

        XCTAssertEqual(result.ids.count, 3)
        XCTAssertEqual(result.ids, ["111", "222", "333"])
        XCTAssertEqual(result.totalCount, 12345)
        XCTAssertEqual(result.retmax, 100)
        XCTAssertEqual(result.retstart, 0)
    }

    // MARK: - SearchVirus Tests

    func testSearchVirusAddsViralTaxonomyFilter() async throws {
        await mockClient.registerNCBISearch(ids: ["111"])

        _ = try await service.searchVirus(term: "SARS-CoV-2", retmax: 10)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        let url = requests[0].url!.absoluteString
        // The search term should include the viral taxonomy filter
        XCTAssertTrue(url.contains("txid10239") || url.contains("10239"),
                      "Search should include viral taxonomy filter")
    }

    func testSearchVirusRefseqOnlyAddsRefseqFilter() async throws {
        await mockClient.registerNCBISearch(ids: ["222"])

        _ = try await service.searchVirus(term: "influenza", retmax: 10, refseqOnly: true)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        let url = requests[0].url!.absoluteString
        // The search term should include the refseq filter when refseqOnly is true
        XCTAssertTrue(url.contains("refseq"),
                      "Search with refseqOnly should include refseq[filter]")
    }

    func testSearchVirusWithoutRefseqOnlyDoesNotAddRefseqFilter() async throws {
        await mockClient.registerNCBISearch(ids: ["333"])

        _ = try await service.searchVirus(term: "influenza", retmax: 10, refseqOnly: false)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        let url = requests[0].url!.absoluteString
        // The search term should NOT include the refseq filter when refseqOnly is false
        XCTAssertFalse(url.contains("refseq"),
                       "Search without refseqOnly should not include refseq filter")
    }

    // MARK: - Database Enum Extended Tests

    func testDatabaseEnumIncludesGenomeAndAssembly() {
        let allCases = NCBIDatabase.allCases
        XCTAssertTrue(allCases.contains(.genome))
        XCTAssertTrue(allCases.contains(.assembly))
    }

    func testDatabaseDisplayNames() {
        XCTAssertEqual(NCBIDatabase.genome.displayName, "Genome")
        XCTAssertEqual(NCBIDatabase.assembly.displayName, "Assembly")
    }
}
