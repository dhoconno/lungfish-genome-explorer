// FastqIngestCancelReplayTests.swift - The Cancel of `fastq ingest` through the app's transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2 (SWIFT 3, panel decisions C5, P2 and G1). The window's Cancel reaches a
// CLI route through `CLISubprocessTransport.cancel()`, so ToolProcess sends SIGTERM to the
// command and its tree, and SIGKILL after `CLIProcessLauncher.operationGrace`. `FastqIngestSIGTERMTests`
// signals the command alone. This test cancels the way the app does, while a stand-in clumpify
// holds a half-written output in the command's hidden folder. The command must exit 125 inside
// the grace, write its `cancelled` record, and leave the original file as it was, with no output
// and no process behind (lane S30's checks).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier. It needs no real tool.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class FastqIngestCancelReplayTests: XCTestCase {
    /// Past the grace, for the hop of the cancel to the transport and the drain of the output.
    static let margin: Duration = .seconds(2)

    private static let reads = "@read1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n@read2\nTTGGCCAATTGG\n+\nIIIIIIIIIIII\n"

    func testACancelThroughTheTransportExits125RecordsTheCancelAndLeavesTheOriginal() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-cancel")
        defer { TestTempDirectory.cleanup(root) }

        // A stand-in for the managed clumpify.sh, in a conda root of this test's own. It records its
        // pid, writes half an output where `out=` says, and waits.
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let script = condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo $$ > "$CLUMPIFY_PID_FILE"
        for argument in "$@"; do
          case "$argument" in
            out=*) printf 'half' > "${argument#out=}" ;;
          esac
        done
        exec /bin/sleep 300
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("clumpify.pid")

        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let recordURL = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        // The route's transport, as the L6 runner builds it: a real grace, events on standard output.
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let environment = [
            "LUNGFISH_CONDA_ROOT": condaRoot.path,
            "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": home.path,
            "CLUMPIFY_PID_FILE": pidFile.path,
        ]
        let run = Task {
            try await transport.run(
                arguments: ["fastq", "ingest", input.path, "--delete-originals", "--format", "json"],
                terminationGracePeriod: CLIProcessLauncher.operationGrace,
                environmentAdditions: environment,
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        // The stand-in runs, so the command is listening for SIGTERM and its output is half written.
        guard await CLISIGTERMHarness.waitForProcessID(in: pidFile) != nil else {
            transport.cancel()
            _ = await run.result
            return XCTFail("The command never started the stand-in clumpify")
        }
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        let cliPID = try XCTUnwrap(tree.min(), "the command and its tree run")
        let watch = try XCTUnwrap(ChildExitWatch(pid: cliPID), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        transport.cancel()
        let outcome = await run.result
        let elapsed = ContinuousClock.now - sent

        XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        CLISIGTERMHarness.assertCancelledExit(
            status: watch.exitCode(timeoutSeconds: 5),
            elapsed: elapsed,
            within: CLIProcessLauncher.operationGrace + Self.margin
        )
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        CLISIGTERMHarness.assertRecordCancelled {
            try ProvenanceEnvelopeReader.load(fromSidecar: recordURL)?.status.rawValue
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            [ProvenanceRecorder.provenanceFilename, "SRR9_1.fastq"],
            "the original and the cancelled record remain, with no output, sidecar or hidden folder"
        )
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads, "the original is as it was")
    }
}
