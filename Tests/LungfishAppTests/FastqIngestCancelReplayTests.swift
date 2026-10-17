// FastqIngestCancelReplayTests.swift - The Cancel of `fastq ingest` through the app's transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2 and M3 (SWIFT 3, panel decisions C5, P2 and G1, and the ruling on M3
// section 5). The window's Cancel reaches a CLI route through `CLISubprocessTransport.cancel()`,
// so ToolProcess sends SIGTERM to the command and its tree, and SIGKILL after
// `CLIProcessLauncher.operationGrace`. `FastqIngestSIGTERMTests` signals the command alone. These
// tests cancel the way the app does, while a stand-in clumpify holds a half-written output in the
// command's staging folder. The command must exit 125 inside the grace and leave no process behind.
//
// - A folder with no record gets the command's `cancelled` record, and the original is as it was.
// - A folder that holds a record already is the file's history, so the cancel writes nothing and
//   every file in it keeps its digest, with nothing staged beside the input.
// - The first case again with every core busy, since the handler that writes the record races the
//   death of the tool on a loaded machine.
// - Since 2.11 S8 the command stages in the system temp folder, so each run gives it a `TMPDIR` of its own
//   through the process environment. One `lungfish-ingest-*` folder sits there while the stand-in holds its
//   output, and the folder is empty once the cancel ends.
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

    /// What one cancel through the transport observed.
    private struct Cancelled {
        let outcome: Result<CLISubprocessTransport.Result, Error>
        let status: Int32?
        let elapsed: Duration
        let tree: [Int32]
        /// The system temp folder the command was given, and what it held while the stand-in clumpify ran.
        let systemTemp: URL
        let staged: [String]
    }

    /// Runs `fastq ingest` on `input` through the transport the L6 runner uses, against a stand-in
    /// clumpify under `root`, cancels once the clumpify holds a half-written output, and returns
    /// what the cancel observed.
    private func cancelIngest(of input: URL, in root: URL) async throws -> Cancelled {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
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
        // 2.11 S8. The command stages in the system temp folder it inherits, here a folder of this test's own.
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        let previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
        defer { if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") } }

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
        let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(url: input)
        let run = Task {
            try await transport.run(
                arguments: arguments,
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
            XCTFail("The command never started the stand-in clumpify")
            throw CancellationError()
        }
        let staged = ((try? FileManager.default.contentsOfDirectory(atPath: systemTemp.path)) ?? []).sorted()
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
        let cliPID = try XCTUnwrap(tree.min(), "the command and its tree run")
        let watch = try XCTUnwrap(ChildExitWatch(pid: cliPID), "cannot watch \(tree)")
        let sent = ContinuousClock.now
        transport.cancel()
        let outcome = await run.result
        let elapsed = ContinuousClock.now - sent
        return Cancelled(
            outcome: outcome, status: watch.exitCode(timeoutSeconds: 5), elapsed: elapsed, tree: tree,
            systemTemp: systemTemp, staged: staged
        )
    }

    private func assertCancelledInsideTheGrace(_ cancelled: Cancelled) async {
        XCTAssertThrowsError(try cancelled.outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        CLISIGTERMHarness.assertCancelledExit(
            status: cancelled.status,
            elapsed: cancelled.elapsed,
            within: CLIProcessLauncher.operationGrace + Self.margin
        )
        await CLISIGTERMHarness.assertNoProcessLeft(cancelled.tree)
        // The stage sat in the system temp folder the command inherited, and the cancel removed it.
        XCTAssertEqual(cancelled.staged.count, 1, "the command stages in the system temp folder it inherits: \(cancelled.staged)")
        XCTAssertTrue(cancelled.staged.allSatisfy { $0.hasPrefix("lungfish-ingest-") }, "\(cancelled.staged)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cancelled.systemTemp.path), [],
            "a cancelled ingest leaves no staging folder"
        )
    }

    /// The SHA-256 of every entry directly in `folder` by name, with a marker for a folder.
    private func digests(in folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[name] = isDirectory.boolValue ? "folder" : try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }

    func testACancelThroughTheTransportExits125RecordsTheCancelAndLeavesTheOriginal() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let recordURL = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

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

    /// Ruling on M3, section 5. A bundle that holds the import record is the file's history, so the
    /// cancel writes nothing there. Every file keeps its digest and nothing is staged beside the input.
    func testACancelWhereARecordStandsChangesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-record-stands")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let imported = try ProvenanceRunBuilder(
            workflowName: "FASTQ Import", workflowVersion: "1", toolName: "lungfish-cli", toolVersion: "1"
        )
        .argv([CLICommandIdentity.executableName, "import", "fastq"])
        .output(input, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 11))
        try ProvenanceWriter(signingProvider: nil).write(imported, to: folder)
        let before = try digests(in: folder)
        XCTAssertNotNil(before[ProvenanceRecorder.provenanceFilename], "a record stands in the folder")

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

        XCTAssertEqual(try digests(in: folder), before, "every file keeps its digest, and nothing is staged beside the input")
    }

    /// Ruling on M3, section 5. The handler that writes the cancelled record runs while every core
    /// is busy, and it still finishes inside the grace.
    func testACancelWithEveryCoreBusyStillExits125InsideTheGrace() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let root = try TestTempDirectory.make(prefix: "fastq-ingest-transport-busy")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        await assertCancelledInsideTheGrace(try await cancelIngest(of: input, in: root))

        CLISIGTERMHarness.assertRecordCancelled {
            try ProvenanceEnvelopeReader.load(
                fromSidecar: folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            )?.status.rawValue
        }
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads, "the original is as it was")
    }
}
