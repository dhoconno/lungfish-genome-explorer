import XCTest
@testable import LungfishCore

final class NCBINucleotideAccessionLookupTests: XCTestCase {
    func testExactVersionsOrderDeduplicationAndNoPagination() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "id=NM_000546.5", response: .text(fixture("NM_000546.5")))
        await client.register(pattern: "id=NM_000546", response: .text(fixture("NM_000546.6")))
        await client.register(pattern: "id=NM_000059.4", response: .text(fixture("NM_000059.4")))
        let service = NCBIService(apiKey: "test", httpClient: client)

        let result = try await service.lookupNucleotideAccessions([
            " nm_000546.5 ", "NM_000546.5", "NM_000546", "NM_000546.6", "NM_000059.4"
        ])

        XCTAssertEqual(result.records.map(\.accession), ["NM_000546.5", "NM_000546.6", "NM_000059.4"])
        XCTAssertEqual(result.records.map(\.id), result.records.map(\.accession))
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertFalse(result.hasMore)
        XCTAssertNil(result.nextCursor)
        XCTAssertEqual(result.records.first?.length, 4)
        XCTAssertEqual(result.records.first?.title, "Human transcript test fixture with a continued definition.")
        XCTAssertEqual(result.records.first?.organism, "Homo sapiens")
        let requests = await client.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("efetch.fcgi") == true })
        let first = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(first?.queryItems?.first(where: { $0.name == "id" })?.value, "NM_000546.5")
    }

    func testRejectsSilentVersionAndAccessionSubstitution() async throws {
        for returned in ["NM_000546.6", "NM_000059.2"] {
            let client = MockHTTPClient()
            await client.register(pattern: "efetch.fcgi", response: .text(fixture(returned)))
            do {
                _ = try await NCBIService(httpClient: client).lookupNucleotideAccessions(["NM_000546.5"])
                XCTFail("Must reject substituted record")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("NM_000546.5"))
                XCTAssertTrue(error.localizedDescription.contains(returned))
            }
            let requests = await client.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testUnresolvedRecordFailsEntireLookupAndNamesAccession() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "id=NM_000546.5", response: .text(fixture("NM_000546.5")))
        await client.register(pattern: "id=NM_000059.4", response: .text("Error: ID list is empty!"))
        do {
            _ = try await NCBIService(apiKey: "test", httpClient: client)
                .lookupNucleotideAccessions(["NM_000546.5", "NM_000059.4"])
            XCTFail("Must fail instead of returning a partial list")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("NM_000059.4"))
        }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2, "Must not fall back to a broad search")
    }

    func testValidationPrecedesAllRequests() async throws {
        let client = MockHTTPClient()
        do {
            _ = try await NCBIService(httpClient: client)
                .lookupNucleotideAccessions(["NM_000546.5", "SRR123456"])
            XCTFail("SRA accessions are not nucleotide accessions")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SRR123456"))
        }
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEmptyListMakesNoRequests() async throws {
        let client = MockHTTPClient()
        let result = try await NCBIService(httpClient: client).lookupNucleotideAccessions([])
        XCTAssertEqual(result.totalCount, 0)
        XCTAssertTrue(result.records.isEmpty)
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationPropagatesWithoutWrappingOrSearchFallback() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "efetch.fcgi", response: .cancelled)
        do {
            _ = try await NCBIService(httpClient: client).lookupNucleotideAccessions(["NM_000546.5"])
            XCTFail("Must throw cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellingInFlightLookupStopsRemainingAccessions() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "efetch.fcgi", response: .text(fixture("NM_000546.5")))
        await client.setResponseDelayNanoseconds(10_000_000_000)
        let service = NCBIService(httpClient: client)
        let lookup = Task {
            try await service.lookupNucleotideAccessions(["NM_000546.5", "NM_000059.4"])
        }
        for _ in 0..<100 {
            if !(await client.requests).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        lookup.cancel()
        do {
            _ = try await lookup.value
            XCTFail("Expected cancelled lookup")
        } catch is CancellationError {
            // Cancellation must escape without becoming a lookup failure.
        }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRejectsAmbiguousOrUnversionedResponses() async throws {
        let valid = fixture("NM_000546.5")
        for response in [valid + "\n" + valid, valid.replacingOccurrences(of: "VERSION     NM_000546.5", with: "VERSION     NM_000546")] {
            let client = MockHTTPClient()
            await client.register(pattern: "efetch.fcgi", response: .text(response))
            do {
                _ = try await NCBIService(httpClient: client).lookupNucleotideAccessions(["NM_000546.5"])
                XCTFail("Must require exactly one versioned record")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("NM_000546.5"))
            }
        }
    }

    private func fixture(_ version: String) -> String {
        let accession = version.split(separator: ".")[0]
        return """
        LOCUS       \(accession)              4 bp    DNA     linear   PRI
        DEFINITION  Human transcript test fixture with a
                    continued definition.
        ACCESSION   \(accession)
        VERSION     \(version)
        SOURCE      Homo sapiens
          ORGANISM  Homo sapiens
        ORIGIN
                1 atgc
        //
        """
    }
}
