// FetchPathoplexusSIGTERMReplayTests.swift - SIGTERM to lungfish-cli fetch pathoplexus alone cancels the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M2 (e) and the SIGTERM test of ADDING-AN-OPERATION.md, as
// FetchNCBIBundleSIGTERMReplayTests checks `fetch ncbi --bundle`. The app's Cancel sends SIGTERM to the
// CLI. The row's cancel test (DatabaseBrowserPathoplexusRowCancelReplayTests) goes through the transport,
// and this test starts the built CLI with `CLISIGTERMHarness.launchCLI` and sends the one SIGTERM to the
// CLI alone, as `kill <pid>` does. The loopback NCBI stand-in holds its answer to the record's GFF3 until
// the test has cancelled, so the cancel lands while the command builds the GenBank bundle of a record
// with an INSDC accession in its staging folder. The command exits 125 inside `operationGrace`, writes
// its `failed` event with the words `Fetch cancelled` as the status of its run, leaves no bundle and no
// staging folder, and leaves no process of its tree.
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
final class FetchPathoplexusSIGTERMReplayTests: XCTestCase {
    func testSIGTERMToTheCLIAloneCancelsThePathoplexusFetch() async throws {
        do {
            try await GenBankDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let root = try TestTempDirectory.make(prefix: "fetch-pathoplexus-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let hold = StandInHold()
        let ncbi = try await NCBIGenomeStandIn.start(
            servingIn: root.appendingPathComponent("served", isDirectory: true), holding: hold)
        defer { ncbi.stop() }
        defer { hold.release() }
        let lapis = try PathoplexusLAPISStandIn.start()
        defer { lapis.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [
                NCBIServiceEndpoints.standInOriginVariable: ncbi.baseURL.absoluteString,
                PathoplexusServiceEndpoints.standInOriginVariable: lapis.baseURL.absoluteString,
            ],
            unset: ["NCBI_API_KEY"])
        defer { saved.restore() }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let downloads = project.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "fetch", "pathoplexus", PathoplexusLAPISStandIn.openWithINSDC, "--organism", PathoplexusLAPISStandIn.organism,
                "--output-dir", downloads.path, "--format", "json",
            ],
            workingDirectory: root,
            testClass: Self.self)
        defer { cli.stop() }

        // The command asks for the GFF3 once it has read the record and begun to build the bundle.
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            ncbi.requests.contains { $0.path == "/entrez/eutils/efetch.fcgi" && $0.target.contains("rettype=gff3") }
        }
        guard reached else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The command never asked for the GFF3: \(ncbi.requests.map(\.target)).\(stop.diagnostics)")
        }
        let stop = await CLISIGTERMHarness.cancel(cli)
        hold.release()

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertRecordCancelled { FetchNCBIBundleSIGTERMReplayTests.status(ofEvents: stop.standardOutput) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, "Downloads").filter { $0.hasSuffix(".lungfishref") }, [],
            "a cancelled run leaves no bundle")
        XCTAssertEqual(
            DatabaseBrowserGenomeRowCancelReplayTests.entries(of: project, ".tmp").filter {
                $0.hasPrefix("fetch-pathoplexus-") || $0.hasPrefix("genbank-")
            }, [],
            "a cancelled run leaves no staging folder")
    }
}
