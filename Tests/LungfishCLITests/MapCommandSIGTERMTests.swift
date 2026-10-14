// MapCommandSIGTERMTests.swift - SIGTERM cancels `map`, records the run cancelled and stops the mapper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// Phase 2.10 lane A46 M1, decisions P2 and C5. The Map Reads route's cancel sends SIGTERM to
/// `lungfish-cli map` and gives it `operationGrace`. The command turns the signal into a cancel,
/// so the mapper's tree stops, the run record of the chosen `--output-dir` reads cancelled, and
/// the command exits 125 inside the grace. Before, the command died of the signal and left its
/// record claiming a run that no longer existed.
///
/// The CLI finds a stand-in micromamba in a conda root of its own, with a home and a storage root
/// of its own, so the run touches nothing real. Its minimap2 call records its pid and waits.
final class MapCommandSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "map-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSIGTERMCancelsAMappingRunAndRecordsItCancelled() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let mapperPIDFile = root.appendingPathComponent("mapper.pid")
        try Self.installStandInToolchain(in: condaRoot, mapperPIDFile: mapperPIDFile)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Analyses", isDirectory: true),
            withIntermediateDirectories: true
        )
        let output = project.appendingPathComponent("Analyses/minimap2-sigterm", isDirectory: true)
        let reads = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let reference = root.appendingPathComponent("reference.fa")
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 20))\n".write(to: reference, atomically: true, encoding: .utf8)

        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "map", reads.path,
                "--reference", reference.path,
                "--mapper", "minimap2",
                "--project", project.path,
                "--output-dir", output.path,
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
        defer { cli.stop() }

        // The mapper runs, so the command is at work.
        guard let mapperPID = await CLISIGTERMHarness.waitForProcessID(in: mapperPIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never started the mapper.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            AnalysisRunRecord.load(from: output)?.outcome?.rawValue
        }
        XCTAssertTrue(stop.tree.contains(mapperPID), "the mapper belongs to the CLI's tree \(stop.tree)")
        XCTAssertTrue(stop.standardError.contains("Mapping cancelled"), stop.diagnostics)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(output), "a cancelled run stays out of the sidebar")
    }

    /// A conda root whose micromamba answers version probes, records the pid of its minimap2 run
    /// and waits there, and does nothing for any other call. The minimap2 and samtools files exist
    /// so the command's tool checks find them. The pid file's path is written into the script,
    /// since a managed tool runs with an environment of its own.
    private static func installStandInToolchain(in condaRoot: URL, mapperPIDFile: URL) throws {
        let micromamba = condaRoot.appendingPathComponent("bin/micromamba")
        try write(
            """
            #!/bin/sh
            for argument in "$@"; do
              case "$argument" in
                --version|-V) echo "2.31-r1302"; exit 0 ;;
              esac
            done
            case " $* " in
              " run "*" minimap2 "*)
                echo $$ > '\(mapperPIDFile.path)'
                exec /bin/sleep 300 ;;
            esac
            exit 0
            """,
            executableAt: micromamba
        )
        for (environment, executable) in [("minimap2", "minimap2"), ("samtools", "samtools")] {
            try write("#!/bin/sh\nexit 0\n", executableAt: condaRoot.appendingPathComponent("envs/\(environment)/bin/\(executable)"))
        }
    }

    private static func write(_ script: String, executableAt url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
