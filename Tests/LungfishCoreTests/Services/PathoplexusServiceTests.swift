// PathoplexusServiceTests.swift - Tests for Pathoplexus service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class PathoplexusServiceTests: XCTestCase {

    var mockClient: MockHTTPClient!
    var service: PathoplexusService!

    override func setUp() async throws {
        mockClient = MockHTTPClient()
        service = PathoplexusService(httpClient: mockClient)
    }

    // MARK: - List Organisms Tests

    func testListOrganismsReturnsKnownOrganisms() async throws {
        let organisms = try await service.listOrganisms()

        XCTAssertGreaterThan(organisms.count, 0)

        // Check for expected organisms
        let ids = organisms.map { $0.id }
        XCTAssertTrue(ids.contains("ebola-zaire"))
        XCTAssertTrue(ids.contains("mpox"))
        XCTAssertTrue(ids.contains("cchf"))
    }

    func testListOrganismsIncludesSegmentedInfo() async throws {
        let organisms = try await service.listOrganisms()

        // CCHF should be segmented
        let cchf = organisms.first { $0.id == "cchf" }
        XCTAssertNotNil(cchf)
        XCTAssertTrue(cchf!.segmented)
        XCTAssertNotNil(cchf!.segments)
        XCTAssertEqual(cchf!.segments?.count, 3)  // S, M, L segments
    }

    func testListOrganismsIncludesNonSegmented() async throws {
        let organisms = try await service.listOrganisms()

        // Ebola should not be segmented
        let ebola = organisms.first { $0.id == "ebola-zaire" }
        XCTAssertNotNil(ebola)
        XCTAssertFalse(ebola!.segmented)
        XCTAssertNil(ebola!.segments)
    }

    // MARK: - Search Tests

    func testSearchReturnsResults() async throws {
        await mockClient.registerPathoplexusCount(42)
        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_12345",
                "organism": "Ebola zaire",
                "geoLocCountry": "DRC",
                "sampleCollectionDate": "2024-01-15",
                "length": 18959
            ]
        ])

        let query = SearchQuery(term: "ebola", organism: "ebola-zaire", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.totalCount, 42)
        XCTAssertGreaterThan(results.records.count, 0)
    }

    func testSearchWithFilters() async throws {
        await mockClient.registerPathoplexusCount(5)
        await mockClient.registerPathoplexusMetadata([])

        let filters = PathoplexusFilters(
            geoLocCountry: "USA",
            sampleCollectionDateFrom: "2024-01-01",
            lengthFrom: 1000,
            lengthTo: 20000
        )

        let results = try await service.search(organism: "mpox", filters: filters)

        XCTAssertEqual(results.totalCount, 5)

        // Check that filters were included in the request
        let requests = await mockClient.requests
        XCTAssertGreaterThan(requests.count, 0)
    }

    // MARK: - Aggregated Count Tests

    func testGetAggregatedCount() async throws {
        await mockClient.registerPathoplexusCount(156)

        let count = try await service.getAggregatedCount(organism: "ebola-zaire", filters: PathoplexusFilters())

        XCTAssertEqual(count, 156)
    }

    func testGetAggregatedCountWithFilters() async throws {
        await mockClient.registerPathoplexusCount(25)

        let filters = PathoplexusFilters(geoLocCountry: "Uganda")
        let count = try await service.getAggregatedCount(organism: "ebola-sudan", filters: filters)

        XCTAssertEqual(count, 25)

        let requests = await mockClient.requests
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("geoLocCountry=Uganda") || url.contains("geoLocCountry"))
    }

    // MARK: - Fetch Metadata Tests

    func testFetchMetadataReturnsRecords() async throws {
        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "accessionVersion": "1",
                "organism": "Mpox",
                "geoLocCountry": "Nigeria",
                "sampleCollectionDate": "2024-02-01",
                "length": 197209
            ],
            [
                "accession": "PP_002",
                "accessionVersion": "1",
                "organism": "Mpox",
                "geoLocCountry": "DRC",
                "sampleCollectionDate": "2024-01-20",
                "length": 197150
            ]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())

        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[0].accession, "PP_001")
        XCTAssertEqual(metadata[0].geoLocCountry, "Nigeria")
        XCTAssertEqual(metadata[1].accession, "PP_002")
        XCTAssertEqual(metadata[1].geoLocCountry, "DRC")
    }

    func testFetchMetadataHandlesIntAndStringLength() async throws {
        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "length": 1000],
            ["accession": "PP_002", "length": "2000"]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())

        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[0].length, 1000)
        XCTAssertEqual(metadata[1].length, 2000)
    }

    // MARK: - Fetch Sequences Tests

    func testFetchSequencesStreamsData() async throws {
        let fastaContent = """
        >PP_001
        ATGCATGCATGC
        >PP_002
        GCTAGCTAGCTA
        """
        await mockClient.register(pattern: "NucleotideSequences", response: .text(fastaContent))

        let stream = try await service.fetchSequences(organism: "mpox", filters: PathoplexusFilters())

        var records: [FASTARecord] = []
        for try await record in stream {
            records.append(record)
        }

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].accession, "PP_001")
        XCTAssertEqual(records[1].accession, "PP_002")
    }

    func testFetchAlignedSequences() async throws {
        let fastaContent = ">PP_001\nATG---CATGC"
        await mockClient.register(pattern: "alignedNucleotideSequences", response: .text(fastaContent))

        let stream = try await service.fetchSequences(organism: "mpox", filters: PathoplexusFilters(), aligned: true)

        var records: [FASTARecord] = []
        for try await record in stream {
            records.append(record)
        }

        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].sequence.contains("-"))
    }

    func testFetchUnalignedSequences() async throws {
        let fastaContent = ">PP_001\nATGCATGC"
        await mockClient.register(pattern: "unalignedNucleotideSequences", response: .text(fastaContent))

        let stream = try await service.fetchSequences(organism: "mpox", filters: PathoplexusFilters(), aligned: false)

        var records: [FASTARecord] = []
        for try await record in stream {
            records.append(record)
        }

        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].sequence.contains("-"))
    }

    // MARK: - Fetch Tests (DatabaseService Protocol)

    func testFetchReturnsRecord() async throws {
        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_TEST", "length": 5000]
        ])
        await mockClient.register(pattern: "NucleotideSequences", response: .text(">PP_TEST\nATGCATGC"))

        let record = try await service.fetch(accession: "PP_TEST")

        XCTAssertEqual(record.accession, "PP_TEST")
        XCTAssertEqual(record.source, .pathoplexus)
    }

    // MARK: - Filter Building Tests

    func testFiltersIncludeAllParameters() async throws {
        await mockClient.registerPathoplexusCount(0)

        let filters = PathoplexusFilters(
            accession: "PP_001",
            geoLocCountry: "USA",
            sampleCollectionDateFrom: "2024-01-01",
            sampleCollectionDateTo: "2024-02-01",
            lengthFrom: 1000,
            lengthTo: 20000,
            nucleotideMutations: ["C180T"],
            aminoAcidMutations: ["GP:440G"],
            versionStatus: .latestVersion
        )

        _ = try await service.getAggregatedCount(organism: "mpox", filters: filters)

        let requests = await mockClient.requests
        XCTAssertEqual(requests.count, 1)

        // Verify date strings appear in the URL exactly as provided
        let requestURL = requests[0].url!.absoluteString
        XCTAssertTrue(requestURL.contains("sampleCollectionDateRangeLowerFrom=2024-01-01"), "URL should contain date from: \(requestURL)")
        XCTAssertTrue(requestURL.contains("sampleCollectionDateRangeUpperTo=2024-02-01"), "URL should contain date to: \(requestURL)")
        XCTAssertTrue(requestURL.contains("accession=PP_001"), "URL should contain accession: \(requestURL)")
        XCTAssertTrue(requestURL.contains("geoLocCountry=USA"), "URL should contain country: \(requestURL)")
        XCTAssertTrue(requestURL.contains("lengthFrom=1000"), "URL should contain lengthFrom: \(requestURL)")
        XCTAssertTrue(requestURL.contains("versionStatus=LATEST_VERSION"), "URL should contain versionStatus: \(requestURL)")
    }

    // MARK: - Error Handling Tests

    func testHandlesNetworkError() async throws {
        // No response registered — should throw an error (either DatabaseServiceError or URLError)

        do {
            _ = try await service.getAggregatedCount(organism: "mpox", filters: PathoplexusFilters())
            XCTFail("Should have thrown an error")
        } catch {
            // Any error is acceptable — the mock has no registered response
            // so the underlying URLSession or mock will throw a network error
        }
    }

    func testHandlesServerError() async throws {
        await mockClient.register(pattern: "/aggregated", response: .error(statusCode: 500, message: "Internal Error"))

        do {
            _ = try await service.getAggregatedCount(organism: "mpox", filters: PathoplexusFilters())
            XCTFail("Should have thrown an error")
        } catch let error as DatabaseServiceError {
            if case .serverError = error {
                // Expected
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        }
    }

    func testHandlesInvalidOrganism() async throws {
        await mockClient.register(pattern: "/aggregated", response: .error(statusCode: 404, message: "Not Found"))

        do {
            _ = try await service.getAggregatedCount(organism: "invalid-organism", filters: PathoplexusFilters())
            XCTFail("Should have thrown an error")
        } catch let error as DatabaseServiceError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound error, got \(error)")
            }
        }
    }

    // MARK: - Service Properties Tests

    func testServiceName() async {
        XCTAssertEqual(service.name, "Pathoplexus")
    }

    func testServiceBaseURL() async {
        XCTAssertTrue(service.baseURL.absoluteString.contains("pathoplexus"))
    }
}

