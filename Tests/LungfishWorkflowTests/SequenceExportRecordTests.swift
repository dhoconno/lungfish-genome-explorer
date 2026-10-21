// SequenceExportRecordTests.swift - The record of a zstd export names the compressor and the version that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.17 M3 (BIO 4). `convert --compress zstd` records one step for zstd beside the step of `convert`.
// The step names the tool, carries the argv that ran, names the lock entry, and holds the version that the
// environment which ran it reports in its conda-meta, through the evidence type the other managed tools use. The
// first class builds the step from a fake environment, so it runs on every Mac. The second class is the real form.
// It needs the zstd that Lungfish manages, so it is a Conformance class gated on `ToolAvailability` (QA 3).

import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SequenceExportRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceExportRecord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func receipt(in environment: URL) -> SequenceExportCompressor.Receipt {
        SequenceExportCompressor.Receipt(
            toolName: "zstd",
            executable: environment.appendingPathComponent("bin/zstd"),
            arguments: ["-c", "/work/export.fa"]
        )
    }

    func testTheStepNamesZstdAndTheVersionOfTheEnvironmentThatRan() throws {
        let environment = root.appendingPathComponent("envs/zstd", isDirectory: true)
        try CondaMetaRecordWriter.write(environment: environment, package: "zstd", version: "1.5.7", build: "hf451053_7")
        let step = SequenceExportCompressor.provenanceStep(for: receipt(in: environment), wallTimeSeconds: 0.25)
        XCTAssertEqual(step.toolName, "zstd")
        XCTAssertEqual(step.toolVersion, "1.5.7")
        XCTAssertEqual(step.managedToolID, ManagedToolID(rawValue: "zstd"))
        XCTAssertEqual(step.toolVersionEvidence, .observed(version: "1.5.7", reportedLine: "zstd-1.5.7-hf451053_7"))
        XCTAssertEqual(step.argv, [environment.appendingPathComponent("bin/zstd").path, "-c", "/work/export.fa"])
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(step.wallTimeSeconds, 0.25)
    }

    /// The version comes from the environment that ran, and not from the lock, so an environment changed after
    /// its install records what it holds.
    func testTheStepFollowsTheEnvironmentAndNotTheLock() throws {
        let environment = root.appendingPathComponent("envs/zstd", isDirectory: true)
        try CondaMetaRecordWriter.write(environment: environment, package: "zstd", version: "1.5.9", build: "h0000000_0")
        let step = SequenceExportCompressor.provenanceStep(for: receipt(in: environment), wallTimeSeconds: 0)
        XCTAssertEqual(step.toolVersion, "1.5.9")
        XCTAssertEqual(step.toolVersionEvidence, .observed(version: "1.5.9", reportedLine: "zstd-1.5.9-h0000000_0"))
    }

    /// An environment that holds no record of the package records the lock's pin, as a pin.
    func testAnEnvironmentWithoutCondaMetaRecordsTheLockPin() throws {
        let environment = root.appendingPathComponent("envs/zstd", isDirectory: true)
        try FileManager.default.createDirectory(
            at: environment.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true
        )
        let step = SequenceExportCompressor.provenanceStep(for: receipt(in: environment), wallTimeSeconds: 0)
        guard case .lockPin(let version, let id)? = step.toolVersionEvidence else {
            return XCTFail("expected a lock pin, got \(String(describing: step.toolVersionEvidence))")
        }
        XCTAssertEqual(id, ManagedToolID(rawValue: "zstd"))
        XCTAssertEqual(step.toolVersion, version)
    }
}

/// The real form, run once with `LUNGFISH_REQUIRE_TOOLS=1` and `LUNGFISH_CONDA_ROOT` set to the conda folder of the
/// golden environment, whose zstd is the managed build `1.5.7` `hf451053_7`.
final class SequenceExportCompressorConformanceTests: XCTestCase {
    func testTheManagedZstdExportDecompressesToItsSourceAndTheRecordNamesTheVersionThatRan() async throws {
        let zstd = try await ToolAvailability.require("zstd", environment: "zstd")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceExportCompressorConformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("export.fa")
        let text = String(repeating: ">a\nACGTACGTAC\n", count: 2_000)
        try text.write(to: source, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out.fa.zst")

        let receipt = try await SequenceExportCompressor.compress(source: source, to: destination, kind: .zstd)

        let ran = try XCTUnwrap(receipt, "zstd returns a receipt")
        XCTAssertEqual(ran.executable.resolvingSymlinksInPath().path, zstd.resolvingSymlinksInPath().path)
        XCTAssertEqual(Array(try Data(contentsOf: destination).prefix(4)), [0x28, 0xb5, 0x2f, 0xfd], "a zstd frame")
        let decompressed = try ProcessRunner.run(zstd, ["-dc", destination.path])
        XCTAssertEqual(decompressed.status, 0)
        XCTAssertEqual(decompressed.stdout, text, "the export decompresses to its source")

        let step = SequenceExportCompressor.provenanceStep(for: ran, wallTimeSeconds: 0)
        XCTAssertEqual(step.toolName, "zstd")
        XCTAssertEqual(step.toolVersion, "1.5.7")
        XCTAssertEqual(step.toolVersionEvidence, .observed(version: "1.5.7", reportedLine: "zstd-1.5.7-hf451053_7"))
    }
}
