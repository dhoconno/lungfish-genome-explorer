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
import LungfishWorkflow
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

    /// Lane S61 M2 flipped the M1 pin, which read a death by signal 15, IQ-TREE left running and a
    /// staging folder left behind. A SIGTERM now cancels the run. IQ-TREE stops with the command,
    /// which exits 125 inside the grace, records the run as cancelled beside the output it did not
    /// write, ends the stream with one `failed` line and removes its staging folder.
    func testSIGTERMCancelsTreeInferenceStopsIQTreeAndRecordsItCancelled() async throws {
        let started = try startInference()
        defer { started.cli.stop() }
        guard let iqtreePID = await CLISIGTERMHarness.waitForProcessID(in: started.iqtreePIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(started.cli, timeout: .seconds(5))
            return XCTFail("The command never started IQ-TREE.\(stop.diagnostics)")
        }
        let record = URL(fileURLWithPath: started.output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(started.cli) {
            try SIGTERMPinSupport.recordStatus(at: record)
        }

        XCTAssertTrue(stop.tree.contains(iqtreePID), "IQ-TREE belongs to the CLI's tree \(stop.tree)")
        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertEqual(
            SIGTERMPinSupport.paths(under: started.scratch, startingWith: "lungfish-tree-iqtree-"), [],
            "the staging folder is gone: \(SIGTERMPinSupport.relativePaths(under: started.scratch))"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.output.path), "no tree bundle was written")
    }
}
