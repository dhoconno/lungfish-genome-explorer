// PrimerDesignExistingOutputTests.swift - A primer design leaf never replaces a destination that exists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.17, ruling R-B1 and QA 1. A replay of a recorded `primers design` command names the bundle the
// app already wrote, so a replay in the same project meets a destination that exists. Each of the four leaves runs
// in process on such a destination, and the test reads the exit code ArgumentParser gives the error and every file
// and folder under the project before and after. At the base of lane 12.17 every leaf failed inside its pipeline with
// exit 1 and changed nothing (the pin of QA 1). Each leaf now refuses first, exits 3 and still changes nothing.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI

final class PrimerDesignExistingOutputTests: XCTestCase {
    private var root: URL!
    private var bundle: URL!
    private var fasta: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("primer-existing-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Analyses/old.lungfishprimeranalysis", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true
        )
        try Data("{\"pairs\":[\"old\"]}\n".utf8).write(to: bundle.appendingPathComponent("results/old.json"))
        try Data("old manifest\n".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        fasta = root.appendingPathComponent("templates.fasta")
        try Data((">template-one\n" + String(repeating: "ACGTTGCAAC", count: 30) + "\n").utf8).write(to: fasta)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrimer3LeafLeavesAnExistingDestinationAlone() async throws {
        try await assertRefuses(PrimerDesignCommand.Primer3Subcommand.self, ["--fasta-record", fasta.path + "@0"])
    }

    func testPrimalScheme3LeafLeavesAnExistingDestinationAlone() async throws {
        try await assertRefuses(PrimerDesignCommand.PrimalScheme3Subcommand.self, ["--msa", fasta.path])
    }

    func testOlivarLeafLeavesAnExistingDestinationAlone() async throws {
        try await assertRefuses(OlivarDesignCommand.self, ["--msa", fasta.path])
    }

    func testVarVAMPLeafLeavesAnExistingDestinationAlone() async throws {
        try await assertRefuses(VarVAMPDesignCommand.self, ["--msa", fasta.path])
    }

    /// The refusal names the bundle and the option to change, and exits 3. UX's sentence goes on to suggest `--project`,
    /// which no `primers design` leaf has, so the text stops after its first clause until UX rules. A new path passes.
    func testTheRefusalNamesTheBundleAndExitsThree() throws {
        var lines: [String] = []
        XCTAssertThrowsError(try PrimerDesignCommand.refuseExistingOutput(bundle.path) { lines.append($0) }) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, 3)
        }
        XCTAssertEqual(lines, ["Output already exists: \(bundle.path). Give --output a new path."])
        let fresh = root.appendingPathComponent("Analyses/new.lungfishprimeranalysis").path
        XCTAssertNoThrow(try PrimerDesignCommand.refuseExistingOutput(fresh) { lines.append($0) })
        XCTAssertEqual(lines.count, 1, "a new path is not refused")
    }

    // MARK: - Helpers

    /// Runs the leaf on `arguments` with `--output` naming the existing bundle. The leaf exits 3, and no file or folder
    /// under the project changes.
    private func assertRefuses<Command: AsyncParsableCommand>(
        _ type: Command.Type, _ arguments: [String], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = try snapshot()
        var command = try type.parse(arguments + ["--output", bundle.path])
        do {
            try await command.run()
            XCTFail("the leaf ran into an existing destination", file: file, line: line)
        } catch {
            XCTAssertEqual(type.exitCode(for: error).rawValue, 3, type.message(for: error), file: file, line: line)
        }
        XCTAssertEqual(try snapshot(), before, "the old bundle's bytes and the project's folders", file: file, line: line)
    }

    /// Every folder and file under the project, a folder as an empty value and a file with its bytes.
    private func snapshot() throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys))
        for case let url as URL in enumerator {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))
            if try url.resourceValues(forKeys: Set(keys)).isDirectory == true {
                entries[relative + "/"] = Data()
            } else {
                entries[relative] = try Data(contentsOf: url)
            }
        }
        return entries
    }
}
