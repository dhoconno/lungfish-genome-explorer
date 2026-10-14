// DatabaseBrowserNucleotideRowCancelReplayTests.swift - The Cancel of a nucleotide row on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 (SWIFT 3, panel decision G1), as lane A44 checks a genome row. A nucleotide
// row of the NCBI browser's batch download runs `lungfish-cli fetch ncbi --bundle` on the CLI route.
// The batch row's Cancel reaches the child through the callback the row installs
// (`transport.cancel()`), so ToolProcess sends SIGTERM, and SIGKILL after
// `CLIProcessLauncher.operationGrace`. The loopback NCBI stand-in holds its answer to the record's
// GFF3 until the test has cancelled, so the cancel lands while the child builds the bundle in its
// staging folder. The child must exit 125 inside the grace and leave no bundle, staging folder or
// process behind, and the batch's second row must launch no child.
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
final class DatabaseBrowserNucleotideRowCancelReplayTests: XCTestCase {
    func testACancelledNucleotideRowExits125AndLeavesNoBundle() async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "nucleotide-row-cancel")
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

        // The batch row of two nucleotide rows, begun as the browser begins it.
        let records = [
            DatabaseBrowserNucleotideRowParityReplayTests.record,
            DatabaseBrowserNucleotideRowParityReplayTests.recordWithoutGFF3,
        ]
        let started = DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: "GenBank: \(records.map(\.accession).joined(separator: ", "))",
            accessions: records.map(\.accession), source: .ncbi, searchType: .nucleotide,
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
        ) { _ in }
        let operationID = try XCTUnwrap(started.startedID)
        defer { _ = OperationCenter.shared.acknowledgeCancellation(id: operationID) }
        let service = NCBIService()
        let genBankVM = GenBankBundleDownloadViewModel(ncbiService: service)
        let batchFolder = BatchDownloadFolder(projectURL: project)
        let row: @Sendable (Int) async throws -> URL = { index in
            try await DatabaseBrowserViewModel.downloadNucleotideRow(
                records[index], index: index, totalCount: records.count, operationID: operationID, route: .cli,
                ncbi: service, genBankVM: genBankVM, includeGFF3Annotations: true, batchFolder: batchFolder,
                projectURL: project, cliURLOverride: cli)
        }

        // Row 1 runs until the stand-in holds its GFF3, then the batch row is cancelled.
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let first = Task { try await row(0) }
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            server.requests.contains { $0.path == "/entrez/eutils/efetch.fcgi" && $0.target.contains("rettype=gff3") }
        }
        XCTAssertTrue(reached, "the child never asked for the GFF3: \(server.requests.map(\.target))")
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        XCTAssertEqual(tree.count, 1, "only the child runs while its GFF3 is held: \(tree)")
        let watch = try XCTUnwrap(tree.first.flatMap(ChildExitWatch.init(pid:)), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        OperationCenter.shared.cancel(id: operationID)
        let firstResult = await first.result
        let elapsed = ContinuousClock.now - sent
        hold.release()

        XCTAssertThrowsError(try firstResult.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(watch.exitCode(timeoutSeconds: 5), CLISIGTERMHarness.cancelledExitStatus, "the child exits 125")
        XCTAssertLessThanOrEqual(elapsed, CLIProcessLauncher.operationGrace + DatabaseBrowserGenomeRowCancelReplayTests.margin)
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        XCTAssertEqual(DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, "Downloads").filter { $0.hasSuffix(".lungfishref") }, [])
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, ".tmp")
                .filter { $0.hasPrefix("fetch-ncbi-") || $0.hasPrefix("batch-") || $0.hasPrefix("genbank-") },
            [])

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
}