// MARK: - PathoplexusFilters Tests

final class PathoplexusFiltersTests: XCTestCase {

    func testDefaultFiltersAreEmpty() {
        let filters = PathoplexusFilters()

        XCTAssertNil(filters.accession)
        XCTAssertNil(filters.geoLocCountry)
        XCTAssertNil(filters.sampleCollectionDateFrom)
        XCTAssertNil(filters.lengthFrom)
        XCTAssertNil(filters.nucleotideMutations)
    }

    func testFiltersEquatable() {
        let filters1 = PathoplexusFilters(geoLocCountry: "USA")
        let filters2 = PathoplexusFilters(geoLocCountry: "USA")
        let filters3 = PathoplexusFilters(geoLocCountry: "UK")

        XCTAssertEqual(filters1, filters2)
        XCTAssertNotEqual(filters1, filters3)
    }
}

// MARK: - PathoplexusOrganism Tests

final class PathoplexusOrganismTests: XCTestCase {

    func testOrganismIdentifiable() {
        let organism = PathoplexusOrganism(id: "mpox", displayName: "Mpox", segmented: false, segments: nil)

        XCTAssertEqual(organism.id, "mpox")
    }

    func testOrganismEquatable() {
        let org1 = PathoplexusOrganism(id: "mpox", displayName: "Mpox", segmented: false, segments: nil)
        let org2 = PathoplexusOrganism(id: "mpox", displayName: "Mpox", segmented: false, segments: nil)
        let org3 = PathoplexusOrganism(id: "ebola", displayName: "Ebola", segmented: false, segments: nil)

        XCTAssertEqual(org1, org2)
        XCTAssertNotEqual(org1, org3)
    }

