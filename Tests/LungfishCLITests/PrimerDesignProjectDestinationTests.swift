// PrimerDesignProjectDestinationTests.swift - Where a primers design leaf writes, and what it refuses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M2, row PRIMER-PROJECT. The options `--output`, `--project` and `--name` of the four
// `primers design` leaves, and the destination `--project` picks. A refusal exits 3, names the fix on standard error and
// makes no folder, as docs/contracts/ADDING-AN-OPERATION.md asks of a refusal.

import ArgumentParser
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class PrimerDesignProjectDestinationTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "primer-destination").resolvingSymlinksInPath()
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// One parse of each leaf with its own inputs and the given place words.
    private let parsers: [([String]) throws -> Void] = [
        { _ = try PrimerDesignCommand.Primer3Subcommand.parse(["--fasta-record", "/tmp/a.fasta@0"] + $0) },
        { _ = try PrimerDesignCommand.PrimalScheme3Subcommand.parse(["--msa", "/tmp/a.fasta"] + $0) },
        { _ = try OlivarDesignCommand.parse(["--msa", "/tmp/a.fasta"] + $0) },
        { _ = try VarVAMPDesignCommand.parse(["--msa", "/tmp/a.fasta"] + $0) },
    ]

    func testExactlyOneOfOutputAndProjectIsRequiredOnEveryLeaf() {
        for (index, parse) in parsers.enumerated() {
            XCTAssertNoThrow(try parse(["--output", "/tmp/o.lungfishprimeranalysis"]), "leaf \(index)")
            XCTAssertNoThrow(try parse(["--project", project.path]), "leaf \(index)")
            XCTAssertThrowsError(try parse([]), "leaf \(index): neither place")
            XCTAssertThrowsError(try parse(["--output", "/tmp/o", "--project", project.path]), "leaf \(index): both places")
        }
    }

    func testTheNameNeedsAProjectAndFollowsTheDialogsRules() {
        for (index, parse) in parsers.enumerated() {
            XCTAssertNoThrow(try parse(["--project", project.path, "--name", "Design 7"]), "leaf \(index)")
            // The recorded command joins the name to its option, so a name that starts with a hyphen is a value.
            XCTAssertNoThrow(try parse(["--project", project.path, "--name=-dash"]), "leaf \(index)")
            XCTAssertThrowsError(try parse(["--output", "/tmp/o", "--name", "Design"]), "leaf \(index): name with --output")
            for bad in ["", "  ", ".", "..", ".hidden", "a/b", "a\\b", "a:b", "tab\there", String(repeating: "x", count: 201)] {
                XCTAssertThrowsError(try parse(["--project", project.path, "--name=\(bad)"]), "leaf \(index): \(bad.debugDescription)")
            }
        }
    }

    func testTheFirstFreeNameInTheProjectIsChosenAndNothingIsMade() throws {
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let first = try PrimerDesignCommand.resolveDestination(output: nil, project: project.path, name: nil)
        XCTAssertEqual(first, analyses.appendingPathComponent("Primer analysis.lungfishprimeranalysis", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: analyses.path), "resolving a destination makes no folder")

        for stem in ["Design", "Design 2"] {
            try FileManager.default.createDirectory(
                at: analyses.appendingPathComponent(stem + ".lungfishprimeranalysis"), withIntermediateDirectories: true)
        }
        let third = try PrimerDesignCommand.resolveDestination(output: nil, project: project.path, name: "  Design  ")
        XCTAssertEqual(third.lastPathComponent, "Design 3.lungfishprimeranalysis")
        // A link counts as taken even when it dangles, so the leaf never writes through one.
        try FileManager.default.createSymbolicLink(
            atPath: analyses.appendingPathComponent("Design 3.lungfishprimeranalysis").path,
            withDestinationPath: root.appendingPathComponent("nowhere").path)
        let fourth = try PrimerDesignCommand.resolveDestination(output: nil, project: project.path, name: "Design")
        XCTAssertEqual(fourth.lastPathComponent, "Design 4.lungfishprimeranalysis")
    }

    func testAMissingProjectAnAnalysesLinkAndAnAnalysesFileAreRefusedWithExit3AndMakeNothing() throws {
        func refusal(_ projectPath: String) throws -> [String] {
            var lines: [String] = []
            XCTAssertThrowsError(
                try PrimerDesignCommand.resolveDestination(output: nil, project: projectPath, name: nil) { lines.append($0) }
            ) { error in
                XCTAssertEqual((error as? ExitCode)?.rawValue, 3, projectPath)
            }
            return lines
        }
        let missing = root.appendingPathComponent("Absent.lungfish")
        let missingLines = try refusal(missing.path)
        XCTAssertEqual(missingLines.count, 1)
        XCTAssertTrue(missingLines[0].hasPrefix("Project folder not found: \(missing.path). "), missingLines[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "a refusal makes no project")

        let linked = root.appendingPathComponent("Linked.lungfish", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: linked.appendingPathComponent("Analyses").path, withDestinationPath: elsewhere.path)
        let linkLines = try refusal(linked.path)
        XCTAssertTrue(linkLines.first?.hasPrefix("The project's Analyses folder is a symbolic link: ") == true, "\(linkLines)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing written through the link")

        let filed = root.appendingPathComponent("Filed.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: filed, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: filed.appendingPathComponent("Analyses"))
        let fileLines = try refusal(filed.path)
        XCTAssertTrue(fileLines.first?.hasPrefix("The project's Analyses path is not a folder: ") == true, "\(fileLines)")
    }

    func testAnOutputThatExistsIsRefusedAndAnewOneIsReturnedAsGiven() throws {
        let existing = root.appendingPathComponent("old.lungfishprimeranalysis", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        var lines: [String] = []
        XCTAssertThrowsError(
            try PrimerDesignCommand.resolveDestination(output: existing.path, project: nil, name: nil) { lines.append($0) }
        ) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, 3)
        }
        XCTAssertEqual(lines, [PrimerDesignExistingOutputTests.refusalWords(existing.path)])
        let fresh = root.appendingPathComponent("new.lungfishprimeranalysis")
        XCTAssertEqual(try PrimerDesignCommand.resolveDestination(output: fresh.path, project: nil, name: nil), fresh)
    }
}
