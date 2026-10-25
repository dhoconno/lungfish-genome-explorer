// ImportFastqBatchAdoptSIGTERMTests.swift - How a SIGTERM ends `import fastq <batch folder> --adopt` (CHTC C5 lane BADOPT, review fix 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The window's Cancel sends SIGTERM to `lungfish-cli import fastq <returned batch folder> --adopt`. A cancel after bundle k
// must end as UX-c5 point 7 words it: `Adopt cancelled after k of n samples.`, with the bundles made, the samples left and
// the way on in the detail, and the bundles stay whole. The in-process cancel of `ImportFastqBatchAdoptTests` never sets
// the flag a real signal sets, so it cannot see the helper that turned every cancel into `Adopt cancelled. Nothing was
// imported.`; this class runs the built CLI and sends the real signal. The batch is two flat samples, A and B, that keep
// their reads, so the write of each sample starts the one tool the adopt starts, the `seqkit head` that samples the reads
// for the charts. The stand-in seqkit answers at once for A and, for B, writes its process ID and waits, so the batch is
// known to be writing B when the signal arrives.

import Darwin
import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class ImportFastqBatchAdoptSIGTERMTests: XCTestCase {
    /// A SIGTERM while the batch writes its second bundle cancels it. The command exits 125 inside the grace, keeps bundle A
    /// whole, leaves no staging bundle and no process, and ends the stream with one `failed` line that says the adopt was
    /// cancelled after 1 of 2 samples, names the bundle made, the sample left and the way on.
    func testSIGTERMAfterFirstBundleKeepsItAndNamesTheRest() async throws {
        let root = try TestTempDirectory.make(prefix: "adopt-batch-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        for name in ["A", "B"] {
            let returned = try ExecutorReturnedFolder.make(
                root: root.appendingPathComponent("made-\(name)", isDirectory: true), clumping: .bbtools, sample: name
            )
            try FileManager.default.moveItem(at: returned.folder, to: batch.appendingPathComponent(name, isDirectory: true))
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let seqkitPIDFile = root.appendingPathComponent("seqkit.pid")
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        // The head call names the staged file `<staging bundle>/<sample>.fastq.gz`, so the stand-in tells the samples apart
        // by that name and does not depend on how many calls each sample makes.
        try SIGTERMPinSupport.writeExecutable(
            """
            #!/bin/sh
            case "$*" in
              *version*) echo "v2.10.0"; exit 0 ;;
              *B.fastq.gz*) echo $$ > '\(seqkitPIDFile.path)'; exec sleep 120 ;;
            esac
            exit 0
            """,
            at: condaRoot.appendingPathComponent("envs/seqkit/bin/seqkit")
        )
        let cli = try CLISIGTERMHarness.launchCLI(
            ["import", "fastq", batch.path, "--adopt", "--project", project.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard await CLISIGTERMHarness.waitForProcessID(in: seqkitPIDFile) != nil else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The batch adopt never started the seqkit head of sample B.\(stop.diagnostics)")
        }
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let atSignal = Self.entries(of: imports)
        XCTAssertTrue(atSignal.contains("A.lungfishfastq"), "bundle A is published when the signal arrives: \(atSignal)")
        XCTAssertGreaterThan(atSignal.count, 1, "the batch is staging bundle B when the signal arrives: \(atSignal)")

        let stop = await CLISIGTERMHarness.cancel(cli)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(
            Self.entries(of: imports), ["A.lungfishfastq"],
            "a cancelled batch keeps the bundle it made and leaves no staging bundle.\(stop.diagnostics)"
        )
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        let failedLines = lines.filter { $0.contains(#""event":"failed""#) }
        XCTAssertEqual(failedLines.count, 1, "the stream ends with one failed line: \(stop.standardOutput)")
        XCTAssertEqual(lines.last, failedLines.first, "the failed line ends the stream: \(stop.standardOutput)")
        let line = try XCTUnwrap(failedLines.first, stop.standardOutput)
        let decoded = try XCTUnwrap(try CLIEventLineDecoder().decodeLine(line), line)
        guard case let .failed(message, detail)? = decoded.event else { return XCTFail("not a failed line: \(line)") }
        XCTAssertEqual(message, "Adopt cancelled after 1 of 2 samples.")
        XCTAssertEqual(
            detail,
            "Imported: A.lungfishfastq.\nNot imported: B.\nTo adopt the rest, delete the imported bundles and adopt the batch again."
        )
    }

    /// The names in a folder, hidden staging bundles included.
    private static func entries(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}
