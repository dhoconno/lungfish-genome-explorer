// SystemTempScratchCLIPinTests.swift - CLI scratch outside a project's .tmp, and what removes it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S32 M1 (2.10 P1 and P3, A30 M2 review fix 2, 2.11 S8). `TMPDIR` points the system
// temp folder at a folder under a TestTempDirectory root, so no pin touches the real one.

import ArgumentParser
import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class SystemTempScratchCLIPinTests: XCTestCase {
    private var root: URL!
    /// Stands in for the system temp folder.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "system-temp-scratch-cli-pin").resolvingSymlinksInPath()
        systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(root)
    }

    /// Cancels the run's task in the Docker wait, so the run goes on to stage and stops at the split of
    /// interleaved reads, and launches no Nextflow.
    private final class CancellingRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        func waitForDocker(profile: String, progress: (@Sendable (Double, String) -> Void)?) async throws {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            XCTFail("a cancelled run launches no Nextflow")
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    /// W6 and A30 M2 fix 2. A project whose path holds a space puts the work tree and the staged inputs
    /// in `nfcore-work-` and `nfcore-inputs-` folders in the system temp folder, and a cancel keeps them.
    /// The launch scratch stays in the project `.tmp` with its marker, where the project sweep finds it.
    func testACancelledViralReconRunWhoseScratchHoldsASpaceLeavesTwoFoldersInTheSystemTempFolder() async throws {
        let project = root.appendingPathComponent("Cancel Space.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let reads = project.appendingPathComponent("reads.fastq")
        try InterleavedFASTQFixture.write(pairCount: 4, naming: .casava, to: reads)
        let samplesheet = project.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,\(reads.path),\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundle = analyses.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = analyses.appendingPathComponent("viralrecon-results", isDirectory: true)

        do {
            try await RunSubcommand.parse([
                "nf-core/viralrecon",
                "--executor", "docker",
                "--input", samplesheet.path,
                "--results-dir", results.path,
                "--expected-output", results.path,
                "--bundle-path", bundle.path,
                "--version", "3.0.0",
                "--param", "platform=illumina",
                "--param", "protocol=amplicon",
                "--quiet",
            ]).run(nfCoreRunner: CancellingRunner())
            XCTFail("a cancelled run ended without an error")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, CLIExitCode.cancelled.rawValue, "a cancel exits 125")
        }

        let left = Self.names(in: systemTemp)
        for prefix in ["nfcore-work-", "nfcore-inputs-"] {
            let matches = left.filter { $0.hasPrefix(prefix) }
            XCTAssertEqual(matches.count, 1, "a cancel keeps the \(prefix) folder, saw \(left.sorted())")
            for name in matches {
                XCTAssertFalse(
                    Self.holdsMarker(systemTemp.appendingPathComponent(name, isDirectory: true)),
                    "W1, \(name) carries no marker naming its creator"
                )
            }
        }
        let tmp = ProjectTempDirectory.tempRoot(for: project)
        let launch = Self.names(in: tmp).filter { $0.hasPrefix("nfcore-run-") }
        XCTAssertEqual(launch.count, 1, "the launch scratch stays in the project .tmp")
        for name in launch {
            XCTAssertTrue(
                Self.holdsMarker(tmp.appendingPathComponent(name, isDirectory: true)),
                "project scratch carries the marker the project sweep reads"
            )
        }
    }

    /// W11 and SW7 (a). An in-place ingest of an input outside a project stages in a hidden
    /// `.lungfish-ingest-<UUID>` folder beside its input, which no sweep covers.
    func testAnIngestOfAnInputOutsideAProjectStagesBesideItsInput() throws {
        let folder = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: input, atomically: true, encoding: .utf8)

        let staging = try FastqIngestRun.makeStagingFolder(for: input)

        XCTAssertEqual(staging.deletingLastPathComponent().resolvingSymlinksInPath().path, folder.path)
        XCTAssertTrue(staging.lastPathComponent.hasPrefix(".lungfish-ingest-"), staging.lastPathComponent)
        XCTAssertTrue(Self.names(in: systemTemp).isEmpty, "nothing stages in the system temp folder")
        XCTAssertFalse(Self.holdsMarker(staging), "the folder beside the input carries no marker")
    }

    /// An input in a project stages under the project `.tmp` with the marker the project sweep reads.
    func testAnIngestOfAnInputInAProjectStagesUnderTheProjectTmp() throws {
        let project = root.appendingPathComponent("Ingest.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let input = imports.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: input, atomically: true, encoding: .utf8)

        let staging = try FastqIngestRun.makeStagingFolder(for: input)

        XCTAssertEqual(
            staging.deletingLastPathComponent().resolvingSymlinksInPath().path,
            ProjectTempDirectory.tempRoot(for: project).path
        )
        XCTAssertTrue(staging.lastPathComponent.hasPrefix("lungfish-ingest-"), staging.lastPathComponent)
        XCTAssertTrue(Self.holdsMarker(staging))
    }

    // MARK: - Helpers

    private static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private static func holdsMarker(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(OwnedWorkDirectoryMarker.fileName).path)
    }
}
