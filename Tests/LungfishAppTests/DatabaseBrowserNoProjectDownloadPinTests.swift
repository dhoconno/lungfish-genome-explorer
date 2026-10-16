// DatabaseBrowserNoProjectDownloadPinTests.swift - Where a Database Browser download with no project lands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A60 M1 (plan row K2, decision C2). These pins hold at base 4586560ed and record
// what a download from the Database Browser does when the window it was opened on has no project.
//
// - The row begins, runs and records no command, for the genome, GenBank, virus, Pathoplexus and
//   SRA rows alike, with no route context and with one that names only a window.
// - A genome row takes the in-process route whatever the hidden key holds, and that route makes its
//   batch folder in the system scratch folder before it asks NCBI for anything. A row that fails
//   leaves the empty folder there.
// - The import never keeps a bundle from that scratch folder in place. It copies it into the user's
//   `Downloads/Lungfish Downloads` folder (AppDelegate+Classification.swift), which no test here
//   writes into.
//
// The NCBI service is a client that refuses every request and records it, so no test reaches the
// network.

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
final class DatabaseBrowserNoProjectDownloadPinTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

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

    // MARK: - What the row records

    func testEachRowWithNoProjectBeginsLaunchesAndRecordsNoCommand() {
        for context in Self.noProjectContexts {
            for kind in Self.kinds {
                let label = "\(kind.name), context \(context == nil ? "nil" : "with a window only")"
                let reporter = RecordingOperationReporter()
                var launched = 0
                let result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
                    title: kind.accession,
                    accessions: [kind.accession],
                    source: kind.source,
                    searchType: kind.searchType,
                    routeContext: context,
                    pathoplexusOrganism: kind.organism,
                    reporter: reporter
                ) { _ in launched += 1 }

                XCTAssertEqual(reporter.items.count, 1, label)
                XCTAssertNotNil(result.startedID, label)
                XCTAssertEqual(launched, 1, label)
                XCTAssertNil(reporter.items.first?.cliCommand, label)
            }
        }
    }

    // MARK: - Where the in-process task writes and what the row shows

    func testAGenomeRowWithNoProjectRunsInProcessInTheSystemScratchFolderWhateverTheKeyHolds() async throws {
        let suite = makeTestDefaultsSuite(prefix: "a60-no-project-genome")
        suite.defaults.set("cli", forKey: GenomeRowDownloadRouteSettings.defaultsKey)
        let client = RefusingNCBIClient()
        let model = DatabaseBrowserViewModel(
            source: .ncbi, ncbiService: NCBIService(httpClient: client), sraDownloadSuiteName: suite.name)
        model.ncbiSearchType = .genome
        let accession = "GCF_960000001.1"
        model.selectedRecord = SearchResultRecord(id: "960000001", accession: accession, title: "A60 pin", source: .ncbi)
        let scratch = ProjectTempDirectory.systemTemporaryDirectory()
        let before = Self.batchFolders(in: scratch)

        model.performBatchDownload()

        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == accession })
        defer { OperationCenter.shared.clearItem(id: row.id) }
        await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.items.first { $0.id == row.id }?.state == .failed
        }
        let made = Self.batchFolders(in: scratch).subtracting(before)
        defer {
            for name in made { try? FileManager.default.removeItem(at: scratch.appendingPathComponent(name)) }
        }

        let ended = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == row.id })
        XCTAssertEqual(ended.state, .failed)
        XCTAssertNil(ended.cliCommand, "the row records no command")
        XCTAssertTrue(ended.detail.hasPrefix("Completed with 1 failure(s): \(accession): "), ended.detail)
        let requested = await client.requestedURLs
        XCTAssertTrue(
            requested.contains { $0.contains("esummary") },
            "the in-process route asks NCBI for the assembly summary, where the CLI route would launch a child: \(requested)")
        XCTAssertEqual(made.count, 1, "the in-process route made one batch folder in the system scratch folder")
        for name in made {
            let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent(name).path)
            XCTAssertEqual(contents, [], "the failed row leaves its empty batch folder behind")
        }
    }

    func testTheBatchFolderOfARowWithNoProjectIsInTheSystemScratchFolder() throws {
        let folder = try BatchDownloadFolder(projectURL: nil).url()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(
            folder.deletingLastPathComponent().standardizedFileURL.path,
            ProjectTempDirectory.systemTemporaryDirectory().standardizedFileURL.path)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("batch-"), folder.lastPathComponent)
    }

    func testTheImportCopiesABundleFromTheScratchFolderInsteadOfKeepingIt() {
        // With no project and no working folder the import copies the bundle into the user's
        // Downloads/Lungfish Downloads folder and removes the one it was given, so the row's
        // bundle URL names a removed path. No test writes into the user's Downloads folder, so
        // this pins the rule that sends it there.
        let bundle = ProjectTempDirectory.systemTemporaryDirectory()
            .appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("GCF_960000001.1.lungfishref", isDirectory: true)
        XCTAssertFalse(DownloadImportRouting.shouldPreserveInPlace(
            downloadedURL: bundle, projectURL: nil, workingDirectoryURL: nil))
    }

    // MARK: - Helpers

    static func batchFolders(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasPrefix("batch-") })
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
