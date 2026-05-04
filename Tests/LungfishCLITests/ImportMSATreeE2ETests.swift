// ImportMSATreeE2ETests.swift - End-to-end CLI tests for native MSA/tree imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

final class ImportMSATreeE2ETests: XCTestCase {
    private let fileManager = FileManager.default
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? fileManager.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testImportMSAWritesNativeBundleProgressAndProvenance() throws {
        let workspace = try makeWorkspace()
        let projectURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = workspace.appendingPathComponent("mhc.aln")
        try """
        CLUSTAL W

        seq1 ACGT-A
        seq2 AC-TTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "import", "msa", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportStart\""))
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportComplete\""))

        let bundleURL = projectURL
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("mhc.lungfishmsa", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
        let provenance = try String(
            contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"),
            encoding: .utf8
        )
        let normalizedProvenance = provenance.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedProvenance.contains("lungfish import msa"))
        XCTAssertTrue(normalizedProvenance.contains(bundleURL.path))
        XCTAssertFalse(normalizedProvenance.contains("\"/tmp/"), "MSA provenance should point at final project paths, not /tmp")
    }

    func testImportTreeWritesNativeBundleProgressAndProvenance() throws {
        let workspace = try makeWorkspace()
        let projectURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = workspace.appendingPathComponent("mhc.nwk")
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "import", "tree", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportStart\""))
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportComplete\""))

        let bundleURL = projectURL
            .appendingPathComponent("Phylogenetic Trees", isDirectory: true)
            .appendingPathComponent("mhc.lungfishtree", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
        let provenance = try String(
            contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"),
            encoding: .utf8
        )
        let normalizedProvenance = provenance.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedProvenance.contains("lungfish import tree"))
        XCTAssertTrue(normalizedProvenance.contains(bundleURL.path))
        XCTAssertFalse(normalizedProvenance.contains("\"/tmp/"), "Tree provenance should point at final project paths, not /tmp")
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let binary = cliBinaryPath else {
            throw XCTSkip("CLI binary not built at expected path - run `swift build --product lungfish-cli` first")
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

    private var cliBinaryPath: URL? {
        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func makeWorkspace() throws -> URL {
        let root = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-msa-tree-e2e-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        cleanupURLs.append(root)
        return root
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
