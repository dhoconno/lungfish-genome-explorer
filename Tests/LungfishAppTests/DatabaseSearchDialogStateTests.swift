import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class DatabaseSearchDialogStateTests: XCTestCase {
    func testCancelledGenBankImportCannotCommitLateResults() async throws {
        let backend = DelayedDatabaseSearchBackend()
        let state = DatabaseSearchDialogState(automationBackend: DatabaseSearchAutomationBackend { request in
            try await backend.search(request)
        })
        let model = state.genBankGenomesViewModel
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "accession\nNM_000546.6\n".write(to: url, atomically: true, encoding: .utf8)
        try model.importAccessionList(at: url)
        await backend.waitUntilStarted("NM_000546.6")
        model.cancelSearch()
        await backend.complete("NM_000546.6", accession: "NM_000546.6")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.searchPhase, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.selectedRecords.isEmpty)
        XCTAssertEqual(model.totalResultCount, 0)
        XCTAssertFalse(model.hasMoreResults)
    }

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

    func testInFlightSearchResponseCannotCommitAfterQueryAndFilterEdits() async throws {
        let backend = DelayedDatabaseSearchBackend()
        let state = DatabaseSearchDialogState(
            automationBackend: DatabaseSearchAutomationBackend { request in
                try await backend.search(request)
            }
        )
        let viewModel = state.genBankGenomesViewModel

        viewModel.searchText = "query-A"
        viewModel.organismFilter = "Protopterus"
        viewModel.performSearch()
        await backend.waitUntilStarted("query-A")

        viewModel.searchText = "query-edited"
        viewModel.organismFilter = "Neoceratodus"

        await backend.complete("query-A", accession: "A")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNotEqual(viewModel.searchPhase, .complete(count: 1))
    }

    func testStaleSearchCompletionResetsProgressSoEditedQueryCanStartNewSearch() async throws {
        let backend = DelayedDatabaseSearchBackend()
        let state = DatabaseSearchDialogState(
            automationBackend: DatabaseSearchAutomationBackend { request in
                try await backend.search(request)
            }
        )
        let viewModel = state.genBankGenomesViewModel

        viewModel.searchText = "query-A"
        viewModel.organismFilter = "Protopterus"
        viewModel.performSearch()
        await backend.waitUntilStarted("query-A")

        viewModel.searchText = "query-B"
        viewModel.organismFilter = "Neoceratodus"

        await backend.complete("query-A", accession: "A")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertFalse(viewModel.testingHasCurrentSearchTask)

        viewModel.performSearch()
        await backend.waitUntilStarted("query-B")
        await backend.complete("query-B", accession: "B")
        try await waitForSearchCompletion(viewModel)

        XCTAssertEqual(viewModel.results.map(\.accession), ["B"])
        XCTAssertEqual(viewModel.searchPhase, .complete(count: 1))
    }

    func testImportedSRAAccessionListSearchCompletesAfterAccessionsAreCapturedAndCleared() async throws {
        let mockClient = DatabaseSearchDialogMockHTTPClient()
        await mockClient.register(
            pattern: "accession=SRR000001",
            response: .json([Self.enaReadRecord(accession: "SRR000001")])
        )
        await mockClient.register(
            pattern: "accession=SRR000002",
            response: .json([Self.enaReadRecord(accession: "SRR000002")])
        )
        await mockClient.register(
            pattern: "efetch.fcgi",
            response: .text("Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName\n")
        )

        let viewModel = DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: mockClient),
            enaService: ENAService(httpClient: mockClient)
        )
        viewModel.searchText = "2 accessions from import.csv"
        viewModel.importedAccessions = ["SRR000001", "SRR000002"]
        viewModel.searchScope = .accession

        viewModel.performSearch()

        try await waitForSearchResultCount(2, in: viewModel)
        XCTAssertEqual(viewModel.results.map(\.accession).sorted(), ["SRR000001", "SRR000002"])
        XCTAssertTrue(viewModel.importedAccessions.isEmpty)
        XCTAssertEqual(viewModel.searchPhase, .complete(count: 2))
    }

    func testStaleNucleotideSearchDoesNotShowLargeResultPromptAfterQueryEdit() async throws {
        let mockClient = DatabaseSearchDialogMockHTTPClient()
        await mockClient.registerDelayed(
            pattern: "esearch.fcgi",
            response: .text(#"{"esearchresult":{"count":"1001","retmax":"200","retstart":"0","idlist":["1"]}}"#)
        )
        let promptRecorder = LargeResultPromptRecorder()

        let viewModel = DatabaseBrowserViewModel(
            source: .ncbi,
            ncbiService: NCBIService(httpClient: mockClient),
            enaService: ENAService(httpClient: mockClient),
            largeResultActionProvider: { totalCount, sourceLabel in
                await promptRecorder.record(totalCount: totalCount, sourceLabel: sourceLabel)
                return .firstThousand
            }
        )
        viewModel.searchText = "query-A"
        viewModel.ncbiSearchType = NCBISearchType.nucleotide
        viewModel.performSearch()
        await mockClient.waitUntilRequested("esearch.fcgi")

        viewModel.searchText = "query-B"
        await mockClient.release("esearch.fcgi")
        try await Task.sleep(nanoseconds: 50_000_000)

        let promptCount = await promptRecorder.count()
        XCTAssertEqual(promptCount, 0)
    }

    func testLargeResultPromptsRouteThroughSearchTokenGate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("let action = await confirmLargeResultActionDialog("))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "try await self.resolveLargeResultAction(").count - 1,
            4
        )
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

    private func waitForSearchResultCount(
        _ count: Int,
        in viewModel: DatabaseBrowserViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if viewModel.results.count == count {
                return
            }
            if let errorMessage = viewModel.errorMessage {
                XCTFail("Search failed: \(errorMessage)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(count) search results", file: file, line: line)
    }

    private static func enaReadRecord(accession: String) -> [String: String] {
        [
            "run_accession": accession,
            "experiment_title": "Imported \(accession)",
            "library_layout": "PAIRED",
            "library_strategy": "WGS",
            "instrument_platform": "ILLUMINA",
            "base_count": "1000",
            "read_count": "10",
            "fastq_ftp": "",
            "fastq_bytes": "",
            "first_public": "2026-01-01",
        ]
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

private actor DatabaseSearchDialogMockHTTPClient: HTTPClient {
    struct MockResponse {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func text(_ string: String, statusCode: Int = 200) -> MockResponse {
            MockResponse(data: Data(string.utf8), statusCode: statusCode, headers: [:])
        }

        static func json(_ object: Any, statusCode: Int = 200) -> MockResponse {
            MockResponse(
                data: try! JSONSerialization.data(withJSONObject: object),
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"]
            )
        }
    }

    private var responses: [(pattern: String, response: MockResponse)] = []
    private var delayedResponses: [String: MockResponse] = [:]
    private var delayedContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requestedPatterns: Set<String> = []

    func register(pattern: String, response: MockResponse) {
        responses.append((pattern, response))
    }

    func registerDelayed(pattern: String, response: MockResponse) {
        delayedResponses[pattern] = response
    }

    func waitUntilRequested(_ pattern: String) async {
        if requestedPatterns.contains(pattern) {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters[pattern, default: []].append(continuation)
        }
    }

    func release(_ pattern: String) {
        delayedContinuations.removeValue(forKey: pattern)?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let urlString = request.url?.absoluteString ?? ""
        for (pattern, response) in delayedResponses where urlString.contains(pattern) {
            requestedPatterns.insert(pattern)
            requestWaiters.removeValue(forKey: pattern)?.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                delayedContinuations[pattern] = continuation
            }
            let urlResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            return (response.data, urlResponse)
        }
        for (pattern, response) in responses where urlString.contains(pattern) {
            let urlResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            return (response.data, urlResponse)
        }
        throw URLError(.badURL)
    }
}

private actor LargeResultPromptRecorder {
    private var calls: [(totalCount: Int, sourceLabel: String)] = []

    func record(totalCount: Int, sourceLabel: String) {
        calls.append((totalCount, sourceLabel))
    }

    func count() -> Int {
        calls.count
    }
}
