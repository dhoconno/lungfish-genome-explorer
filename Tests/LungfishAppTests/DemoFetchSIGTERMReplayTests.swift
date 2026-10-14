// DemoFetchSIGTERMReplayTests.swift - SIGTERM to lungfish-cli demo fetch alone cancels the install
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M4 and the SIGTERM test of ADDING-AN-OPERATION.md, as FetchPathoplexusSIGTERMReplayTests
// checks `fetch pathoplexus`. The Demo Projects window's Cancel sends SIGTERM to the CLI. The window's own cancel
// test goes through the transport (DemoProjectsCLIRoutePinReplayTests), and this test starts the built CLI with
// `CLISIGTERMHarness.launchCLI` and sends the one SIGTERM to the CLI alone, as `kill <pid>` does. The loopback
// stand-in holds its answer to the archive until the test has cancelled, so the cancel lands while the command
// has staged its hidden folder and waits for the transfer. The command exits 125 inside `operationGrace`, writes
// its `failed` event with the words `Fetch cancelled` as the status of its run, leaves no project and no staging
// folder, and leaves no process of its tree.
//
// Before this milestone the command named no signal. SIGTERM ended it with the default action, so the `defer`
// that removes the staging folder never ran and the hidden `.lge-demo-staging-<UUID>` folder stayed in the
// destination.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DemoFetchSIGTERMReplayTests: XCTestCase {
    func testSIGTERMToTheCLIAloneCancelsTheDemoFetchAndRemovesItsStagingFolder() async throws {
        let root = try TestTempDirectory.make(prefix: "demo-fetch-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let hold = StandInHold()
        let standIn = try DemoArchiveStandIn.start(in: root, hold: hold)
        defer { standIn.stop() }
        defer { hold.release() }
        let work = root.appendingPathComponent("work", isDirectory: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "demo", "fetch", DemoArchiveStandIn.projectID, "--dest", work.path,
                "--manifest", standIn.manifestURL.path, "--format", "json",
            ],
            environment: standIn.environment,
            workingDirectory: root,
            testClass: Self.self)
        defer { cli.stop() }

        // The command asks for the archive once it has staged its hidden folder in the destination.
        let reached = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            standIn.server.requests.contains { $0.path == DemoArchiveStandIn.archivePath }
        }
        guard reached else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The command never asked for the archive: \(standIn.server.requests.map(\.target)).\(stop.diagnostics)")
        }
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertEqual(staged.filter { $0.hasPrefix(".lge-demo-staging-") }.count, 1, "the install staged its folder before the cancel: \(staged)")
        let stop = await CLISIGTERMHarness.cancel(cli)
        hold.release()

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertRecordCancelled { FetchNCBIBundleSIGTERMReplayTests.status(ofEvents: stop.standardOutput) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertEqual(left, [], "a cancelled run leaves no project and no staging folder")
    }
}
