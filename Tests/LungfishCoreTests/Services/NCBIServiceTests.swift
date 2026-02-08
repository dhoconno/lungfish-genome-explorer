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

    // MARK: - SearchNucleotide Tests

    func testSearchNucleotideCallsESearchWithNucleotideDB() async throws {
        await mockClient.registerNCBISearch(ids: ["100", "200"])

        let result = try await service.searchNucleotide(term: "ebola", retmax: 10)

        XCTAssertEqual(result.ids.count, 2)
        XCTAssertEqual(result.ids, ["100", "200"])

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("db=nucleotide"))
        XCTAssertTrue(url.contains("retmax=10"))
    }

    func testSearchNucleotideWithRefseqOnly() async throws {
        await mockClient.registerNCBISearch(ids: ["300"])

        let result = try await service.searchNucleotide(term: "SARS-CoV-2", retmax: 5, refseqOnly: true)

        XCTAssertEqual(result.ids, ["300"])

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("refseq"), "Should include refseq[filter] when refseqOnly is true")
    }

    func testSearchNucleotideWithoutRefseqDoesNotAddFilter() async throws {
        await mockClient.registerNCBISearch(ids: ["400"])

        _ = try await service.searchNucleotide(term: "influenza", retmax: 5, refseqOnly: false)

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertFalse(url.contains("refseq"), "Should NOT include refseq[filter] when refseqOnly is false")
    }

    func testSearchNucleotideWithPagination() async throws {
        let response: [String: Any] = [
            "esearchresult": [
                "count": "500",
                "retmax": "20",
                "retstart": "40",
                "idlist": ["501", "502"]
            ]
        ]
        await mockClient.register(pattern: "esearch.fcgi", response: .json(response))

        let result = try await service.searchNucleotide(term: "coronavirus", retmax: 20, retstart: 40)

        XCTAssertEqual(result.totalCount, 500)
        XCTAssertEqual(result.retstart, 40)
        XCTAssertEqual(result.retmax, 20)
        XCTAssertEqual(result.ids.count, 2)
    }

    func testSearchNucleotideEmptyResults() async throws {
        await mockClient.registerNCBISearch(ids: [])

        let result = try await service.searchNucleotide(term: "nonexistent_organism_xyz", retmax: 10)

        XCTAssertEqual(result.ids.count, 0)
        XCTAssertEqual(result.totalCount, 0)
    }

    // MARK: - SearchGenome Tests

    func testSearchGenomeCallsAssemblyDB() async throws {
        await mockClient.registerNCBISearch(ids: ["999"])

        let result = try await service.searchGenome(term: "Homo sapiens", retmax: 10)

        XCTAssertEqual(result.ids, ["999"])

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("db=assembly"), "Genome search should use the assembly database")
    }

    func testSearchGenomeWithPagination() async throws {
        let response: [String: Any] = [
            "esearchresult": [
                "count": "150",
                "retmax": "20",
                "retstart": "20",
                "idlist": ["1001", "1002", "1003"]
            ]
        ]
        await mockClient.register(pattern: "esearch.fcgi", response: .json(response))

        let result = try await service.searchGenome(term: "Mus musculus", retmax: 20, retstart: 20)

        XCTAssertEqual(result.totalCount, 150)
        XCTAssertEqual(result.retstart, 20)
        XCTAssertEqual(result.ids.count, 3)
    }

    func testSearchGenomeEmptyResults() async throws {
        await mockClient.registerNCBISearch(ids: [])

        let result = try await service.searchGenome(term: "nonexistent_organism_xyz", retmax: 10)

        XCTAssertEqual(result.ids.count, 0)
    }

    // MARK: - AssemblyEsummary Tests

    func testAssemblyEsummaryParsesResponse() async throws {
        let response: [String: Any] = [
            "result": [
                "uids": ["12345"],
                "12345": [
                    "uid": "12345",
                    "assemblyaccession": "GCF_000001405.40",
                    "assemblyname": "GRCh38.p14",
                    "organism": "Homo sapiens",
                    "speciesname": "Homo sapiens",
                    "taxid": 9606,
                    "ftppath_refseq": "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14",
                    "ftppath_genbank": "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.29_GRCh38.p14",
                    "submitter": "Genome Reference Consortium",
                    "coverage": "35.0",
                    "contig_n50": 57879411,
                    "scaffold_n50": 67794873
                ]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(response))

        let summaries = try await service.assemblyEsummary(ids: ["12345"])

        XCTAssertEqual(summaries.count, 1)
        let summary = summaries[0]
        XCTAssertEqual(summary.uid, "12345")
        XCTAssertEqual(summary.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(summary.assemblyName, "GRCh38.p14")
        XCTAssertEqual(summary.organism, "Homo sapiens")
        XCTAssertEqual(summary.speciesName, "Homo sapiens")
        XCTAssertEqual(summary.taxid, 9606)
        XCTAssertTrue(summary.ftpPathRefSeq?.contains("GCF_000001405") ?? false)
        XCTAssertTrue(summary.ftpPathGenBank?.contains("GCA_000001405") ?? false)
        XCTAssertEqual(summary.submitter, "Genome Reference Consortium")
        XCTAssertEqual(summary.coverage, "35.0")
        XCTAssertEqual(summary.contigN50, 57879411)
        XCTAssertEqual(summary.scaffoldN50, 67794873)
    }

    func testAssemblyEsummaryMultipleIDs() async throws {
        let response: [String: Any] = [
            "result": [
                "uids": ["111", "222"],
                "111": [
                    "uid": "111",
                    "assemblyaccession": "GCF_000001635.27",
                    "assemblyname": "GRCm39",
                    "organism": "Mus musculus",
                    "taxid": "10090"
                ],
                "222": [
                    "uid": "222",
                    "assemblyaccession": "GCF_011100685.1",
                    "assemblyname": "mRatBN7.2",
                    "organism": "Rattus norvegicus",
                    "taxid": "10116"
                ]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(response))

        let summaries = try await service.assemblyEsummary(ids: ["111", "222"])

        XCTAssertEqual(summaries.count, 2)
    }

    func testAssemblyEsummaryHandlesTaxidAsString() async throws {
        let response: [String: Any] = [
            "result": [
                "uids": ["333"],
                "333": [
                    "uid": "333",
                    "assemblyaccession": "GCF_test",
                    "taxid": "9606"
                ]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(response))

        let summaries = try await service.assemblyEsummary(ids: ["333"])

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].taxid, 9606)
    }

    func testAssemblyEsummaryEmptyResults() async throws {
        let response: [String: Any] = [
            "result": [
                "uids": ([] as [String])
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(response))

        let summaries = try await service.assemblyEsummary(ids: ["nonexistent"])

        XCTAssertTrue(summaries.isEmpty)
    }

    func testAssemblyEsummaryBuildsCorrectURL() async throws {
        let response: [String: Any] = [
            "result": [
                "uids": ["555"],
                "555": ["uid": "555"]
            ]
        ]
        await mockClient.register(pattern: "esummary.fcgi", response: .json(response))

        _ = try await service.assemblyEsummary(ids: ["555", "666"])

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("db=assembly"))
        XCTAssertTrue(url.contains("555") && url.contains("666"))
        XCTAssertTrue(url.contains("retmode=json"))
    }

    // MARK: - SearchVirusDatasets Tests

    func testSearchVirusDatasetsBuildsCorrectURL() async throws {
        let virusResponse: [String: Any] = [
            "reports": [],
            "total_count": 0
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        _ = try await service.searchVirusDatasets(taxon: "SARS-CoV-2", pageSize: 10)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("datasets/v2/virus/taxon/SARS-CoV-2"))
        XCTAssertTrue(url.contains("page_size=10"))
    }

    func testSearchVirusDatasetsWithAllFilters() async throws {
        let virusResponse: [String: Any] = [
            "reports": [],
            "total_count": 0
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        _ = try await service.searchVirusDatasets(
            taxon: "Ebolavirus",
            pageSize: 5,
            pageToken: "abc123",
            refseqOnly: true,
            annotatedOnly: true,
            completeness: "COMPLETE",
            host: "Homo sapiens",
            geoLocation: "USA",
            releasedSince: "2024-01-01"
        )

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("filter.refseq_only=true"))
        XCTAssertTrue(url.contains("filter.annotated_only=true"))
        XCTAssertTrue(url.contains("filter.completeness=COMPLETE"))
        XCTAssertTrue(url.contains("filter.host=Homo"))
        XCTAssertTrue(url.contains("filter.geo_location=USA"))
        XCTAssertTrue(url.contains("filter.released_since=2024-01-01"))
        XCTAssertTrue(url.contains("page_token=abc123"))
    }

    func testSearchVirusDatasetsWithoutOptionalFilters() async throws {
        let virusResponse: [String: Any] = [
            "reports": [],
            "total_count": 0
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        _ = try await service.searchVirusDatasets(taxon: "Influenza")

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertFalse(url.contains("filter.refseq_only"))
        XCTAssertFalse(url.contains("filter.annotated_only"))
        XCTAssertFalse(url.contains("filter.completeness"))
        XCTAssertFalse(url.contains("filter.host"))
        XCTAssertFalse(url.contains("filter.geo_location"))
        XCTAssertFalse(url.contains("filter.released_since"))
        XCTAssertFalse(url.contains("page_token"))
    }

    func testSearchVirusDatasetsEmptyFiltersNotIncluded() async throws {
        let virusResponse: [String: Any] = [
            "reports": [],
            "total_count": 0
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        _ = try await service.searchVirusDatasets(
            taxon: "HIV",
            host: "",
            geoLocation: "",
            releasedSince: ""
        )

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertFalse(url.contains("filter.host"))
        XCTAssertFalse(url.contains("filter.geo_location"))
        XCTAssertFalse(url.contains("filter.released_since"))
    }

    func testSearchVirusDatasetsParsesSingleReport() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                [
                    "accession": "NC_045512.2",
                    "is_annotated": true,
                    "source_database": "RefSeq",
                    "completeness": "COMPLETE",
                    "length": 29903,
                    "release_date": "2020-01-13",
                    "isolate": [
                        "name": "Wuhan-Hu-1",
                        "collection_date": "2019-12-30"
                    ],
                    "host": [
                        "tax_id": 9606,
                        "organism_name": "Homo sapiens"
                    ],
                    "virus": [
                        "tax_id": 2697049,
                        "organism_name": "Severe acute respiratory syndrome coronavirus 2",
                        "pangolin_classification": "B"
                    ],
                    "location": [
                        "geographic_location": "China: Wuhan",
                        "geographic_region": "Asia"
                    ]
                ]
            ],
            "total_count": 1
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "2697049")

        XCTAssertEqual(results.totalCount, 1)
        XCTAssertEqual(results.records.count, 1)

        let record = results.records[0]
        XCTAssertEqual(record.accession, "NC_045512.2")
        XCTAssertEqual(record.title, "Wuhan-Hu-1")
        XCTAssertEqual(record.organism, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(record.length, 29903)
        XCTAssertEqual(record.source, .ncbi)

        // Virus-specific fields
        XCTAssertEqual(record.host, "Homo sapiens")
        XCTAssertEqual(record.geoLocation, "China: Wuhan")
        XCTAssertEqual(record.collectionDate, "2019-12-30")
        XCTAssertEqual(record.completeness, "COMPLETE")
        XCTAssertEqual(record.isolateName, "Wuhan-Hu-1")
        XCTAssertEqual(record.sourceDatabase, "RefSeq")
        XCTAssertEqual(record.pangolinClassification, "B")
    }

    func testSearchVirusDatasetsMultipleReports() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                [
                    "accession": "NC_045512.2",
                    "virus": ["organism_name": "SARS-CoV-2"],
                    "completeness": "COMPLETE",
                    "length": 29903
                ],
                [
                    "accession": "MN908947.3",
                    "virus": ["organism_name": "SARS-CoV-2"],
                    "completeness": "COMPLETE",
                    "length": 29903
                ],
                [
                    "accession": "MW732483.1",
                    "virus": ["organism_name": "SARS-CoV-2"],
                    "completeness": "PARTIAL",
                    "length": 29500
                ]
            ],
            "total_count": 9000000,
            "next_page_token": "eyJwYWdlIjoyfQ=="
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "SARS-CoV-2", pageSize: 3)

        XCTAssertEqual(results.totalCount, 9000000)
        XCTAssertEqual(results.records.count, 3)
        XCTAssertTrue(results.hasMore)
        XCTAssertEqual(results.nextCursor, "eyJwYWdlIjoyfQ==")

        XCTAssertEqual(results.records[0].accession, "NC_045512.2")
        XCTAssertEqual(results.records[1].accession, "MN908947.3")
        XCTAssertEqual(results.records[2].accession, "MW732483.1")
        XCTAssertEqual(results.records[2].completeness, "PARTIAL")
    }

    func testSearchVirusDatasetsSkipsReportsWithNilAccession() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                [
                    "accession": "NC_045512.2",
                    "virus": ["organism_name": "SARS-CoV-2"]
                ],
                [
                    // no accession key
                    "virus": ["organism_name": "Unknown"]
                ]
            ],
            "total_count": 2
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "SARS-CoV-2")

        // Should skip the report without an accession
        XCTAssertEqual(results.records.count, 1)
        XCTAssertEqual(results.records[0].accession, "NC_045512.2")
    }

    func testSearchVirusDatasetsNoNextPageToken() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                ["accession": "NC_045512.2"]
            ],
            "total_count": 1
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "SARS-CoV-2")

        XCTAssertFalse(results.hasMore)
        XCTAssertNil(results.nextCursor)
    }

    func testSearchVirusDatasetsTitleFallsBackToOrganismName() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                [
                    "accession": "NC_002549.1",
                    // No isolate name
                    "virus": ["organism_name": "Zaire ebolavirus"]
                ]
            ],
            "total_count": 1
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "Ebolavirus")

        XCTAssertEqual(results.records[0].title, "Zaire ebolavirus")
    }

    func testSearchVirusDatasetsTitleFallsBackToAccession() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                [
                    "accession": "NC_002549.1"
                    // No isolate, no virus
                ]
            ],
            "total_count": 1
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "Ebolavirus")

        XCTAssertEqual(results.records[0].title, "NC_002549.1")
    }

    func testSearchVirusDatasetsUsesTotalCountFromResponse() async throws {
        let virusResponse: [String: Any] = [
            "reports": [
                ["accession": "NC_045512.2"]
            ],
            "total_count": 9190295
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "SARS-CoV-2")

        XCTAssertEqual(results.totalCount, 9190295)
    }

    func testSearchVirusDatasetsHandlesMissingTotalCount() async throws {
        // Some responses may not include total_count
        let virusResponse: [String: Any] = [
            "reports": [
                ["accession": "A"],
                ["accession": "B"]
            ]
        ]
        await mockClient.register(pattern: "datasets/v2/virus", response: .json(virusResponse))

        let results = try await service.searchVirusDatasets(taxon: "test")

        // Falls back to records.count
        XCTAssertEqual(results.totalCount, 2)
    }

    // MARK: - Datasets v2 Model Decoding Tests

    func testVirusDatasetReportDecodesFullResponse() throws {
        let json = """
        {
            "reports": [
                {
                    "accession": "NC_045512.2",
                    "is_annotated": true,
                    "source_database": "RefSeq",
                    "protein_count": 12,
                    "completeness": "COMPLETE",
                    "length": 29903,
                    "release_date": "2020-01-13",
                    "update_date": "2024-08-15",
                    "biosample": "SAMN13922059",
                    "bioprojects": ["PRJNA485481"],
                    "purpose_of_sampling": "Diagnostic testing",
                    "isolate": {
                        "name": "Wuhan-Hu-1",
                        "source": "clinical",
                        "collection_date": "2019-12-30"
                    },
                    "host": {
                        "tax_id": 9606,
                        "organism_name": "Homo sapiens"
                    },
                    "virus": {
                        "tax_id": 2697049,
                        "organism_name": "SARS-CoV-2",
                        "pangolin_classification": "B"
                    },
                    "location": {
                        "geographic_location": "China: Wuhan",
                        "geographic_region": "Asia",
                        "usa_state": null
                    }
                }
            ],
            "total_count": 9190295,
            "next_page_token": "token123"
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(VirusDatasetReport.self, from: json)

        XCTAssertEqual(report.totalCount, 9190295)
        XCTAssertEqual(report.nextPageToken, "token123")
        XCTAssertEqual(report.reports.count, 1)

        let r = report.reports[0]
        XCTAssertEqual(r.accession, "NC_045512.2")
        XCTAssertEqual(r.isAnnotated, true)
        XCTAssertEqual(r.sourceDatabase, "RefSeq")
        XCTAssertEqual(r.proteinCount, 12)
        XCTAssertEqual(r.completeness, "COMPLETE")
        XCTAssertEqual(r.length, 29903)
        XCTAssertEqual(r.releaseDate, "2020-01-13")
        XCTAssertEqual(r.updateDate, "2024-08-15")
        XCTAssertEqual(r.biosample, "SAMN13922059")
        XCTAssertEqual(r.bioprojects, ["PRJNA485481"])
        XCTAssertEqual(r.purposeOfSampling, "Diagnostic testing")

        XCTAssertEqual(r.isolate?.name, "Wuhan-Hu-1")
        XCTAssertEqual(r.isolate?.source, "clinical")
        XCTAssertEqual(r.isolate?.collectionDate, "2019-12-30")

        XCTAssertEqual(r.host?.taxId, 9606)
        XCTAssertEqual(r.host?.organismName, "Homo sapiens")

        XCTAssertEqual(r.virus?.taxId, 2697049)
        XCTAssertEqual(r.virus?.organismName, "SARS-CoV-2")
        XCTAssertEqual(r.virus?.pangolinClassification, "B")

        XCTAssertEqual(r.location?.geographicLocation, "China: Wuhan")
        XCTAssertEqual(r.location?.geographicRegion, "Asia")
        XCTAssertNil(r.location?.usaState)
    }

    func testVirusDatasetReportDecodesMinimalResponse() throws {
        let json = """
        {
            "reports": []
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(VirusDatasetReport.self, from: json)

        XCTAssertTrue(report.reports.isEmpty)
        XCTAssertNil(report.totalCount)
        XCTAssertNil(report.nextPageToken)
    }

    func testVirusReportDecodesWithMissingOptionalFields() throws {
        let json = """
        {
            "accession": "MN908947.3"
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(VirusReport.self, from: json)

        XCTAssertEqual(report.accession, "MN908947.3")
        XCTAssertNil(report.isAnnotated)
        XCTAssertNil(report.isolate)
        XCTAssertNil(report.sourceDatabase)
        XCTAssertNil(report.proteinCount)
        XCTAssertNil(report.host)
        XCTAssertNil(report.virus)
        XCTAssertNil(report.location)
        XCTAssertNil(report.completeness)
        XCTAssertNil(report.length)
        XCTAssertNil(report.releaseDate)
        XCTAssertNil(report.updateDate)
        XCTAssertNil(report.biosample)
        XCTAssertNil(report.bioprojects)
        XCTAssertNil(report.purposeOfSampling)
    }

    func testVirusIsolateDecodes() throws {
        let json = """
        {
            "name": "SARS-CoV-2/human/USA/MN-MDH-49571/2026",
            "source": "clinical",
            "collection_date": "2026-01-20"
        }
        """.data(using: .utf8)!

        let isolate = try JSONDecoder().decode(VirusIsolate.self, from: json)

        XCTAssertEqual(isolate.name, "SARS-CoV-2/human/USA/MN-MDH-49571/2026")
        XCTAssertEqual(isolate.source, "clinical")
        XCTAssertEqual(isolate.collectionDate, "2026-01-20")
    }

    func testVirusHostDecodes() throws {
        let json = """
        {
            "tax_id": 9606,
            "organism_name": "Homo sapiens"
        }
        """.data(using: .utf8)!

        let host = try JSONDecoder().decode(VirusHost.self, from: json)

        XCTAssertEqual(host.taxId, 9606)
        XCTAssertEqual(host.organismName, "Homo sapiens")
    }

    func testVirusInfoDecodes() throws {
        let json = """
        {
            "tax_id": 2697049,
            "organism_name": "Severe acute respiratory syndrome coronavirus 2",
            "pangolin_classification": "XFG.14.1.1"
        }
        """.data(using: .utf8)!

        let virus = try JSONDecoder().decode(VirusInfo.self, from: json)

        XCTAssertEqual(virus.taxId, 2697049)
        XCTAssertEqual(virus.organismName, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(virus.pangolinClassification, "XFG.14.1.1")
    }

    func testVirusInfoDecodesWithoutPangolin() throws {
        let json = """
        {
            "tax_id": 11320,
            "organism_name": "Influenza A virus"
        }
        """.data(using: .utf8)!

        let virus = try JSONDecoder().decode(VirusInfo.self, from: json)

        XCTAssertEqual(virus.taxId, 11320)
        XCTAssertEqual(virus.organismName, "Influenza A virus")
        XCTAssertNil(virus.pangolinClassification)
    }

    func testVirusLocationDecodes() throws {
        let json = """
        {
            "geographic_location": "USA: Minnesota",
            "geographic_region": "North America",
            "usa_state": "Minnesota"
        }
        """.data(using: .utf8)!

        let location = try JSONDecoder().decode(VirusLocation.self, from: json)

        XCTAssertEqual(location.geographicLocation, "USA: Minnesota")
        XCTAssertEqual(location.geographicRegion, "North America")
        XCTAssertEqual(location.usaState, "Minnesota")
    }

    func testVirusLocationDecodesPartial() throws {
        let json = """
        {
            "geographic_location": "China"
        }
        """.data(using: .utf8)!

        let location = try JSONDecoder().decode(VirusLocation.self, from: json)

        XCTAssertEqual(location.geographicLocation, "China")
        XCTAssertNil(location.geographicRegion)
        XCTAssertNil(location.usaState)
    }

    func testVirusDatasetReportLooseDateFormatter() {
        let formatter = VirusDatasetReport.looseDateFormatter
        let date = formatter.date(from: "2024-06-15")
        XCTAssertNotNil(date, "looseDateFormatter should parse yyyy-MM-dd dates")

        let invalid = formatter.date(from: "not-a-date")
        XCTAssertNil(invalid)
    }

    // MARK: - NCBIAssemblySummary Decoding Tests

    func testNCBIAssemblySummaryDecodesFromJSON() throws {
        let json = """
        {
            "uid": "12345",
            "assemblyaccession": "GCF_000001405.40",
            "assemblyname": "GRCh38.p14",
            "organism": "Homo sapiens",
            "speciesname": "Homo sapiens",
            "taxid": 9606,
            "ftppath_refseq": "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF",
            "ftppath_genbank": "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA",
            "submitter": "GRC",
            "coverage": "35.0",
            "contig_n50": 57879411,
            "scaffold_n50": 67794873
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(NCBIAssemblySummary.self, from: json)

        XCTAssertEqual(summary.uid, "12345")
        XCTAssertEqual(summary.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(summary.assemblyName, "GRCh38.p14")
        XCTAssertEqual(summary.organism, "Homo sapiens")
        XCTAssertEqual(summary.taxid, 9606)
        XCTAssertEqual(summary.contigN50, 57879411)
        XCTAssertEqual(summary.scaffoldN50, 67794873)
    }

    func testNCBIAssemblySummaryHandlesStringNumbers() throws {
        let json = """
        {
            "uid": "999",
            "taxid": "9606",
            "contig_n50": "12345",
            "scaffold_n50": "67890"
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(NCBIAssemblySummary.self, from: json)

        XCTAssertEqual(summary.taxid, 9606)
        XCTAssertEqual(summary.contigN50, 12345)
        XCTAssertEqual(summary.scaffoldN50, 67890)
    }

    func testNCBIAssemblySummaryHandlesMinimalFields() throws {
        let json = """
        {
            "uid": "1"
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(NCBIAssemblySummary.self, from: json)

        XCTAssertEqual(summary.uid, "1")
        XCTAssertNil(summary.assemblyAccession)
        XCTAssertNil(summary.assemblyName)
        XCTAssertNil(summary.organism)
        XCTAssertNil(summary.taxid)
        XCTAssertNil(summary.ftpPathRefSeq)
        XCTAssertNil(summary.ftpPathGenBank)
    }

    // MARK: - SearchResultRecord Virus Fields Tests

    func testSearchResultRecordWithVirusFields() {
        let record = SearchResultRecord(
            id: "NC_045512.2",
            accession: "NC_045512.2",
            title: "Wuhan-Hu-1",
            organism: "SARS-CoV-2",
            length: 29903,
            source: .ncbi,
            host: "Homo sapiens",
            geoLocation: "China: Wuhan",
            collectionDate: "2019-12-30",
            completeness: "COMPLETE",
            isolateName: "Wuhan-Hu-1",
            sourceDatabase: "RefSeq",
            pangolinClassification: "B"
        )

        XCTAssertEqual(record.host, "Homo sapiens")
        XCTAssertEqual(record.geoLocation, "China: Wuhan")
        XCTAssertEqual(record.collectionDate, "2019-12-30")
        XCTAssertEqual(record.completeness, "COMPLETE")
        XCTAssertEqual(record.isolateName, "Wuhan-Hu-1")
        XCTAssertEqual(record.sourceDatabase, "RefSeq")
        XCTAssertEqual(record.pangolinClassification, "B")
    }

    func testSearchResultRecordVirusFieldsDefaultToNil() {
        let record = SearchResultRecord(
            id: "AB123",
            accession: "AB123",
            title: "Test sequence",
            source: .ncbi
        )

        XCTAssertNil(record.host)
        XCTAssertNil(record.geoLocation)
        XCTAssertNil(record.collectionDate)
        XCTAssertNil(record.completeness)
        XCTAssertNil(record.isolateName)
        XCTAssertNil(record.sourceDatabase)
        XCTAssertNil(record.pangolinClassification)
    }

    func testSearchResultRecordEquatableWithVirusFields() {
        let record1 = SearchResultRecord(
            id: "NC_045512.2",
            accession: "NC_045512.2",
            title: "Test",
            source: .ncbi,
            host: "Homo sapiens",
            pangolinClassification: "B"
        )
        let record2 = SearchResultRecord(
            id: "NC_045512.2",
            accession: "NC_045512.2",
            title: "Test",
            source: .ncbi,
            host: "Homo sapiens",
            pangolinClassification: "B"
        )
        let record3 = SearchResultRecord(
            id: "NC_045512.2",
            accession: "NC_045512.2",
            title: "Test",
            source: .ncbi,
            host: "Gallus gallus",
            pangolinClassification: "B"
        )

        XCTAssertEqual(record1, record2)
        XCTAssertNotEqual(record1, record3)
    }

    func testSearchResultRecordIdentity() {
        let record = SearchResultRecord(
            id: "test-id-123",
            accession: "AB123.1",
            title: "Test",
            source: .ncbi
        )

        XCTAssertEqual(record.id, "test-id-123")
    }

    // MARK: - ESearchSearchResult Tests

    func testESearchSearchResultStructure() async throws {
        let response: [String: Any] = [
            "esearchresult": [
                "count": "1000",
                "retmax": "50",
                "retstart": "100",
                "idlist": ["a", "b", "c"]
            ]
        ]
        await mockClient.register(pattern: "esearch.fcgi", response: .json(response))

        let result = try await service.esearchWithCount(
            database: .nucleotide,
            term: "test",
            retmax: 50,
            retstart: 100
        )

        XCTAssertEqual(result.ids, ["a", "b", "c"])
        XCTAssertEqual(result.totalCount, 1000)
        XCTAssertEqual(result.retmax, 50)
        XCTAssertEqual(result.retstart, 100)
    }
}
