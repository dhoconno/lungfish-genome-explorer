// DatabaseBrowserNoProjectDownloadRefusalTests.swift - A Database Browser download with no project says No Project Open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A60 M2 (plan row K2, decision C2 branch b, Q-A2 with UX's words). With no project
// the browser's download ran in process, built in the system scratch folder, and the import copied
// the bundle into the user's `Downloads/Lungfish Downloads` folder while the row named only the
// bundle and recorded no command (`download-genome-no-project`, pinned by lane A60 M1 at
// base 4586560ed). That folder is one a person can find, but the row never names it, so C2 takes
// branch b. The download now refuses before any row, in the words of Q-U65's family, `No Project
// Open` over `Open or create a project before downloading <thing>.`, through
// `AppDelegate.NoProjectPresenterSeam`. It starts no row, launches nothing, asks no service and makes
// no folder. The tests bind a recording presenter, because no test can click an alert away.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport

@MainActor
final class DatabaseBrowserNoProjectDownloadRefusalTests: XCTestCase {
    /// One kind of browser row, with what a person downloads through it.
    struct Kind {
        let name: String
        let source: DatabaseSource
        let searchType: NCBISearchType
        let accession: String
        let organism: String?
        /// The noun the No Project Open refusal names.
        let thing: String
    }

    static let kinds: [Kind] = [
        Kind(name: "genome", source: .ncbi, searchType: .genome, accession: "GCF_003047895.1", organism: nil,
             thing: "genome assemblies"),
        Kind(name: "GenBank", source: .ncbi, searchType: .nucleotide, accession: "MN908947.3", organism: nil,
             thing: "GenBank records"),
        Kind(name: "virus", source: .ncbi, searchType: .virus, accession: "NC_045512.2", organism: nil,
             thing: "virus records"),
        Kind(name: "Pathoplexus", source: .pathoplexus, searchType: .nucleotide, accession: "PP_0012345", organism: "mpox",
             thing: "Pathoplexus records"),
        Kind(name: "SRA", source: .ena, searchType: .nucleotide, accession: "SRR11140748", organism: nil,
             thing: "SRA runs"),
    ]

    /// No route context, and the context a main window with no project gives the browser
    /// (`currentOperationRouteContext`), which names the window and no project.
    static let noProjectContexts: [OperationRouteContext?] = [
        nil,
        OperationRouteContext(projectURL: nil, windowStateScopeID: UUID()),
    ]

