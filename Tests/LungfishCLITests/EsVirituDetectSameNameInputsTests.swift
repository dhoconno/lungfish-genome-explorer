// EsVirituDetectSameNameInputsTests.swift - lungfish-cli esviritu detect without --batch hands EsViritu each input as itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishTestSupport

/// ESV-STAGING-SYMBOL-NAMES (BIO-PROBES-B item 1). Without `--batch` the command makes one sample of all its inputs, so two
/// files named `reads.fastq` in two run folders reach the pipeline as two inputs of one file name, and the space in a run
/// folder's name makes the pipeline stage its inputs as links. A stand-in EsViritu keeps a copy of each file it is handed
/// after `-r`, copied through the path it was given, so the copy shows which file the tool would have read.
final class EsVirituDetectSameNameInputsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-same-name-inputs")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// `--paired`, the smallest failing input: mate 1 is run A's file and mate 2 is run B's file.
    func testTwoPairedMatesOfOneFileNameInTwoRunFoldersAreEachHandedToTheTool() async throws {
        let run = try await detect(["--paired"])
        XCTAssertEqual(run.formatSeen, "paired")
        XCTAssertEqual(run.filesSeen, [["run-A-read"], ["run-B-read"]], "each mate is read from its own run folder")
    }

    /// With the layout left at `auto`, two inputs run unpaired, and each file is read once.
    func testTwoUnpairedFilesOfOneFileNameInTwoRunFoldersAreEachReadOnce() async throws {
        let run = try await detect([])
        XCTAssertEqual(run.formatSeen, "unpaired")
        XCTAssertEqual(run.filesSeen, [["run-A-read"], ["run-B-read"]], "each file is read once, and neither is read twice")
    }

    // MARK: - Helpers

    private struct Run {
        /// The record names of each file EsViritu was handed, in argument order.
        let filesSeen: [[String]]
        let formatSeen: String
    }

    /// Runs `lungfish-cli esviritu detect --input <A> --input <B> --sample S1` with a stand-in EsViritu, `extra` added to the
    /// arguments, on two files named `reads.fastq` of one read each, in the folders `Run A` and `Run B`.
    private func detect(_ extra: [String]) async throws -> Run {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool", isDirectory: true))
        let first = try reads(folder: "Run A", readName: "run-A-read")
        let second = try reads(folder: "Run B", readName: "run-B-read")
        let output = root.appendingPathComponent("Analyses/esviritu/S1", isDirectory: true)
        let parsed = try LungfishCLI.parseAsRoot(
            ["esviritu", "detect", "--input", first.path, "--input", second.path, "--sample", "S1",
             "--db", esviritu.databaseURL.path, "--output", output.path, "--threads", "2", "--quiet"] + extra
        )
        let command = try XCTUnwrap(parsed as? EsVirituCommand.DetectSubcommand)
        let installed = esviritu.databaseURL
        try await command.execute(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { installed }
        )
        return Run(
            filesSeen: try esviritu.inputsSeen().map(BundleShapeFixtures.readNames(in:)),
            formatSeen: esviritu.formatSeen
        )
    }

    private func reads(folder: String, readName: String) throws -> URL {
        let directory = root.appendingPathComponent("inputs/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("reads.fastq")
        try BundleShapeFixtures.fastq([readName]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
