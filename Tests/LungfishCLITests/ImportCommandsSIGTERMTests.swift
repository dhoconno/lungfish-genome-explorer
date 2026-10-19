// ImportCommandsSIGTERMTests.swift - A SIGTERM cancels the import commands of the two import runners
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7 (SWIFT SC4). The app's Cancel sends SIGTERM to the command and
// gives it `operationGrace`. `import msa`, `import tree`, `import geneious` and `import
// application-export` turn the signal into a cancel of the import, record the run as cancelled in the
// project, tell the row with a `failed` event, exit 125 and leave no process behind. These cases were
// pins at the base (`ImportRunnerCommandsSIGTERMPinTests`, commit 7e6fad694), where each command ended
// without exit 125 and without a record.
//
// The two bundle imports run one synchronous importer, so a large input holds them at it for seconds
// (the importer cannot be interrupted, and the command exits 125 without waiting for it). The two
// collection imports import the reference of an export through bgzip, so a stand-in bgzip that writes
// its process ID and sleeps holds them. The application-export case cancels with every core busy. No
// real tool and no network are needed. `ImportCancellationTests` covers the wait-free cancel of a stuck
// importer on its own.

import Darwin
import Foundation
import os
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ImportCommandsSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-commands-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - import msa and import tree

    func testImportMSATurnsSIGTERMIntoACancelAndPublishesNothing() async throws {
        let held = try await startBundleImportOnALargeInput(kind: "msa", destinationFolder: "Multiple Sequence Alignments")
        defer { held.release() }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(held.run, record: { Self.recordStatus(in: held.project) })
        try Self.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(Self.bundles(in: held.project, folder: "Multiple Sequence Alignments"), [], "a cancelled import publishes no bundle")
    }

    func testImportTreeTurnsSIGTERMIntoACancelAndPublishesNothing() async throws {
        let held = try await startBundleImportOnALargeInput(kind: "tree", destinationFolder: "Phylogenetic Trees")
        defer { held.release() }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(held.run, record: { Self.recordStatus(in: held.project) })
        try Self.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(Self.bundles(in: held.project, folder: "Phylogenetic Trees"), [], "a cancelled import publishes no bundle")
    }

    // MARK: - import geneious and import application-export

    func testImportGeneiousTurnsSIGTERMIntoACancelAndLeavesNoProcess() async throws {
        let (run, project, bgzipPID) = try await startCollectionImport(["import", "geneious"])
        defer { run.stop() }
        XCTAssertNotNil(bgzipPID, "the command never reached bgzip")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: { Self.recordStatus(in: project) })
        try Self.assertCancelledEvents(stop.standardOutput)
    }

    /// The same cancel with every core busy, which the grace must still cover.
    func testImportApplicationExportTurnsSIGTERMIntoACancelWithEveryCoreBusy() async throws {
        let (run, project, bgzipPID) = try await startCollectionImport(["import", "application-export", "clc-workbench"])
        defer { run.stop() }
        XCTAssertNotNil(bgzipPID, "the command never reached bgzip")
        let burners = try CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { burners.forEach { $0.stop() } }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: { Self.recordStatus(in: project) })
        try Self.assertCancelledEvents(stop.standardOutput)
    }

    // MARK: - import bam

    /// The same cancel for the attach of an alignment to a bundle, held at samtools by a stand-in that writes its
    /// process ID and sleeps. The cancel removes what the run added to the bundle and leaves no process.
    func testImportBAMTurnsSIGTERMIntoACancelAndLeavesNothingInTheBundle() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundle)
        let input = root.appendingPathComponent("sample.bam")
        try Data([0x1f, 0x8b]).write(to: input)
        let pidFile = root.appendingPathComponent("samtools.pid")
        let condaRoot = try Self.samtoolsHoldingCondaRoot(in: root, pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            ["import", "bam", input.path, "--output-dir", bundle.path, "--name", "sample.bam", "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let pid = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        XCTAssertNotNil(pid, "the command never reached samtools")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: { Self.recordStatus(in: project) })
        try Self.assertCancelledEvents(stop.standardOutput)
        let alignments = bundle.appendingPathComponent("alignments", isDirectory: true)
        XCTAssertEqual(
            ((try? FileManager.default.contentsOfDirectory(atPath: alignments.path)) ?? []).sorted(), [],
            "a cancelled import leaves nothing in the bundle's alignments folder"
        )
        XCTAssertEqual(try BundleManifest.load(from: bundle).alignments.count, 0, "and no track in its manifest")
    }

    // MARK: - What a cancelled import leaves

    /// The status of the run record the command wrote in the project, nil when there is none.
    static func recordStatus(in project: URL) -> String? {
        ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue
    }

    /// The last line is the `failed` event that carries the cancel words, after the start line.
    static func assertCancelledEvents(
        _ output: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.contains("import via lungfish-cli") == true, "the row's first words. \(lines)", file: file, line: line)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)", file: file, line: line
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)", file: file, line: line)
        XCTAssertEqual(last["error"] as? String, "Import cancelled. Nothing was published.", file: file, line: line)
    }

    /// The bundles in the project's destination folder.
    static func bundles(in project: URL, folder: String) -> [String] {
        let destination = project.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }

    // MARK: - Holding a command at work

    /// A bundle import held at its importer, and what releases it.
    private struct HeldBundleImport {
        let run: CLISIGTERMHarness.Run
        let project: URL

        func release() {
            run.stop()
        }
    }

    /// The input of a bundle import that takes the importer seconds to parse in a debug build, about
    /// 5 s for the alignment and 10 s for the tree, so a SIGTERM that follows the command's first write
    /// by a poll interval meets the importer at work. A FIFO cannot hold it, since Foundation refuses to
    /// read one with a permission error at once.
    private static func writeLargeInput(kind: String, to url: URL) throws {
        if kind == "msa" {
            let columns = Array("ACGT-")
            var text = ""
            for row in 0..<1_200 {
                text += ">row\(row)\n"
                text += String((0..<2_000).map { columns[($0 &* 7 &+ row) % columns.count] })
                text += "\n"
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            var tip = 0
            func subtree(_ tips: Int) -> String {
                guard tips > 1 else {
                    tip += 1
                    return "t\(tip):0.1"
                }
                let left = tips / 2
                return "(\(subtree(left)),\(subtree(tips - left))):0.1"
            }
            try (subtree(20_000) + ";\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Starts `import <kind>` on a large input and waits until the command has made its destination
    /// folder, which it does after it scoped the cancel and before the importer runs.
    private func startBundleImportOnALargeInput(kind: String, destinationFolder: String) async throws -> HeldBundleImport {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = root.appendingPathComponent(kind == "msa" ? "input.fasta" : "input.nwk")
        try Self.writeLargeInput(kind: kind, to: input)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", kind, input.path, "--project", project.path, "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        // The command scopes the cancel before it makes its destination folder, so SIGTERM from here on is a
        // cancel, and the importer is then in or just before its open of the FIFO, which blocks.
        let reached = await CLISIGTERMHarness.waitForFile(project.appendingPathComponent(destinationFolder, isDirectory: true))
        if !reached {
            run.stop()
            XCTFail("the \(kind) command never made its destination folder")
        }
        return HeldBundleImport(run: run, project: project)
    }

    /// Starts a collection import of a folder export that holds one reference FASTA, against a conda
    /// root whose bgzip writes its process ID and sleeps, and waits for that ID.
    private func startCollectionImport(
        _ command: [String]
    ) async throws -> (run: CLISIGTERMHarness.Run, project: URL, bgzipPID: Int32?) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let export = root.appendingPathComponent("Export", isDirectory: true)
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

    /// A conda root whose samtools answers a version probe and sleeps on any other call, after it wrote `$$`.
    static func samtoolsHoldingCondaRoot(in root: URL, pidFile: URL) throws -> URL {
        let condaRoot = root.appendingPathComponent("conda-samtools", isDirectory: true)
        let samtools = """
        #!/bin/sh
        case "$*" in
          *version*) echo "samtools 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let binary = condaRoot.appendingPathComponent("envs/samtools/bin/samtools")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try samtools.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return condaRoot
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
