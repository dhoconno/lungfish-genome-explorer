// FetchNCBIBundleSIGTERMReplayTests.swift - SIGTERM to lungfish-cli fetch ncbi --bundle alone cancels the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M1b, ruling section 6 item 2 and the SIGTERM test of ADDING-AN-OPERATION.md.
// The app's Cancel sends SIGTERM to the CLI. The row's cancel test (DatabaseBrowserNucleotideRowCancelReplayTests)
// goes through the transport, and this test starts the built CLI with `CLISIGTERMHarness.launchCLI`
// and sends the one SIGTERM to the CLI alone, as `kill <pid>` does. The loopback NCBI stand-in holds its
// answer to the record's GFF3 until the test has cancelled, so the cancel lands while the command builds
// the bundle in its staging folder. The command exits 125 inside `operationGrace`, writes its `failed`
// event with the words `Fetch cancelled` as the status of its run, leaves no bundle and no staging
// folder, and leaves no process of its tree.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class FetchNCBIBundleSIGTERMReplayTests: XCTestCase {
    /// The status a run's last event reads as, `cancelled` for the `failed` event of a cancel.
    static func status(ofEvents output: String) -> String? {
        let decoder = CLIEventLineDecoder()
        let events = output.split(separator: "\n").compactMap { try? decoder.decode(line: String($0)) }
        guard case let .failed(message, _)? = events.last else { return nil }
        return message == "Fetch cancelled" ? CLISIGTERMHarness.cancelledRecordStatus : "failed: \(message)"
    }

    func testSIGTERMToTheCLIAloneCancelsTheBundleFetch() async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let root = try TestTempDirectory.make(prefix: "fetch-ncbi-sigterm")
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
        let downloads = project.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            ["fetch", "ncbi", NCBIDownloadPinFixtures.genBankAccession, "--bundle", "--output-dir", downloads.path, "--format", "json"],
            workingDirectory: root,
            testClass: Self.self)
        defer { cli.stop() }

        // The command asks for the GFF3 once it has fetched the record and begun to build the bundle.
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            server.requests.contains { $0.path == "/entrez/eutils/efetch.fcgi" && $0.target.contains("rettype=gff3") }
        }
        guard reached else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The command never asked for the GFF3: \(server.requests.map(\.target)).\(stop.diagnostics)")
        }
        let stop = await CLISIGTERMHarness.cancel(cli)
        hold.release()

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertRecordCancelled { Self.status(ofEvents: stop.standardOutput) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, "Downloads").filter { $0.hasSuffix(".lungfishref") }, [],
            "a cancelled run leaves no bundle")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, ".tmp").filter { $0.hasPrefix("fetch-ncbi-") }, [],
            "a cancelled run leaves no staging folder")
    }
}