    /// The `batch-` folders directly in `folder`.
    static func batchFolders(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasPrefix("batch-") })
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    func testEachRowWithNoProjectRefusesWithNoProjectOpenAndStartsNothing() {
        for context in Self.noProjectContexts {
            for kind in Self.kinds {
                let label = "\(kind.name), context \(context == nil ? "nil" : "with a window only")"
                let reporter = RecordingOperationReporter()
                let recorder = RecordingNoProjectPresenter()
                var launched = 0
                var result: OperationStartResult?
                AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
                    result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
                        title: kind.accession,
                        accessions: [kind.accession],
                        source: kind.source,
                        searchType: kind.searchType,
                        routeContext: context,
                        pathoplexusOrganism: kind.organism,
                        reporter: reporter
                    ) { _ in launched += 1 }
                }

                XCTAssertNil(result, "\(label): nothing reached the reporter")
                XCTAssertEqual(reporter.items.count, 0, "\(label): no row")
                XCTAssertEqual(launched, 0, "\(label): nothing launched")
                XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"], label)
                XCTAssertEqual(
                    recorder.presentations.map(\.message),
                    ["Open or create a project before downloading \(kind.thing)."], label)
                XCTAssertFalse(
                    recorder.presentations.contains { $0.message.contains("Analyses") || $0.message.contains("Downloads") },
                    "\(label): the refusal names no folder")
            }
        }
    }

    func testTheRefusalSitsOnTheWindowItIsGivenAndIsAppModalWithNone() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = RecordingNoProjectPresenter()
        let reporter = RecordingOperationReporter()
        var refused = 0
        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            for presentingWindow in [window, nil] as [NSWindow?] {
                let result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
                    title: "SRR11140748", accessions: ["SRR11140748"], source: .ena, searchType: .nucleotide,
                    routeContext: nil, presentingWindow: presentingWindow, reporter: reporter
                ) { _ in }
                if result == nil { refused += 1 }
            }
        }

        XCTAssertEqual(refused, 2)
        XCTAssertEqual(reporter.items.count, 0)
        XCTAssertEqual(
            recorder.presentations.map(\.message),
            Array(repeating: "Open or create a project before downloading SRA runs.", count: 2))
        XCTAssertTrue(recorder.presentations.first?.window === window, "a sheet on the browser's window")
        XCTAssertNil(recorder.presentations.last?.window, "app-modal with no window")
    }

    func testAGenomeRowWithNoProjectAsksNCBINothingAndMakesNoFolder() async throws {
        let suite = makeTestDefaultsSuite(prefix: "a60-no-project-refusal")
        let client = RefusingNCBIClient()
        let model = DatabaseBrowserViewModel(
            source: .ncbi, ncbiService: NCBIService(httpClient: client), defaultsSuiteName: suite.name)
        model.ncbiSearchType = .genome
        let accession = "GCF_960000002.1"
        model.selectedRecord = SearchResultRecord(id: "960000002", accession: accession, title: "A60 refusal", source: .ncbi)
        var dismissed = false
        model.onDownloadStarted = { dismissed = true }
        let scratch = ProjectTempDirectory.systemTemporaryDirectory()
        let before = Self.batchFolders(in: scratch)
        let recorder = RecordingNoProjectPresenter()

        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) { model.performBatchDownload() }

        let row = OperationCenter.shared.items.first { $0.title == accession }
        if let row {
            // Only a route that still starts the row gets here. Let it end before reading the folder.
            await waitUntil(timeout: .seconds(30)) {
                OperationCenter.shared.items.first { $0.id == row.id }?.state.isActive != true
            }
            OperationCenter.shared.clearItem(id: row.id)
        }
        let made = Self.batchFolders(in: scratch).subtracting(before)
        for name in made { try? FileManager.default.removeItem(at: scratch.appendingPathComponent(name)) }

        XCTAssertNil(row, "no row starts")
        XCTAssertFalse(dismissed, "the browser stays open, so the person can go and open a project")
        XCTAssertFalse(model.isDownloading)
        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(
            recorder.presentations.map(\.message), ["Open or create a project before downloading genome assemblies."])
        let requested = await client.requestedURLs
        XCTAssertEqual(requested, [], "no service is asked")
        XCTAssertEqual(made, [], "no folder is made")
    }

    /// The SRA row is the only one with work before its row, the metadata lookup and the import
    /// sheet, and it starts that work inside the launch, after the begin helper's guard. Driven
    /// through the browser's own entry, a move of the preparation ahead of the begin fails here.
    func testAnSRARowWithNoProjectAsksENANothingAndStartsNoPreparation() async throws {
        let suite = makeTestDefaultsSuite(prefix: "a60-no-project-refusal-sra")
        let client = RefusingNCBIClient()
        let model = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(httpClient: client),
            enaService: ENAService(httpClient: client), defaultsSuiteName: suite.name)
        let accession = "SRR9000002"
        model.selectedRecord = SearchResultRecord(id: accession, accession: accession, title: "A60 refusal", source: .ena)
        var dismissed = false
        model.onDownloadStarted = { dismissed = true }
        let recorder = RecordingNoProjectPresenter()

        AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) { model.performBatchDownload() }

        let row = OperationCenter.shared.items.first { $0.title == accession }
        if let row {
            // Only a route that still begins the row gets here. Cancel it and let it end.
            OperationCenter.shared.cancel(id: row.id)
            await waitUntil(timeout: .seconds(30)) {
                OperationCenter.shared.items.first { $0.id == row.id }?.state.isActive != true
            }
            OperationCenter.shared.clearItem(id: row.id)
        }

        XCTAssertNil(row, "no row starts, so no preparation starts")
        XCTAssertFalse(dismissed, "the browser stays open")
        XCTAssertFalse(model.isDownloading)
        XCTAssertTrue(model.preparingSRADownloadIDs.isEmpty, "no preparation is registered")
        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(
            recorder.presentations.map(\.message), ["Open or create a project before downloading SRA runs."])
        let requested = await client.requestedURLs
        XCTAssertEqual(requested, [], "no lookup is made before the refusal")
    }

    /// The import sheet hands its runs to `startSRADownloadTask` only after the row began, which the
    /// refusal prevents with no project. A row handed over with none anyway fails in the refusal's words,
    /// records no command and asks no archive, since the in-process download that once took it went with
    /// the hidden key of the SRA row (lane A60 M3, K3).
    func testAnSRARowHandedOverWithNoProjectFailsInTheRefusalsWordsAndAsksNothing() async throws {
        let suite = makeTestDefaultsSuite(prefix: "a60-no-project-sra-hand-over")
        let client = RefusingNCBIClient()
        let model = DatabaseBrowserViewModel(
            source: .ena, ncbiService: NCBIService(httpClient: client),
            enaService: ENAService(httpClient: client), defaultsSuiteName: suite.name)
        XCTAssertNil(model.routeContext?.projectURL)
        let accession = "SRR9000003"
        let id = try XCTUnwrap(
            OperationCenter.shared.begin(
                title: accession, detail: "Preparing 1 record(s)...", operationType: .download, cliCommand: nil
            ).startedID)
        defer { OperationCenter.shared.clearItem(id: id) }

        model.startSRADownloadTask(
            records: [SearchResultRecord(id: accession, accession: accession, title: "A60 hand-over", source: .ena)],
            importConfig: DatabaseBrowserSRARowParityReplayTests.sheet(), downloadCenterTaskID: id, totalCount: 1)

        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.detail, "Open or create a project before downloading SRA runs.")
        XCTAssertNil(row.cliCommand, "the row records no command")
        let requested = await client.requestedURLs
        XCTAssertEqual(requested, [], "no archive is asked")
    }
}

/// An NCBI client that refuses every request and records the URL it was asked for.
actor RefusingNCBIClient: HTTPClient {
    private(set) var requestedURLs: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestedURLs.append(request.url?.absoluteString ?? "")
        throw URLError(.cannotConnectToHost)
    }
}
