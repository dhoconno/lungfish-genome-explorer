// PrimerTrimSIGTERMTests.swift - How a SIGTERM ends `bam primer-trim` (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Primer Trim row's Cancel sends SIGTERM to `lungfish-cli bam primer-trim`. Until lane S61 the
// command did not turn the signal into a cancel, so the CLI-wide handler stopped its tools and the
// command died by signal 15 with no record of the run. The built CLI
// runs against a stand-in ivar that writes its process ID and waits, so the command is known to be at
// work when the signal arrives. No real tool and no network are needed.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest

final class PrimerTrimSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "primer-trim-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// One started `bam primer-trim` and the places a test reads afterwards.
    private struct Started {
        let cli: CLISIGTERMHarness.Run
        let bundle: URL
        let ivarPIDFile: URL
        /// The `TMPDIR` of the CLI, where the command stages the trimmed BAM.
        let scratch: URL
    }

    /// Starts `bam primer-trim` on a bundle whose source track is a small stand-in file, against a
    /// stand-in ivar that answers a version probe and otherwise records its process ID and waits. The
    /// scheme names its reference, so the command reads no BAM header before ivar runs.
    private func startPrimerTrim() throws -> Started {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let ivarPIDFile = root.appendingPathComponent("ivar.pid")
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try SIGTERMPinSupport.writeExecutable(
            """
            #!/bin/sh
            case "$*" in
              *version*) echo "iVar version 1.4.4"; exit 0 ;;
            esac
            echo $$ > '\(ivarPIDFile.path)'
            exec sleep 120
            """,
            at: condaRoot.appendingPathComponent("envs/ivar/bin/ivar")
        )
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let scheme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LungfishCLITests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("LungfishWorkflowTests/Resources/primerschemes/mt192765-integration.lungfishprimers")
        guard FileManager.default.fileExists(atPath: scheme.path) else {
            throw XCTSkip("mt192765-integration scheme missing at \(scheme.path)")
        }
        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "bam", "primer-trim",
                "--bundle", fixture.bundleURL.path,
                "--alignment-track", DerivedAlignmentTrackFixture.sourceTrackID,
                "--scheme", scheme.path,
                "--name", "Sample 1 Primer Trim",
                "--target-reference", "MT192765.1",
                "--format", "json",
                "--no-progress",
            ],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path, "TMPDIR": scratch.path + "/"],
            workingDirectory: root,
            testClass: Self.self
        )
        return Started(cli: cli, bundle: fixture.bundleURL, ivarPIDFile: ivarPIDFile, scratch: scratch)
    }

    /// Lane S61 M2 flipped the M1 pin, which read a death by signal 15 and no record. A SIGTERM now
    /// cancels the run. The command exits 125 inside the grace, records the run as cancelled in the
    /// bundle's `provenance/cancelled` folder, ends the stream with one `failed` line, removes its
    /// staging folder and leaves no process and no track behind.
    func testSIGTERMCancelsPrimerTrimAndRecordsItCancelled() async throws {
        let started = try startPrimerTrim()
        defer { started.cli.stop() }
        guard await CLISIGTERMHarness.waitForProcessID(in: started.ivarPIDFile) != nil else {
            let stop = await CLISIGTERMHarness.cancel(started.cli, timeout: .seconds(5))
            return XCTFail("The command never started ivar.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(started.cli) {
            try SIGTERMPinSupport.cancelledRecordStatus(inBundle: started.bundle)
        }

        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertTrue(stop.standardOutput.contains("cancelled"), "the failed line says the run was cancelled")
        XCTAssertEqual(
            SIGTERMPinSupport.paths(under: started.scratch, startingWith: "primer-trim-"), [],
            "the staging folder is gone"
        )
        XCTAssertEqual(try BundleManifest.load(from: started.bundle).alignments.count, 2, "the bundle was not changed")
    }
}
