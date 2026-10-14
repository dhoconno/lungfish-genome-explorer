// AssembleCommandSIGTERMTests.swift - SIGTERM cancels `assemble` and stops the assembler
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// Phase 2.10 lane A46 M2, decisions P2 and C5. The Reassemble route's cancel sends SIGTERM to
/// `lungfish-cli assemble` and gives it `operationGrace`. The command turns the signal into a
/// cancel, so the assembler's tree stops, the run ends with one `failed` line that says
/// `Assembly cancelled`, and the command exits 125 inside the grace. Before, the command died of
/// the signal. `assemble` keeps no run record, so the harness's record check does not apply.
///
/// The CLI finds a stand-in micromamba in a conda root of its own, with a home and a storage root
/// of its own, so the run touches nothing real. Its MEGAHIT call records its pid and waits.
final class AssembleCommandSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSIGTERMCancelsAnAssemblyAndStopsTheAssembler() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let assemblerPIDFile = root.appendingPathComponent("assembler.pid")
        try Self.installStandInToolchain(in: condaRoot, assemblerPIDFile: assemblerPIDFile)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("Assemblies/sigterm", isDirectory: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            [
                "assemble", reads.path,
                "--assembler", "megahit",
                "--read-type", "illumina-short-reads",
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
        defer { cli.stop() }

        // The assembler runs, so the command is at work.
        guard let assemblerPID = await CLISIGTERMHarness.waitForProcessID(in: assemblerPIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never started the assembler.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.cancel(cli)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(stop.tree.contains(assemblerPID), "the assembler belongs to the CLI's tree \(stop.tree)")
        XCTAssertTrue(stop.standardError.contains("Assembly cancelled"), stop.diagnostics)
        let lastEvent = stop.standardOutput.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(lastEvent.contains(#""event":"failed""#) && lastEvent.contains("Assembly cancelled"), stop.diagnostics)
    }

    /// A conda root whose micromamba answers version probes, records the pid of its MEGAHIT run and
    /// waits there, and does nothing for any other call. The pid file's path is written into the
    /// script, since a managed tool runs with an environment of its own.
    private static func installStandInToolchain(in condaRoot: URL, assemblerPIDFile: URL) throws {
        try write(
            """
            #!/bin/sh
            for argument in "$@"; do
              case "$argument" in
                --version|-V) echo "1.2.9"; exit 0 ;;
              esac
            done
            case " $* " in
              " run "*" megahit "*)
                echo $$ > '\(assemblerPIDFile.path)'
                exec /bin/sleep 300 ;;
            esac
            exit 0
            """,
            executableAt: condaRoot.appendingPathComponent("bin/micromamba")
        )
        try write("#!/bin/sh\nexit 0\n", executableAt: condaRoot.appendingPathComponent("envs/megahit/bin/megahit"))
    }

    private static func write(_ script: String, executableAt url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
