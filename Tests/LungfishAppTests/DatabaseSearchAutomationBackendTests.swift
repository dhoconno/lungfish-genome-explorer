import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class DatabaseSearchAutomationBackendTests: XCTestCase {
    func testUnknownScenarioNameReturnsNilBackend() {
        XCTAssertNil(DatabaseSearchAutomationBackend(scenarioName: "unknown"))
    }

    func testDisabledConfigurationDoesNotCreateBackend() {
        let config = AppUITestConfiguration(arguments: ["Lungfish"], environment: [:])

        XCTAssertNil(DatabaseSearchAutomationBackend(configuration: config))
    }

    func testBasicScenarioReturnsDeterministicRecordsPerDestination() async throws {
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(scenarioName: "database-search-basic"))

        let ncbi = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .ncbi,
                ncbiSearchType: .nucleotide,
                searchText: "coronavirus"
            )
        )
        XCTAssertEqual(ncbi.records.map(\.accession), ["NC_045512.2", "PP000001.1"])

        let sra = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .ena,
                ncbiSearchType: .nucleotide,
                searchText: "SRR000001"
            )
        )
        XCTAssertEqual(sra.records.map(\.accession), ["SRR000001"])

        let pathoplexus = try await backend.search(
            DatabaseSearchAutomationRequest(
                source: .pathoplexus,
                ncbiSearchType: .nucleotide,
                searchText: "mpox"
            )
        )
        XCTAssertEqual(pathoplexus.records.map(\.accession), ["MPXV-OPEN-001"])
    }

    func testBasicScenarioSupportsNoOpDownloadSimulation() async throws {
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(scenarioName: "database-search-basic"))
        let records = [
            SearchResultRecord(
                id: "NC_045512.2",
                accession: "NC_045512.2",
                title: "Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1, complete genome",
                source: .ncbi
            )
        ]

        try await backend.simulateDownload(records: records, source: .ncbi)
    }

    func testEnabledConfigurationWithoutScenarioFailsClosed() async throws {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: [:]
        )
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(configuration: config))

        do {
            _ = try await backend.search(
                DatabaseSearchAutomationRequest(
                    source: .ncbi,
                    ncbiSearchType: .nucleotide,
                    searchText: "coronavirus"
                )
            )
            XCTFail("Expected missing-scenario configuration to fail closed")
        } catch let error as DatabaseSearchAutomationBackendError {
            XCTAssertEqual(
                error.errorDescription,
                "UI test mode requires LUNGFISH_UI_TEST_SCENARIO to select a deterministic database-search scenario."
            )
        }
    }

    func testEnabledConfigurationWithUnknownScenarioFailsClosed() async throws {
        let config = AppUITestConfiguration(
            arguments: ["Lungfish", "--ui-test-mode"],
            environment: ["LUNGFISH_UI_TEST_SCENARIO": "unknown"]
        )
        let backend = try XCTUnwrap(DatabaseSearchAutomationBackend(configuration: config))

        do {
            try await backend.simulateDownload(records: [], source: .ncbi)
            XCTFail("Expected unknown-scenario configuration to fail closed")
        } catch let error as DatabaseSearchAutomationBackendError {
            XCTAssertEqual(
                error.errorDescription,
                "Unknown database-search UI-test scenario 'unknown'."
            )
        }
    }
}
