// DatabaseBrowserGenomeRowCancelReplayTests.swift - The Cancel of a genome row on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44, review fix F6 (SWIFT 3, panel decision G1). A genome row of the NCBI
// browser's batch download runs `lungfish-cli fetch genome` on the CLI route. The batch row's
// Cancel reaches the child through the callback the row installs (`transport.cancel()`), so
// ToolProcess sends SIGTERM, and SIGKILL after `CLIProcessLauncher.operationGrace`. The loopback
// NCBI stand-in holds its answer to the assembly's FASTA until the test has cancelled, so the
// cancel lands while the child downloads. The child must exit 125 inside the grace and leave no
// bundle, staging folder or process behind (lane S30's checks), and the batch's second row must
// launch no child.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DatabaseBrowserGenomeRowCancelReplayTests: XCTestCase {
    /// Past the grace, for the hop of the cancel to the transport and the drain of the output.
    static let margin: Duration = .seconds(2)

    func testACancelledGenomeRowExits125AndLeavesNoBundle() async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "genome-row-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let hold = StandInHold()
        let server = try await NCBIGenomeStandIn.start(
            servingIn: root.appendingPathComponent("served", isDirectory: true), holding: hold)
        defer { server.stop() }
        defer { hold.release() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // The batch row of two genome rows, begun as the browser begins it.
        let records = [
            DatabaseBrowserGenomeRowParityReplayTests.record,
            SearchResultRecord(id: "9900009", accession: NCBIGenomeStandIn.unknownAccession, title: "Second", source: .ncbi),
        ]
        let started = DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: "Genome: \(records.map(\.accession).joined(separator: ", "))",
            accessions: records.map(\.accession), source: .ncbi, searchType: .genome,
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        ) { _ in }
        let operationID = try XCTUnwrap(started?.startedID)
        defer { _ = OperationCenter.shared.acknowledgeCancellation(id: operationID) }
        let service = NCBIService()
        let genomeVM = GenomeDownloadViewModel(ncbiService: service)
        let batchFolder = BatchDownloadFolder(projectURL: project)
        let row: @Sendable (Int) async throws -> URL = { index in
            try await DatabaseBrowserViewModel.downloadGenomeRow(
                records[index], index: index, totalCount: records.count, operationID: operationID, route: .cli,
                ncbi: service, genomeVM: genomeVM, batchFolder: batchFolder, projectURL: project, cliURLOverride: cli)
        }

        // Row 1 runs until the stand-in holds its FASTA, then the batch row is cancelled.
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let first = Task { try await row(0) }
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            server.requests.contains { $0.method == "GET" && $0.path == NCBIGenomeStandIn.assemblyFASTAPath }
        }
        XCTAssertTrue(reached, "the child never asked for the FASTA: \(server.requests.map(\.target))")
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        XCTAssertEqual(tree.count, 1, "only the child runs while its FASTA is held: \(tree)")
        let watch = try XCTUnwrap(tree.first.flatMap(ChildExitWatch.init(pid:)), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        OperationCenter.shared.cancel(id: operationID)
        let firstResult = await first.result
        let elapsed = ContinuousClock.now - sent
        hold.release()

        XCTAssertThrowsError(try firstResult.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(watch.exitCode(timeoutSeconds: 5), CLISIGTERMHarness.cancelledExitStatus, "the child exits 125")
        XCTAssertLessThanOrEqual(elapsed, CLIProcessLauncher.operationGrace + Self.margin)
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        XCTAssertEqual(Self.entries(of: project, "Downloads").filter { $0.hasSuffix(".lungfishref") }, [])
        XCTAssertEqual(Self.entries(of: project, ".tmp").filter { $0.hasPrefix("fetch-genome-") || $0.hasPrefix("batch-") }, [])

        // The batch goes on to row 2, whose transport sees the cancelled row and launches nothing.
        let requests = server.requests.count
        do {
            _ = try await row(1)
            XCTFail("row 2 ran after the cancel")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(
            server.requests.count, requests,
            "a child ran for row 2: \(server.requests.dropFirst(requests).map(\.target))")
    }

    /// The names in `folder` of `project`, none when it does not exist.
    static func entries(of project: URL, _ folder: String) -> [String] {
        let url = project.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

/// Reads the exit code of a child of this test process that another owner launched and reaps,
/// through kqueue's `NOTE_EXITSTATUS`, so a test sees how the CLI a row's transport ran exited.
final class ChildExitWatch: Sendable {
    private let queue: Int32

    /// Watches `pid`, which must be a child of this process and still run. Nil when kqueue fails.
    init?(pid: Int32) {
        let queue = kqueue()
        guard queue >= 0 else { return nil }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(truncatingIfNeeded: NOTE_EXIT) | UInt32(truncatingIfNeeded: NOTE_EXITSTATUS),
            data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            return nil
        }
        self.queue = queue
    }

    deinit {
        close(queue)
    }

    /// The exit code once the child has exited, nil when a signal ended it or nothing came in time.
    func exitCode(timeoutSeconds: Int) -> Int32? {
        var event = kevent()
        var limit = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        guard kevent(queue, nil, 0, &event, 1, &limit) == 1 else { return nil }
        let status = Int32(truncatingIfNeeded: event.data)
        return status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}