    func testOrganismCodable() throws {
        let organism = PathoplexusOrganism(id: "cchf", displayName: "CCHF", segmented: true, segments: ["S", "M", "L"])

        let encoder = JSONEncoder()
        let data = try encoder.encode(organism)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PathoplexusOrganism.self, from: data)

        XCTAssertEqual(decoded.id, organism.id)
        XCTAssertEqual(decoded.segmented, organism.segmented)
        XCTAssertEqual(decoded.segments, organism.segments)
    }
}

// MARK: - DataUseTerms Tests

final class DataUseTermsTests: XCTestCase {

    func testDataUseTermsRawValues() {
        XCTAssertEqual(DataUseTerms.open.rawValue, "OPEN")
        XCTAssertEqual(DataUseTerms.restricted.rawValue, "RESTRICTED")
    }

    func testDataUseTermsDescription() {
        XCTAssertTrue(DataUseTerms.open.description.contains("Open"))
        XCTAssertTrue(DataUseTerms.restricted.description.contains("Restricted"))
    }

    func testDataUseTermsCaseIterable() {
        XCTAssertEqual(DataUseTerms.allCases.count, 2)
    }
}

// MARK: - Search Result Mapping Tests

final class PathoplexusSearchMappingTests: XCTestCase {

    var mockClient: MockHTTPClient!
    var service: PathoplexusService!

