// ImportFastqAdoptSIGTERMTests.swift - How a SIGTERM ends `import fastq <folder> --adopt` (CHTC C4 lane V2, review A2 fix 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The window's Cancel sends SIGTERM to `lungfish-cli import fastq <returned folder> --adopt`. The adopt must end as
// `import fastq` does: remove its hidden staging bundle, exit 125 and end the stream with one `failed` line. The adopt
// starts one tool, the `seqkit head` that samples the reads for the charts, so the built CLI runs against a stand-in
// seqkit that writes its process ID and waits, and the adopt is known to be at work when the signal arrives.

import Darwin
import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class ImportFastqAdoptSIGTERMTests: XCTestCase {
    /// A SIGTERM while the adopt samples the reads cancels it. The command exits 125 inside the grace, ends the stream
    /// with one `failed` line, leaves nothing in the project's `Imports` folder and no process behind.
    func testSIGTERMCancelsTheAdoptAndLeavesNoStagingBundle() async throws {
        let root = try TestTempDirectory.make(prefix: "adopt-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let returned = try ExecutorReturnedFolder.make(root: root, clumping: .bbtools)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let seqkitPIDFile = root.appendingPathComponent("seqkit.pid")
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try SIGTERMPinSupport.writeExecutable(
            """
            #!/bin/sh
            case "$*" in
              *version*) echo "v2.10.0"; exit 0 ;;
            esac
            echo $$ > '\(seqkitPIDFile.path)'
            exec sleep 120
            """,
            at: condaRoot.appendingPathComponent("envs/seqkit/bin/seqkit")
        )
        let cli = try CLISIGTERMHarness.launchCLI(
            ["import", "fastq", returned.folder.path, "--adopt", "--project", project.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard await CLISIGTERMHarness.waitForProcessID(in: seqkitPIDFile) != nil else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The adopt never started seqkit head.\(stop.diagnostics)")
        }
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertFalse(SIGTERMPinSupport.relativePaths(under: imports).isEmpty, "the adopt is staging its bundle when the signal arrives")

        let stop = await CLISIGTERMHarness.cancel(cli)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(
            SIGTERMPinSupport.relativePaths(under: imports), [],
            "a cancelled adopt leaves no staging bundle and no bundle.\(stop.diagnostics)"
        )
        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertTrue(stop.standardOutput.contains("Adopt cancelled"), "the failed line says the adopt was cancelled: \(stop.standardOutput)")
    }
}
