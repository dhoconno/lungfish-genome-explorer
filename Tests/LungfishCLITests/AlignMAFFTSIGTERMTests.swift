// AlignMAFFTSIGTERMTests.swift - How a SIGTERM ends `align mafft` (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Align with MAFFT row's Cancel sends SIGTERM to `lungfish-cli align mafft`. Until lane S61 the
// command did not turn the signal into a cancel, so the CLI-wide handler stopped MAFFT and the command
// died by signal 15 with no record of the run. The built CLI finds a
// stand-in micromamba in a conda root of its own, with a home and a storage root of its own, so the
// run touches nothing real. Its MAFFT call records its process ID and waits.

import Darwin
import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class AlignMAFFTSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "align-mafft-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// One started `align mafft` and the places a test reads afterwards.
    private struct Started {
        let cli: CLISIGTERMHarness.Run
        let project: URL
        let output: URL
        let mafftPIDFile: URL
    }

    /// Starts `align mafft` on three sequences against a stand-in micromamba whose `run ... mafft`
    /// call records its process ID and waits, and which answers a version probe and does nothing for
    /// any other call.
    private func startAlignment() throws -> Started {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let mafftPIDFile = root.appendingPathComponent("mafft.pid")
        try SIGTERMPinSupport.writeExecutable(
            """
            #!/bin/sh
            for argument in "$@"; do
              case "$argument" in
                --version|-V) echo "2.31-r1302"; exit 0 ;;
              esac
            done
            case " $* " in
              " run "*" mafft "*)
                echo $$ > '\(mafftPIDFile.path)'
                exec /bin/sleep 300 ;;
            esac
            exit 0
            """,
            at: condaRoot.appendingPathComponent("bin/micromamba")
        )
        try SIGTERMPinSupport.writeExecutable("#!/bin/sh\nexit 0\n", at: condaRoot.appendingPathComponent("envs/mafft/bin/mafft"))
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("sequences.fasta")
        try ">a\nACGTACGTACGTACGT\n>b\nACGTACGAACGTACGT\n>c\nACGTTCGTACGTACGA\n".write(to: input, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "align", "mafft", input.path,
                "--project", project.path,
                "--output", output.path,
                "--threads", "1",
                "--format", "json",
            ],
            environment: [
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        return Started(cli: cli, project: project, output: output, mafftPIDFile: mafftPIDFile)
    }

    /// Lane S61 M2 flipped the M1 pin, which read a death by signal 15 and no record. A SIGTERM now
    /// cancels the run. The command exits 125 inside the grace, records the run as cancelled beside
    /// the bundle it did not write, ends the stream with one `failed` line, removes its workspace and
    /// leaves no process behind.
    func testSIGTERMCancelsAlignMAFFTAndRecordsItCancelled() async throws {
        let started = try startAlignment()
        defer { started.cli.stop() }
        guard await CLISIGTERMHarness.waitForProcessID(in: started.mafftPIDFile) != nil else {
            let stop = await CLISIGTERMHarness.cancel(started.cli, timeout: .seconds(5))
            return XCTFail("The command never started MAFFT.\(stop.diagnostics)")
        }
        let record = URL(fileURLWithPath: started.output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(started.cli) {
            try SIGTERMPinSupport.recordStatus(at: record)
        }

        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertEqual(
            SIGTERMPinSupport.paths(under: started.project, startingWith: "mafft-"), [],
            "the workspace is gone: \(SIGTERMPinSupport.relativePaths(under: started.project))"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.output.path), "no alignment bundle was written")
    }
}
