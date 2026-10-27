// AssembleCommandReferenceBundleTests.swift - assemble --reference-bundle publishes the bundle Reassemble opens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Phase 2.10 lane A46, the ruling on the reference bundle. `assemble --reference-bundle` publishes,
/// after the assembler, the `.lungfishref` bundle the app's Reassemble route builds, beside
/// `--output` and named after the project, through `AssemblyReferenceBundle.publish`, so its words
/// and fractions from 0.92 are the app's. The run record names the bundle and each of its files with
/// its SHA-256 in an `Assembly Bundle Wrapping` step. A stand-in SPAdes lets the whole command run
/// in this process, on the seam `AssembleCommandRecordedCommandLineTests` uses. The replay of the
/// recorded command needs bgzip, so it runs in `AssemblyRouteParityReplayTests` (integration tier).
final class AssembleCommandReferenceBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-reference-bundle")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTheFlagBuildsTheBundleTheRecordNames() async throws {
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")
        let run = try await assemble(in: root.appendingPathComponent("side", isDirectory: true))
        XCTAssertNil(run.error)

        let bundle = run.output.deletingLastPathComponent().appendingPathComponent("demo.lungfishref", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(BundleManifest.filename).path))
        let beside = try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path)
        XCTAssertEqual(beside.sorted(), ["demo", "demo.lungfishref"], "the bundle sits beside --output, and no staging is left")

        let bundleSteps = run.progress.filter { $0.fraction >= AssemblyReferenceBundle.startFraction }
        XCTAssertEqual(bundleSteps.first?.message, "Creating reference bundle...")
        XCTAssertEqual(bundleSteps.first?.fraction ?? 0, 0.92, accuracy: 1e-9)
        XCTAssertTrue(bundleSteps.map(\.message).contains("Validating bundle..."))
        XCTAssertEqual(bundleSteps.last?.message, "Bundle created successfully")
        XCTAssertEqual(bundleSteps.last?.fraction ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(run.outputs, [run.output.path, bundle.path], "the folder, then the bundle")

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.output))
        XCTAssertEqual(record.argv, [
            CLICommandIdentity.executableName, "assemble", run.reads.path, "--assembler", "spades",
            "--read-type", "illumina-short-reads", "--project-name", "demo", "--threads", "1",
            "--output", run.output.path, "--reference-bundle", "--format", "json",
        ])
        // The record's output is the bundle, with role output (BIO's ruling D1 on A46 M3).
        let output = try XCTUnwrap(record.output, "the record names no output")
        XCTAssertTrue(output.path.hasSuffix("/demo.lungfishref"), "the record's output is \(output.path)")
        XCTAssertEqual(output.role, .output)
        let wrapping = try XCTUnwrap(record.steps.first { $0.toolName == "Assembly Bundle Wrapping" })
        XCTAssertTrue(wrapping.outputs.contains { $0.path.hasSuffix("/demo.lungfishref") }, "the step names the bundle")
        let files = wrapping.outputs.filter { $0.path.contains("/demo.lungfishref/") }
        XCTAssertTrue(files.contains { $0.path.hasSuffix("/\(BundleManifest.filename)") }, "\(files.map(\.path))")
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(file.checksumSHA256, digest, file.path)
        }
    }

    func testAnExistingBundleIsRefusedBeforeTheAssembler() async throws {
        let side = root.appendingPathComponent("side", isDirectory: true)
        let bundle = side.appendingPathComponent("Assemblies/demo.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let sentinel = bundle.appendingPathComponent("sentinel.txt")
        try "keep me\n".write(to: sentinel, atomically: true, encoding: .utf8)

        let run = try await assemble(in: side)

        XCTAssertEqual((run.error as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue, "\(String(describing: run.error))")
        let failed = try XCTUnwrap(run.failed)
        XCTAssertTrue(failed.hasPrefix("Output assembly bundle already exists: \(bundle.path)"), failed)
        XCTAssertTrue(failed.contains("Choose another project name"), "the refusal says what to try next: \(failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.output.path), "the assembler never ran")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep me\n", "the existing bundle is untouched")
    }

    // MARK: - Running the command

    private struct Run {
        let reads: URL
        let output: URL
        let progress: [(fraction: Double, message: String)]
        let outputs: [String]
        let failed: String?
        let error: (any Error)?
    }

    /// Runs `assemble --reference-bundle --format json` on one read file in `side`, with the project
    /// `demo` and `--output side/Assemblies/demo`, as the Reassemble row does, and reads its events.
    private func assemble(in side: URL) async throws -> Run {
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        let reads = side.appendingPathComponent("sample.fastq")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nACGTACGT\n+\nIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let output = side.appendingPathComponent("Assemblies/demo", isDirectory: true)
        let command = try AssembleCommand.parse([
            reads.path, "--assembler", "spades", "--read-type", "illumina-short-reads",
            "--project-name", "demo", "--threads", "1", "--output", output.path,
            "--reference-bundle", "--format", "json",
        ])
        let spades = try StandInSPAdesConda(root: root.appendingPathComponent("tool-\(side.lastPathComponent)", isDirectory: true))
        let (standardOutput, error) = await Self.capturingStandardOutput {
            try await command.execute(pipeline: ManagedAssemblyPipeline(condaManager: spades.condaManager))
        }
        var progress: [(fraction: Double, message: String)] = []
        var outputs: [String] = []
        var failed: String?
        for line in standardOutput.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch event["event"] as? String {
            case "progress":
                progress.append(((event["progress"] as? Double) ?? -1, (event["message"] as? String) ?? ""))
            case "complete":
                outputs = (event["outputs"] as? [String]) ?? []
            case "failed":
                failed = event["error"] as? String
            default:
                break
            }
        }
        return Run(reads: reads, output: output, progress: progress, outputs: outputs, failed: failed, error: error)
    }

    /// Runs `body` with standard output in a file and returns what it printed and what it threw.
    private static func capturingStandardOutput(_ body: () async throws -> Void) async -> (String, (any Error)?) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("assemble-stdout-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return ("", CocoaError(.fileWriteUnknown)) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        var thrown: (any Error)?
        do {
            try await body()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? handle.close()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return (text, thrown)
    }
}
