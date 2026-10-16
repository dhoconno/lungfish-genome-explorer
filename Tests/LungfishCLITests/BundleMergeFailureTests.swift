// BundleMergeFailureTests.swift - bundle merge ends a failure with exit 64 and publishes nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49, review A49 Fixes 2 and 5. `docs/contracts/ADDING-AN-OPERATION.md` and decision U-211-2 end
// a refusal with exit 3 and a failure with exit 64, and a refusal leaves no folder behind. The built lungfish-cli
// runs to the end against a stand-in conda root whose bgzip answers the version probe and exits 1 on any other
// call. The source bundles hold a plain FASTA each, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishTestSupport

final class BundleMergeFailureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bundle-merge-failure")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A failure of the merge's own work, here the bgzip the builder runs, is not a refusal. It ends the command
    /// with exit 64 and a last `failed` event, and the run publishes no bundle and leaves no stage.
    func testAFailingBgzipEndsWithExit64AndPublishesNothing() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let first = try makeSource("Alpha", sequence: "chrA", in: project)
        let second = try makeSource("Beta", sequence: "chrB", in: project)
        let condaRoot = try stubCondaRoot()

        let result = try runCLI(
            ["bundle", "merge", first.path, second.path, "--name=Merged", "--format", "json"], condaRoot: condaRoot
        )
        XCTAssertEqual(result.status, 64, "a failure exits 64. \(result.diagnostics)")
        try assertLastEventIsFailed(result)

        let entries = try FileManager.default.contentsOfDirectory(atPath: project.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("Merged") }, "a failed merge publishes no bundle. \(entries)")
        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        let stages = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
            .filter { $0.hasPrefix("reference-merge-") }
        XCTAssertEqual(stages, [], "the stage is removed")
    }

    /// A refusal is a request the input makes impossible, so it ends before any folder exists. Two bundles that
    /// share `chrA` are refused with exit 3 and a last `failed` event, and the folder `--output-directory` names
    /// is not created.
    func testARefusedMergeCreatesNoOutputFolder() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let first = try makeSource("Alpha", sequence: "chrA", in: project)
        let second = try makeSource("Beta", sequence: "chrA", in: project)
        let condaRoot = try stubCondaRoot()
        let output = root.appendingPathComponent("new", isDirectory: true)

        let result = try runCLI(
            [
                "bundle", "merge", first.path, second.path, "--name=Merged",
                "--output-directory", output.path, "--format", "json",
            ],
            condaRoot: condaRoot
        )
        XCTAssertEqual(result.status, 3, "a refusal exits 3. \(result.diagnostics)")
        try assertLastEventIsFailed(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refusal creates no output folder")
    }

    // MARK: - Running the CLI

    private struct Result {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostics: String { "Standard output: \(standardOutput) Standard error: \(standardError)" }
    }

    /// The last line of standard output is a `failed` event.
    private func assertLastEventIsFailed(_ result: Result, file: StaticString = #filePath, line: UInt = #line) throws {
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any],
            "the last line is an event. \(lines)", file: file, line: line
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)", file: file, line: line)
    }

    /// Runs the built `lungfish-cli` to the end and waits up to a minute.
    private func runCLI(_ arguments: [String], condaRoot: URL) throws -> Result {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: Self.self),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: ["LUNGFISH_CONDA_ROOT": condaRoot.path])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            standardOutput: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            standardError: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    // MARK: - Fixture (copied from BundleMergeSIGTERMTests, whose private helpers this class cannot reach)

    /// A reference bundle folder that holds one plain FASTA of one sequence, so reading it needs no tool.
    private func makeSource(_ name: String, sequence: String, in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try ">\(sequence)\nACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT\n"
            .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// A conda root whose bgzip and samtools answer a version probe, and whose bgzip exits 1 on any other call.
    /// The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-ins win over any real tool.
    private func stubCondaRoot() throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        exit 1
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools)] {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }
}
