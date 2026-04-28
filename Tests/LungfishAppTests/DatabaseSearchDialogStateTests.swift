import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class DatabaseSearchDialogStateTests: XCTestCase {
    func testStaleSearchResponseCannotOverwriteActiveQueryResults() async throws {
        let backend = DelayedDatabaseSearchBackend()
        let state = DatabaseSearchDialogState(
            automationBackend: DatabaseSearchAutomationBackend { request in
                try await backend.search(request)
            }
        )
        let viewModel = state.genBankGenomesViewModel

        viewModel.searchText = "query-A"
        viewModel.performSearch()
        await backend.waitUntilStarted("query-A")

        viewModel.searchText = "query-B"
        viewModel.performSearch()
        await backend.waitUntilStarted("query-B")

        await backend.complete("query-B", accession: "B")
        try await waitForSearchCompletion(viewModel)
        XCTAssertEqual(viewModel.results.map(\.accession), ["B"])

        await backend.complete("query-A", accession: "A")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.results.map(\.accession), ["B"])
        XCTAssertEqual(viewModel.searchPhase, .complete(count: 1))
    }

    func testDestinationTitlesAndSubtitlesMatchApprovedCopy() {
        XCTAssertEqual(DatabaseSearchDestination.genBankGenomes.title, "GenBank & Genomes")
        XCTAssertEqual(
            DatabaseSearchDestination.genBankGenomes.subtitle,
            "Nucleotide, assembly, and virus records from NCBI"
        )

        XCTAssertEqual(DatabaseSearchDestination.sraRuns.title, "SRA Runs")
        XCTAssertEqual(
            DatabaseSearchDestination.sraRuns.subtitle,
            "Sequencing runs and FASTQ availability"
        )

        XCTAssertEqual(DatabaseSearchDestination.pathoplexus.title, "Pathoplexus")
        XCTAssertEqual(
            DatabaseSearchDestination.pathoplexus.subtitle,
            "Open pathogen records and surveillance metadata"
        )
    }

    func testDestinationMappingFromDatabaseSource() {
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ncbi), .genBankGenomes)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .ena), .sraRuns)
        XCTAssertEqual(DatabaseSearchDestination(databaseSource: .pathoplexus), .pathoplexus)
    }

    func testSwitchingDestinationsPreservesSearchTextPerViewModel() {
        let state = DatabaseSearchDialogState()

        state.genBankGenomesViewModel.searchText = "SARS-CoV-2"
        state.selectDestination(.sraRuns)
        state.sraRunsViewModel.searchText = "SRR123456"
        state.selectDestination(.pathoplexus)
        state.pathoplexusViewModel.searchText = "mpox"

        state.selectDestination(.genBankGenomes)
        XCTAssertEqual(state.genBankGenomesViewModel.searchText, "SARS-CoV-2")

        state.selectDestination(.sraRuns)
        XCTAssertEqual(state.sraRunsViewModel.searchText, "SRR123456")

        state.selectDestination(.pathoplexus)
        XCTAssertEqual(state.pathoplexusViewModel.searchText, "mpox")
    }

    func testPrimaryActionTitleSwitchesToDownloadSelected() {
        let state = DatabaseSearchDialogState()
        XCTAssertEqual(state.primaryActionTitle, "Search")

        let selectedRecord = SearchResultRecord(
            id: "NC_000000",
            accession: "NC_000000",
            title: "Example record",
            source: .ncbi
        )
        state.genBankGenomesViewModel.selectedRecords.insert(selectedRecord)

        XCTAssertEqual(state.primaryActionTitle, "Download Selected")
    }

    func testCallbacksWireAcrossAllOwnedViewModels() {
        let state = DatabaseSearchDialogState()
        var cancelCount = 0
        var downloadCount = 0

        state.applyCallbacks(
            onCancel: { cancelCount += 1 },
            onDownloadStarted: { downloadCount += 1 }
        )

        state.genBankGenomesViewModel.onCancel?()
        state.sraRunsViewModel.onCancel?()
        state.pathoplexusViewModel.onCancel?()
        state.genBankGenomesViewModel.onDownloadStarted?()
        state.sraRunsViewModel.onDownloadStarted?()
        state.pathoplexusViewModel.onDownloadStarted?()

        XCTAssertEqual(cancelCount, 3)
        XCTAssertEqual(downloadCount, 3)
    }

    func testPathoplexusConsentBlocksPrimaryActionUntilAccepted() {
        let state = DatabaseSearchDialogState(initialDestination: .pathoplexus)
        state.pathoplexusViewModel.hasAcceptedPathoplexusConsent = false

        XCTAssertFalse(state.isPrimaryActionEnabled)

        state.performPrimaryAction()

        XCTAssertEqual(state.pathoplexusViewModel.searchPhase, .idle)
        XCTAssertEqual(state.statusText, "Review the Pathoplexus access notice to continue.")
    }

    private func waitForSearchCompletion(
        _ viewModel: DatabaseBrowserViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .complete = viewModel.searchPhase {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for search completion", file: file, line: line)
    }
}

private actor DelayedDatabaseSearchBackend {
    private var continuations: [String: CheckedContinuation<SearchResults, Error>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func search(_ request: DatabaseSearchAutomationRequest) async throws -> SearchResults {
        try await withCheckedThrowingContinuation { continuation in
            continuations[request.searchText] = continuation
            waiters.removeValue(forKey: request.searchText)?.forEach { $0.resume() }
        }
    }

    func waitUntilStarted(_ query: String) async {
        if continuations[query] != nil {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[query, default: []].append(continuation)
        }
    }

    func complete(_ query: String, accession: String) {
        let record = SearchResultRecord(
            id: accession,
            accession: accession,
            title: "Record \(accession)",
            source: .ncbi
        )
        continuations.removeValue(forKey: query)?.resume(returning: SearchResults(
            totalCount: 1,
            records: [record],
            hasMore: false,
            nextCursor: nil
        ))
    }
}