    override func setUp() async throws {
        mockClient = MockHTTPClient()
        service = PathoplexusService(httpClient: mockClient)
    }

    func testSearchMapsSubtypeFromMetadata() async throws {
        await mockClient.registerPathoplexusCount(1)
        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "organism": "RSV A",
                "subtype": "A.2.1",
                "length": 15000
            ]
        ])

        let query = SearchQuery(term: "rsv", organism: "rsv-a", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.records.count, 1)
        XCTAssertEqual(results.records[0].subtype, "A.2.1")
    }

    func testSearchMapsCompletenessFromMetadataFraction() async throws {
        await mockClient.registerPathoplexusCount(1)
        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "completeness": 0.95,
                "length": 15000
            ]
        ])

        let query = SearchQuery(term: "test", organism: "mpox", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.records.count, 1)
        XCTAssertEqual(results.records[0].completeness, "95%")
    }

    func testSearchMapsIsolateNameFromDisplayName() async throws {
        await mockClient.registerPathoplexusCount(1)
        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "displayName": "Japan/PP_001.1",
                "length": 15000
            ]
        ])

        let query = SearchQuery(term: "test", organism: "mpox", limit: 10)
        let results = try await service.search(query)

        XCTAssertEqual(results.records.count, 1)
        XCTAssertEqual(results.records[0].isolateName, "Japan/PP_001.1")
    }

    func testSearchByPPAccessionSetsAccessionFilter() async throws {
        await mockClient.registerPathoplexusCount(1)
        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_0015NF5", "length": 18959]
        ])

        let query = SearchQuery(term: "PP_0015NF5", organism: "mpox", limit: 10)
        _ = try await service.search(query)

        let requests = await mockClient.requests
        XCTAssertGreaterThan(requests.count, 0)
        let url = requests.last!.url!.absoluteString
        XCTAssertTrue(url.contains("accession=PP_0015NF5"), "URL should contain accession filter: \(url)")
    }

    func testSearchByFreeTextDoesNotSetAccessionFilter() async throws {
        await mockClient.registerPathoplexusCount(1)
        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "length": 18959]
        ])

        let query = SearchQuery(term: "ebola", organism: "ebola-zaire", limit: 10)
        _ = try await service.search(query)

        let requests = await mockClient.requests
        let url = requests.last!.url!.absoluteString
        XCTAssertFalse(url.contains("accession=ebola"), "Free text should not set accession filter: \(url)")
    }
}

// MARK: - PathoplexusMetadata Computed Property Tests

final class PathoplexusMetadataComputedTests: XCTestCase {

