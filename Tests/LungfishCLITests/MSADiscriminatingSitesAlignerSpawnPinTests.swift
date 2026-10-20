// MSADiscriminatingSitesAlignerSpawnPinTests.swift - The MAFFT spawn of the discriminating-sites exclusion aligner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishCLI

/// `MSADiscriminatingSitesExclusionAligner.align` runs the managed MAFFT with `--add` and reads the combined
/// alignment from its standard output (Phase 2.13 lane 13.10 M3 item 2). Stand-in scripts play MAFFT through the
/// `executableOverride` seam, whose default is the managed path. These pins hold at the base, where the spawn was
/// a raw `Process`, and after it runs on `ToolProcess`.
final class MSADiscriminatingSitesAlignerSpawnPinTests: XCTestCase {
    private var root: URL!
    private var target: URL!
    private var exclusions: URL!
    private var count = 0

    private let targetText = ">t1 first\nACGT--\n>t2\nACGTAA\n"
    private let combinedText = ">t1\nACGT--\n>t2\nACGTAA\n>e1\nACGTAC\n"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-mafft-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        target = root.appendingPathComponent("target.aligned.fasta")
        exclusions = root.appendingPathComponent("exclusions.fasta")
        try Data(targetText.utf8).write(to: target)
        try Data(">e1 note\nACGTAC\n".utf8).write(to: exclusions)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A script at `<root>/envs/mafft-N/bin/mafft`, the layout the aligner reads `MAFFT_BINARIES` from.
    private func standIn(_ body: String) throws -> URL {
        count += 1
        let bin = root.appendingPathComponent("envs/mafft-\(count)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent("mafft")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testTheSpawnGetsTheExactArgvTheEnvironmentAndAScratchFolder() throws {
        let log = root.appendingPathComponent("spawn.log")
        let mafft = try standIn(#"""
        {
          for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
          printf 'binaries=%s\n' "$MAFFT_BINARIES"
          printf 'home=%s\n' "$HOME"
          printf 'cwd=%s\n' "$(pwd -P)"
        } > '\#(log.path)'
        printf '%s' '\#(combinedText)'
        """#)
        let aligned = try MSADiscriminatingSitesExclusionAligner.align(
            targetAlignmentURL: target, exclusionsURL: exclusions, executableOverride: mafft
        )
        XCTAssertEqual(aligned.rows.map { $0.name }, ["e1"])
        XCTAssertEqual(aligned.rows.map { $0.sequence }, ["ACGTAC"])
        XCTAssertEqual(aligned.resolvedExclusionFASTAURL, exclusions)
        let arguments = ["--quiet", "--keeplength", "--add", exclusions.path, target.path]
        XCTAssertEqual(aligned.command, ([mafft.path] + arguments).joined(separator: " "))

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 8, "\(lines)")
        XCTAssertEqual(Array(lines.prefix(5)), arguments.map { "arg=\($0)" })
        XCTAssertEqual(lines[5], "binaries=" + root.appendingPathComponent("envs/mafft-1/libexec/mafft").path)
        XCTAssertEqual(lines[6], "home=" + (ProcessInfo.processInfo.environment["HOME"] ?? ""))
        let scratch = String(lines[7].dropFirst("cwd=".count))
        XCTAssertTrue(
            URL(fileURLWithPath: scratch).lastPathComponent.hasPrefix("lungfish-discriminating-sites-"), scratch
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch), "the scratch folder is removed")
    }

    func testACombinedAlignmentOfThreeHundredKilobytesIsReadWhole() throws {
        let width = 150_000
        let wide = root.appendingPathComponent("wide.target.fasta")
        let targetRow = String(repeating: "A", count: width)
        let exclusionRow = String(repeating: "C", count: width)
        try Data(">t1\n\(targetRow)\n".utf8).write(to: wide)
        let combined = root.appendingPathComponent("combined.txt")
        try Data(">t1\n\(targetRow)\n>e1\n\(exclusionRow)\n".utf8).write(to: combined)
        let mafft = try standIn("cat '\(combined.path)'")
        let aligned = try MSADiscriminatingSitesExclusionAligner.align(
            targetAlignmentURL: wide, exclusionsURL: exclusions, executableOverride: mafft
        )
        XCTAssertEqual(aligned.rows.count, 1)
        XCTAssertEqual(aligned.rows.first?.sequence, exclusionRow)
    }

    func testANonzeroExitAndAKillBySignalThrowFailedWithTheStatusAndStderr() throws {
        let failing = try standIn("printf 'boom: bad input\\n' >&2\nexit 3")
        do {
            _ = try MSADiscriminatingSitesExclusionAligner.align(
                targetAlignmentURL: target, exclusionsURL: exclusions, executableOverride: failing
            )
            XCTFail("a failing MAFFT was accepted")
        } catch let failure as DiscriminatingSitesExclusionAligner.Failure {
            XCTAssertEqual(failure, .failed(3, "boom: bad input\n"))
        }
        let killed = try standIn("printf 'killed\\n' >&2\nkill -KILL $$")
        do {
            _ = try MSADiscriminatingSitesExclusionAligner.align(
                targetAlignmentURL: target, exclusionsURL: exclusions, executableOverride: killed
            )
            XCTFail("a killed MAFFT was accepted")
        } catch let failure as DiscriminatingSitesExclusionAligner.Failure {
            XCTAssertEqual(failure, .failed(9, "killed\n"))
        }
    }

    func testAnExecutableThatIsNotThereIsReportedMissingBeforeAnySpawn() throws {
        let missing = root.appendingPathComponent("envs/none/bin/mafft")
        do {
            _ = try MSADiscriminatingSitesExclusionAligner.align(
                targetAlignmentURL: target, exclusionsURL: exclusions, executableOverride: missing
            )
            XCTFail("a missing MAFFT was accepted")
        } catch let failure as DiscriminatingSitesExclusionAligner.Failure {
            XCTAssertEqual(failure, .executableMissing(missing.path))
        }
    }
}
