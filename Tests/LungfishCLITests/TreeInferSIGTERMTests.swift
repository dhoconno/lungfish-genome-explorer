// TreeInferSIGTERMTests.swift - How a SIGTERM ends `tree infer iqtree` (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Tree Inference row's Cancel sends SIGTERM to `lungfish-cli tree infer iqtree`. Until lane S61
// the command ran IQ-TREE on a bare `Process` and did not turn the signal into a cancel, so it died by
// signal 15 with its staging folder in place, no record of the run and IQ-TREE still running. The
// built CLI runs against a stand-in IQ-TREE that writes its process ID and waits, so the command is
// known to be at work when the signal arrives. No real tool is needed.

import Darwin
import Foundation
import LungfishTestSupport
import XCTest

final class TreeInferSIGTERMTests: XCTestCase {
    private var project: IQTreeTestProject!

    override func setUpWithError() throws {
        project = try IQTreeTestProject.make(fasta: fourRowFASTA)
    }

    override func tearDownWithError() throws {
        project.remove()
    }

    /// One started `tree infer iqtree` and the places a test reads afterwards.
    private struct Started {
        let cli: CLISIGTERMHarness.Run
        let output: URL
        let iqtreePIDFile: URL
        /// The folder the command stages IQ-TREE's files in, `<project>/.tmp`.
        let scratch: URL
    }

    /// Starts `tree infer iqtree` against a stand-in IQ-TREE that answers `--version` and otherwise
    /// records its process ID and waits.
    private func startInference() throws -> Started {
        let iqtreePIDFile = project.directory.appendingPathComponent("iqtree.pid")
        let standIn = project.directory.appendingPathComponent("iqtree3-waiting")
        try SIGTERMPinSupport.writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo "IQ-TREE multicore version 3.1.3"
              exit 0
            fi
            echo $$ > '\(iqtreePIDFile.path)'
            exec sleep 120
            """,
            at: standIn
        )
        let output = project.outputURL("Cancelled")
        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "tree", "infer", "iqtree", project.msaBundleURL.path,
                "--project", project.projectURL.path,
                "--output", output.path,
                "--iqtree-path", standIn.path,
                "--format", "json",
            ],
            workingDirectory: project.directory,
            testClass: Self.self
        )
        return Started(
            cli: cli,
            output: output,
            iqtreePIDFile: iqtreePIDFile,
            scratch: project.projectURL.appendingPathComponent(".tmp", isDirectory: true)
        )
    }

    /// Pin at the base (lane S61 M1). A SIGTERM ends the command by signal 15 with no `cancelled`
    /// record. IQ-TREE keeps running, since the CLI-wide handler stops only the tools it registered,
    /// and the staging folder stays under `<project>/.tmp`.
    func testSIGTERMKillsTreeInferenceAtOnceAndLeavesNoRecordToday() async throws {
        let started = try startInference()
        defer { started.cli.stop() }
        guard let iqtreePID = await CLISIGTERMHarness.waitForProcessID(in: started.iqtreePIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(started.cli, timeout: .seconds(5))
            return XCTFail("The command never started IQ-TREE.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.cancel(started.cli, timeout: .seconds(5))

        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), "the command dies of the signal.\(stop.diagnostics)")
        XCTAssertNil(stop.exitStatus, "the command does not exit 125")
        XCTAssertEqual(
            SIGTERMPinSupport.cancelledRecords(under: project.directory), [],
            "the command writes no cancelled record"
        )
        XCTAssertEqual(
            SIGTERMPinSupport.paths(under: started.scratch, startingWith: "lungfish-tree-iqtree-").count, 1,
            "the staging folder stays: \(SIGTERMPinSupport.relativePaths(under: started.scratch))"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.output.path), "no tree bundle was written")
        XCTAssertTrue(stop.tree.contains(iqtreePID), "IQ-TREE belongs to the CLI's tree \(stop.tree)")
        XCTAssertTrue(stop.left.contains(iqtreePID), "IQ-TREE is left running after the CLI died: \(stop.left)")
    }
}