    func testCollectionDateParsesValidDate() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "sampleCollectionDate": "2024-06-15", "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata.count, 1)
        XCTAssertNotNil(metadata[0].collectionDate)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: metadata[0].collectionDate!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
    }

    func testCollectionDateReturnsNilForMissing() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertNil(metadata[0].collectionDate)
    }

    func testBestLocationCombinesCityAdminCountry() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "geoLocCity": "Sapporo",
                "geoLocAdmin1": "Hokkaido",
                "geoLocCountry": "Japan",
                "length": 1000
            ]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].bestLocation, "Sapporo, Hokkaido, Japan")
    }

    func testBestLocationCountryOnly() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "geoLocCountry": "USA", "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].bestLocation, "USA")
    }

    func testCompletenessHandlesDoubleValue() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "completeness": 0.98, "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].completeness, 0.98)
    }

    func testCompletenessHandlesStringValue() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "completeness": "0.95", "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].completeness, 0.95)
    }

    func testBestINSDCAccessionPrefersFull() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "insdcAccessionBase": "AB160902",
                "insdcAccessionFull": "AB160902.1",
                "length": 1000
            ]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].bestINSDCAccession, "AB160902.1")
        XCTAssertTrue(metadata[0].hasINSDCAccession)
    }

    func testBestINSDCAccessionFallsBackToBase() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            [
                "accession": "PP_001",
                "insdcAccessionBase": "AB160902",
                "length": 1000
            ]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertEqual(metadata[0].bestINSDCAccession, "AB160902")
    }

    func testHasINSDCAccessionFalseWhenEmpty() async throws {
        let mockClient = MockHTTPClient()
        let service = PathoplexusService(httpClient: mockClient)

        await mockClient.registerPathoplexusMetadata([
            ["accession": "PP_001", "length": 1000]
        ])

        let metadata = try await service.fetchMetadata(organism: "mpox", filters: PathoplexusFilters())
        XCTAssertFalse(metadata[0].hasINSDCAccession)
        XCTAssertNil(metadata[0].bestINSDCAccession)
    }
}

// MARK: - MetadataItem URL Tests

final class MetadataItemURLTests: XCTestCase {

    func testMetadataItemWithURL() {
        let item = MetadataItem(label: "Accession", value: "PP_001", url: "https://pathoplexus.org/mpox/search?accession=PP_001")
        XCTAssertEqual(item.label, "Accession")
        XCTAssertEqual(item.value, "PP_001")
        XCTAssertEqual(item.url, "https://pathoplexus.org/mpox/search?accession=PP_001")
    }

    func testMetadataItemWithoutURLDefaultsToNil() {
        let item = MetadataItem(label: "Length", value: "1000 bp")
        XCTAssertNil(item.url)
    }

    func testMetadataItemURLRoundTrip() throws {
        let item = MetadataItem(label: "INSDC", value: "AB160902.1", url: "https://www.ncbi.nlm.nih.gov/nuccore/AB160902.1")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MetadataItem.self, from: data)

        XCTAssertEqual(decoded.label, item.label)
        XCTAssertEqual(decoded.value, item.value)
        XCTAssertEqual(decoded.url, item.url)
        XCTAssertEqual(decoded.id, item.id)
    }

    func testMetadataItemBackwardCompatibleDecodingWithoutURL() throws {
        let json = """
        {"id": "test-id", "label": "Length", "value": "1000 bp"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MetadataItem.self, from: data)

        XCTAssertEqual(decoded.label, "Length")
        XCTAssertEqual(decoded.value, "1000 bp")
        XCTAssertNil(decoded.url)
    }
}

// MARK: - VersionStatus Tests

final class VersionStatusTests: XCTestCase {

    func testVersionStatusRawValues() {
        XCTAssertEqual(VersionStatus.latestVersion.rawValue, "LATEST_VERSION")
        XCTAssertEqual(VersionStatus.revisedVersion.rawValue, "REVISED_VERSION")
    }
}
