// PrimerDesignProjectOptionTests.swift - The four primers design leaves take --project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M2, row PRIMER-PROJECT. A result in a project takes `--project`, so a replay in Terminal makes a
// new result and leaves the old one alone (docs/contracts/ADDING-AN-OPERATION.md, the Copy CLI Command part). These
// tests were red at the base of the lane, where no `primers design` leaf had the option. The Primer3 leaf runs on a
// stand-in `primer3_core` that answers the version probe and returns no pair, so no real tool is needed.

import ArgumentParser
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI

final class PrimerDesignProjectOptionTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var fasta: URL!
    private var primer3: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "primer-project").resolvingSymlinksInPath()
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        fasta = root.appendingPathComponent("templates.fasta")
        try Data((">template-one\n" + String(repeating: "ACGTTGCAAC", count: 30) + "\n").utf8).write(to: fasta)
        primer3 = try PrimerDesignCommandTests.writeStandInPrimer3(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func analysesBundle(_ name: String) -> URL {
        project.appendingPathComponent("Analyses/\(name).lungfishprimeranalysis", isDirectory: true)
    }

    private func primer3Arguments(_ place: [String]) -> [String] {
        ["--fasta-record", fasta.path + "@0"] + place + ["--primer3-path", primer3.path]
    }

    /// Every file and folder under `folder`, a file with its bytes.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(folder.path.count))
            let isDirectory = try url.resourceValues(forKeys: Set(keys)).isDirectory == true
            entries[relative] = isDirectory ? Data() : try Data(contentsOf: url)
        }
        return entries
    }

    /// A design given `--project` writes a new bundle in the project's Analyses folder, which the project did not have,
    /// and a second run of the same command writes another new bundle and leaves the first untouched.
    func testAProjectRunWritesANewBundleAndASecondRunLeavesTheFirstAlone() async throws {
        let arguments = primer3Arguments(["--project", project.path, "--name", "Design"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Analyses").path))
        var first = try PrimerDesignCommand.Primer3Subcommand.parse(arguments)
        try await first.run()
        let bundle = analysesBundle("Design")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("results/primer3-normalized-v1.json").path),
            "the first run wrote the bundle into the Analyses folder it made")
        let before = try snapshot(of: bundle)

        var second = try PrimerDesignCommand.Primer3Subcommand.parse(arguments)
        try await second.run()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: analysesBundle("Design 2").appendingPathComponent("manifest.json").path),
            "the second run wrote a new bundle")
        XCTAssertEqual(try snapshot(of: bundle), before, "the first bundle's bytes and folders")
        let names = try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Analyses").path)
        XCTAssertEqual(names.sorted(), ["Design 2.lungfishprimeranalysis", "Design.lungfishprimeranalysis"])
    }

    /// The command the app records writes the name as `--name=<name>`. A replay of it in a project with no Analyses
    /// folder succeeds, which is the Known limit of docs/release-notes/2026.10.21.md that this lane drops.
    func testAReplayInAProjectWithNoAnalysesFolderSucceeds() async throws {
        let arguments = primer3Arguments(["--project", project.path, "--name=Primer analysis"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Analyses").path))
        var command = try PrimerDesignCommand.Primer3Subcommand.parse(arguments)
        do {
            try await command.run()
        } catch {
            return XCTFail("the replay failed: \(PrimerDesignCommand.Primer3Subcommand.message(for: error))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysesBundle("Primer analysis").path))
    }

    /// An existing `--output` without `--project` refuses with the words of R-B1, which name `--project` again now
    /// that the four leaves take it. The text is word for word the one of docs/plans/2026-10-17-phase-2-12-panel-decisions.md.
    func testAnExistingOutputWithoutProjectRefusesWithTheProjectClause() throws {
        let existing = analysesBundle("Old")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        var lines: [String] = []
        XCTAssertThrowsError(try PrimerDesignCommand.refuseExistingOutput(existing.path) { lines.append($0) }) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, 3)
        }
        XCTAssertEqual(lines, [
            "Output already exists: \(existing.path). Give --output a new path, or use --project to write a new bundle in the project."
        ])
    }

    /// Each of the four leaves parses `--project` in place of `--output`.
    func testEachDesignLeafParsesProjectInPlaceOfOutput() throws {
        let place = ["--project", project.path]
        XCTAssertNoThrow(try PrimerDesignCommand.Primer3Subcommand.parse(["--fasta-record", fasta.path + "@0"] + place))
        XCTAssertNoThrow(try PrimerDesignCommand.PrimalScheme3Subcommand.parse(["--msa", fasta.path] + place))
        XCTAssertNoThrow(try OlivarDesignCommand.parse(["--msa", fasta.path] + place))
        XCTAssertNoThrow(try VarVAMPDesignCommand.parse(["--msa", fasta.path] + place))
    }
}
