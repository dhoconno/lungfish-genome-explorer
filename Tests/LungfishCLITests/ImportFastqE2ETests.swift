// ImportFastqE2ETests.swift - End-to-end CLI subprocess tests for `lungfish import fastq`
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishWorkflow

final class ImportFastqE2ETests: XCTestCase {

    /// Find the CLI binary in the build products directory.
    /// Checks both `.build/debug/` (symlink) and the arch-specific path.
    private var cliBinaryPath: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // LungfishCLITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root

        // Try the symlink first, then the arch-specific path
        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Sarscov2 fixtures directory containing test_1.fastq.gz and test_2.fastq.gz
    private var fixturesDir: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        // thisFile: .../Tests/LungfishCLITests/ImportFastqE2ETests.swift
        // testsDir: .../Tests/
        let testsDir = thisFile
            .deletingLastPathComponent()  // LungfishCLITests/
            .deletingLastPathComponent()  // Tests/
        let dir = testsDir.appendingPathComponent("Fixtures/sarscov2")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Run the CLI binary with given arguments and capture exit code + output.
    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let binary = cliBinaryPath else {
            throw XCTSkip("CLI binary not built at expected path — run `swift build --product lungfish-cli` first")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - Tests

    func testHelpShowsNewFlags() throws {
        let (exitCode, stdout, _) = try runCLI(["import", "fastq", "--help"])
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(stdout.contains("--platform"),          "Help should mention --platform")
        XCTAssertTrue(stdout.contains("--no-optimize-storage"), "Help should mention --no-optimize-storage")
        XCTAssertTrue(stdout.contains("--compression"),       "Help should mention --compression")
        XCTAssertTrue(stdout.contains("--force"),             "Help should mention --force")
        XCTAssertTrue(stdout.contains("--recipe"),            "Help should mention --recipe")
    }

    func testDryRunWithFixtures() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }

        let tmpProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-test-\(UUID().uuidString).lungfish")
        try FileManager.default.createDirectory(at: tmpProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpProject) }

        let (exitCode, stdout, stderr) = try runCLI([
            "import", "fastq",
            fixtures.path,
            "--project", tmpProject.path,
            "--platform", "illumina",
            "--dry-run",
        ])

        XCTAssertEqual(exitCode, 0, "Dry run should succeed. stderr: \(stderr)")
        let combined = stdout + stderr
        // The sarscov2 fixtures are named test_1.fastq.gz / test_2.fastq.gz, so the
        // sample name will be "test" and it will be detected as a paired sample.
        XCTAssertTrue(
            combined.lowercased().contains("test") || combined.contains("pair"),
            "Dry run should mention 'test' sample or 'pair'. Output: \(combined)"
        )
    }

    func testDryRunWithVSP2Recipe() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }

        let tmpProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-test-\(UUID().uuidString).lungfish")
        try FileManager.default.createDirectory(at: tmpProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpProject) }

        let (exitCode, _, stderr) = try runCLI([
            "import", "fastq",
            fixtures.path,
            "--project", tmpProject.path,
            "--platform", "illumina",
            "--recipe", "vsp2",
            "--no-optimize-storage",
            "--compression", "fast",
            "--dry-run",
        ])

        XCTAssertEqual(exitCode, 0, "Dry run with VSP2 should succeed. stderr: \(stderr)")
    }

    func testRealImportOnFixtures() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }

        // Copy FASTQ fixtures into a temp input directory so the importer doesn't
        // move or delete the originals from the shared test fixture folder.
        let tmpInput = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpInput, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpInput) }

        for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            let src = fixtures.appendingPathComponent(name)
            let dst = tmpInput.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
        }

        let tmpProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-import-\(UUID().uuidString).lungfish")
        try FileManager.default.createDirectory(at: tmpProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmpProject.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpProject) }

        let (exitCode, _, stderr) = try runCLI([
            "import", "fastq",
            tmpInput.path,
            "--project", tmpProject.path,
            "--platform", "illumina",
            "--no-optimize-storage",
            "--compression", "fast",
        ])

        XCTAssertEqual(exitCode, 0, "Real import should succeed. stderr: \(stderr)")

        // Verify at least one bundle was created under Imports/
        let importsDir = tmpProject.appendingPathComponent("Imports")
        let imports = try FileManager.default.contentsOfDirectory(
            at: importsDir,
            includingPropertiesForKeys: nil)
        let bundles = imports.filter { $0.pathExtension == "lungfishfastq" }
        XCTAssertFalse(bundles.isEmpty, "At least one .lungfishfastq bundle should be created")

        let bundleURL = try XCTUnwrap(bundles.first)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: provenanceURL.path),
            "FASTQ import should write provenance at \(provenanceURL.path)"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
        XCTAssertEqual(run.name, "lungfish import fastq")
        XCTAssertEqual(run.status, .completed)
        XCTAssertTrue(run.steps.contains { $0.toolName == "lungfish import fastq" })
        XCTAssertTrue(run.primaryInputFiles.contains { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(run.allOutputFiles.contains {
            $0.path.hasSuffix(".fastq.gz") && $0.sha256 != nil && $0.sizeBytes != nil
        })
        XCTAssertFalse(
            run.allOutputFiles.contains { $0.path.contains("/.tmp/") },
            "Final provenance output records should point at bundle payloads, not temp workspace files"
        )
    }
}
