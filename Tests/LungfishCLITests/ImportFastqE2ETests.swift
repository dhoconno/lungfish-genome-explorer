// ImportFastqE2ETests.swift - End-to-end CLI subprocess tests for `lungfish import fastq`
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ImportFastqE2ETests: XCTestCase {

    /// Find the CLI binary injected by the test runner or beside this test bundle.
    private var cliBinaryPath: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
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
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
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
        XCTAssertTrue(stdout.contains("--pairing"),           "Help should mention --pairing")
    }

    // MARK: - --pairing (Import sheet Pairing popup parity, 2026-09-24)

    /// Copies the sarscov2 pair into a fresh input directory and returns it.
    private func stageFixturePair(_ fixtures: URL) throws -> URL {
        let tmpInput = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpInput, withIntermediateDirectories: true)
        for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name),
                to: tmpInput.appendingPathComponent(name)
            )
        }
        return tmpInput
    }

    private func makeProject() throws -> URL {
        let tmpProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pairing-\(UUID().uuidString).lungfish")
        try FileManager.default.createDirectory(
            at: tmpProject.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        return tmpProject
    }

    private func bundles(in project: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent("Imports"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "lungfishfastq" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func bundleFASTQ(_ bundle: URL) throws -> URL {
        try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        )
    }

    func testPairingSingleImportsADetectedPairAsTwoSamples() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }
        let tmpInput = try stageFixturePair(fixtures)
        defer { try? FileManager.default.removeItem(at: tmpInput) }
        let tmpProject = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmpProject) }
        let inputPairs = try FASTQPairInterleaver.countRecords(in: fixtures.appendingPathComponent("test_1.fastq.gz"))

        let (exitCode, _, stderr) = try runCLI([
            "import", "fastq", tmpInput.path,
            "--project", tmpProject.path,
            "--platform", "illumina",
            "--pairing", "single",
            "--no-optimize-storage",
        ])

        XCTAssertEqual(exitCode, 0, "Import should succeed. stderr: \(stderr)")
        let created = try bundles(in: tmpProject)
        XCTAssertEqual(created.map(\.lastPathComponent), ["test_1.lungfishfastq", "test_2.lungfishfastq"])
        for bundle in created {
            let fastq = try bundleFASTQ(bundle)
            XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: fastq), inputPairs)
            XCTAssertEqual(FASTQMetadataStore.load(for: fastq)?.ingestion?.pairingMode, .singleEnd)
        }
    }

    func testPairingInterleavedRecordsASingleFileAsInterleavedPairs() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }
        let tmpInput = try stageFixturePair(fixtures)
        defer { try? FileManager.default.removeItem(at: tmpInput) }
        let tmpProject = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmpProject) }
        let inputRecords = try FASTQPairInterleaver.countRecords(in: fixtures.appendingPathComponent("test_1.fastq.gz"))

        let (exitCode, _, stderr) = try runCLI([
            "import", "fastq", tmpInput.appendingPathComponent("test_1.fastq.gz").path,
            "--project", tmpProject.path,
            "--platform", "illumina",
            "--pairing", "interleaved",
            "--no-optimize-storage",
        ])

        XCTAssertEqual(exitCode, 0, "Import should succeed. stderr: \(stderr)")
        let created = try bundles(in: tmpProject)
        XCTAssertEqual(created.count, 1)
        let fastq = try bundleFASTQ(try XCTUnwrap(created.first))
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: fastq), inputRecords, "The file is kept whole")
        XCTAssertEqual(FASTQMetadataStore.load(for: fastq)?.ingestion?.pairingMode, .interleaved)
    }

    func testPairingRejectsUnknownValues() throws {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }
        let tmpProject = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmpProject) }

        let (exitCode, stdout, stderr) = try runCLI([
            "import", "fastq", fixtures.path,
            "--project", tmpProject.path,
            "--pairing", "sideways",
            "--dry-run",
        ])

        XCTAssertNotEqual(exitCode, 0)
        XCTAssertTrue((stdout + stderr).contains("Unknown pairing value"), stdout + stderr)
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

        // Copy FASTQ fixtures into a temp input directory so this subprocess test
        // can freely create adjacent sidecars without touching shared fixtures.
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

        // Data-loss regression (2026-09-24): with --no-optimize-storage the
        // pipeline used to keep only R1 and delete the staged R2, while the
        // bundle metadata still claimed an interleaved pair. The bundle FASTQ
        // must hold every R1 and R2 record.
        let inputPairs = try FASTQPairInterleaver.countRecords(in: fixtures.appendingPathComponent("test_1.fastq.gz"))
        XCTAssertEqual(
            inputPairs,
            try FASTQPairInterleaver.countRecords(in: fixtures.appendingPathComponent("test_2.fastq.gz")),
            "Fixture mates must match"
        )
        XCTAssertGreaterThan(inputPairs, 0)
        let bundleFASTQs = try FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        let bundleFASTQ = try XCTUnwrap(bundleFASTQs.first, "Bundle should hold one .fastq.gz payload")
        XCTAssertEqual(
            try FASTQPairInterleaver.countRecords(in: bundleFASTQ),
            2 * inputPairs,
            "Imported bundle must hold R1 + R2 records (2 x \(inputPairs) pairs)"
        )

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: provenanceURL.path),
            "FASTQ import should write provenance at \(provenanceURL.path)"
        )

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(envelope.workflowName, "lungfish import fastq")
        XCTAssertEqual(envelope.toolName, "lungfish import fastq")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.defaults["compressionLevel"], .string(CompressionLevel.balanced.rawValue))
        XCTAssertEqual(envelope.options.defaults["optimizeStorage"], .boolean(true))
        XCTAssertEqual(envelope.options.defaults["threads"], .integer(4))
        XCTAssertEqual(envelope.options.resolvedDefaults["compressionLevel"], .string(CompressionLevel.fast.rawValue))
        XCTAssertEqual(envelope.options.resolvedDefaults["optimizeStorage"], .boolean(false))
        guard case .integer(let resolvedThreads) = envelope.options.resolvedDefaults["threads"] else {
            return XCTFail("Expected resolved thread count in FASTQ provenance")
        }
        XCTAssertGreaterThan(resolvedThreads, 0)
        XCTAssertEqual(envelope.legacyWorkflowRun().status, .completed)
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "lungfish import fastq" })
        XCTAssertTrue(envelope.files.contains {
            $0.role == .input && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path.hasSuffix(".fastq.gz") && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertFalse(
            envelope.outputs.contains { $0.path.contains("/.tmp/") },
            "Final provenance output records should point at bundle payloads, not temp workspace files"
        )
    }
}
