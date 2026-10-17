// ImportRunnerCommandsSIGTERMPinTests.swift - Pins what SIGTERM does to the import commands of the two zero-grace runners
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7 (SWIFT SC4). `CLIApplicationExportImportRunner` launches `import
// application-export` and `import geneious`, and `CLINativeBundleImportRunner` launches `import msa` and
// `import tree`. At the base none of the four commands turns SIGTERM into a cancel, so the CLI-wide handler
// of `CLITerminationSignals` stops the tools it started and the CLI ends, usually by signal 15 and, when
// the signal interrupts a blocked read or a tool first, by a failure exit whose `failed` event names a
// validation error and never a cancel. It exits no 125 and writes no `cancelled` record, which is all the
// zero grace of the two runners could have waited for.
// Each case holds the built lungfish-cli at work, sends one SIGTERM through `CLISIGTERMHarness` and asserts
// that end. The S7 commit of this lane flips every case to the converted cancel (exit 125 inside the grace,
// a `cancelled` record, no process left).
//
// The two bundle imports read their input before they write anything, so a FIFO as input holds them
// there. The two collection imports import the reference of an export through bgzip, so a stand-in bgzip
// that writes its process ID and sleeps holds them. No real tool and no network are needed.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class ImportRunnerCommandsSIGTERMPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-runner-sigterm-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - import msa and import tree

    func testImportMSAEndsBySIGTERMWithNoCancelledRecord() async throws {
        let (run, project) = try await startBundleImportOnAFIFO(kind: "msa", destinationFolder: "Multiple Sequence Alignments")
        defer { run.stop() }
        let stop = await CLISIGTERMHarness.cancel(run)
        assertEndsBySIGTERM(stop, project: project)
    }

    func testImportTreeEndsBySIGTERMWithNoCancelledRecord() async throws {
        let (run, project) = try await startBundleImportOnAFIFO(kind: "tree", destinationFolder: "Phylogenetic Trees")
        defer { run.stop() }
        let stop = await CLISIGTERMHarness.cancel(run)
        assertEndsBySIGTERM(stop, project: project)
    }

    // MARK: - import geneious and import application-export

    func testImportGeneiousEndsBySIGTERMWithNoCancelledRecord() async throws {
        let (run, project, bgzipPID) = try await startCollectionImport(["import", "geneious"], sourceName: "Export")
        defer { run.stop() }
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertNotNil(bgzipPID, "the command never reached bgzip. Standard output: \(stop.standardOutput)")
        assertEndsBySIGTERM(stop, project: project)
    }

    func testImportApplicationExportEndsBySIGTERMWithNoCancelledRecord() async throws {
        let (run, project, bgzipPID) = try await startCollectionImport(["import", "application-export", "clc-workbench"], sourceName: "Export")
        defer { run.stop() }
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertNotNil(bgzipPID, "the command never reached bgzip. Standard output: \(stop.standardOutput)")
        assertEndsBySIGTERM(stop, project: project)
    }

    // MARK: - What the base does

    /// The CLI ended, but not by exit 125, no run record exists under the project and nothing it
    /// printed says it was cancelled. It ends by signal 15 when the CLI-wide handler wins, and by a
    /// failure exit when the signal interrupts the importer's blocked read or a tool first, so the
    /// case asserts no more than the three facts the converted command changes.
    private func assertEndsBySIGTERM(
        _ stop: CLISIGTERMHarness.Stop,
        project: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(stop.termination, "the CLI-wide handler ends the CLI.\(stop.diagnostics)", file: file, line: line)
        XCTAssertNotEqual(stop.exitStatus, CLISIGTERMHarness.cancelledExitStatus, "the base converts no SIGTERM.\(stop.diagnostics)", file: file, line: line)
        XCTAssertEqual(Self.runRecords(under: project), [], "the base writes no cancelled record", file: file, line: line)
        XCTAssertFalse(
            stop.standardOutput.lowercased().contains("cancel"),
            "nothing it printed reports a cancel. \(stop.standardOutput)",
            file: file, line: line
        )
    }

    /// Every run record, `.lungfish-provenance.json`, under `folder`, as paths relative to it.
    static func runRecords(under folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        return walker.compactMap { $0 as? String }
            .filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
            .sorted()
    }

    // MARK: - Holding a command at work

    /// Starts `import <kind>` on a FIFO as its input file, so the importer blocks reading it. The
    /// command makes its destination folder just before the read, which is how the case knows it is
    /// at work.
    private func startBundleImportOnAFIFO(
        kind: String,
        destinationFolder: String
    ) async throws -> (run: CLISIGTERMHarness.Run, project: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = root.appendingPathComponent("input.\(kind)")
        guard mkfifo(input.path, 0o600) == 0 else {
            throw XCTSkip("mkfifo failed: errno \(errno)")
        }
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", kind, input.path, "--project", project.path, "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        let reached = await CLISIGTERMHarness.waitForFile(project.appendingPathComponent(destinationFolder, isDirectory: true))
        if !reached {
            run.stop()
            XCTFail("the command never made its destination folder")
        }
        return (run, project)
    }

    /// Starts a collection import of a folder export that holds one reference FASTA, against a conda
    /// root whose bgzip writes its process ID and sleeps, and waits for that ID.
    private func startCollectionImport(
        _ command: [String],
        sourceName: String
    ) async throws -> (run: CLISIGTERMHarness.Run, project: URL, bgzipPID: Int32?) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let export = root.appendingPathComponent(sourceName, isDirectory: true)
        try FileManager.default.createDirectory(at: export.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try ">chr1\nACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT\n"
            .write(to: export.appendingPathComponent("refs/reference.fasta"), atomically: true, encoding: .utf8)
        let pidFile = root.appendingPathComponent("bgzip.pid")
        let condaRoot = try Self.stubCondaRoot(in: root, pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            command + [export.path, "--project", project.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        let pid = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        return (run, project, pid)
    }

    /// A conda root whose bgzip and samtools answer a version probe, and whose bgzip sleeps on any
    /// other call, after it wrote `$$`. The CLI reads the root from `LUNGFISH_CONDA_ROOT`.
    static func stubCondaRoot(in root: URL, pidFile: URL) throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools)] {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }
}
