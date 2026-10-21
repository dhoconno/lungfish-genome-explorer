// ViralReconResultsFolderLeafTests.swift - workflow run nf-core/viralrecon refuses a results folder that already holds files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.21 STALE-OUT, M3 (UX 1, QA 2). The leaf refuses the folder as an input error, exit status 3 like the
// `--timeout` refusal, before anything runs, and prints UX's line W1 with its own option name. A missing or empty
// folder gets through, and so does a resumed run, which continues into the folder its earlier run used.

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class ViralReconResultsFolderLeafTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-leaf-results-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func usedFolder() throws -> URL {
        let folder = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "an earlier run\n".write(
            to: folder.appendingPathComponent("multiqc_report.html"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    private func assertRefused(_ arguments: [String], folder: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let command = try RunSubcommand.parse(arguments)
        do {
            try await command.run()
            XCTFail("a results folder that holds files must be refused for nf-core/viralrecon", file: file, line: line)
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("expected validationFailed, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(
                errors,
                ["--results-dir \(folder.path) already holds files. Name an empty or new folder."],
                file: file,
                line: line
            )
            XCTAssertEqual(error.exitCode, .inputError, file: file, line: line)
            XCTAssertEqual(error.exitCode.rawValue, 3, file: file, line: line)
        }
    }

    func testAResultsFolderThatHoldsFilesIsRefusedWithTheInputErrorStatus() async throws {
        let folder = try usedFolder()
        try await assertRefused(
            ["nf-core/viralrecon", "--input", "samplesheet.csv", "--results-dir", folder.path, "--quiet"],
            folder: folder
        )
    }

    func testADryRunIntoAFolderThatHoldsFilesIsRefusedToo() async throws {
        let folder = try usedFolder()
        try await assertRefused(
            ["nf-core/viralrecon", "--input", "samplesheet.csv", "--results-dir", folder.path, "--dry-run", "--quiet"],
            folder: folder
        )
    }

    func testAMissingAndAnEmptyResultsFolderGetThrough() async throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        for folder in [empty, missing] {
            let command = try RunSubcommand.parse([
                "nf-core/viralrecon", "--input", "samplesheet.csv", "--results-dir", folder.path, "--dry-run", "--quiet",
            ])
            try await command.run()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "a dry run writes nothing")
    }

    func testAResumedRunIsNotRefusedForAFolderThatHoldsFiles() async throws {
        let folder = try usedFolder()
        let command = try RunSubcommand.parse([
            "nf-core/viralrecon", "--input", "samplesheet.csv", "--results-dir", folder.path, "--resume", "--dry-run", "--quiet",
        ])
        try await command.run()
    }
}
