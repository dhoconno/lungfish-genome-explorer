// DemuxManagedToolTests.swift - The tool step a demux genotyping run records for a managed executable
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. A step names its lock entry and keeps the version the environment that holds the
// executable reports. These are pure file reads and need no pipeline run.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemuxManagedToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemuxManagedToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func executable(in environment: String, named name: String) -> URL {
        root.appendingPathComponent("envs/\(environment)/bin/\(name)")
    }

    private func file(_ name: String) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: root.appendingPathComponent(name).path)
    }

    func testTheEnvironmentOfAnExecutableIsTheParentOfItsBinFolder() {
        XCTAssertEqual(
            DemuxManagedTool.environment(ofExecutable: executable(in: "samtools", named: "samtools"))?.path,
            root.appendingPathComponent("envs/samtools").path)
        XCTAssertNil(DemuxManagedTool.environment(ofExecutable: root.appendingPathComponent("samtools")))
        XCTAssertNil(DemuxManagedTool.environment(ofExecutable: root.appendingPathComponent("envs/samtools/samtools")))
    }

    func testAStepRecordsTheVersionOfTheEnvironmentThatHoldsTheExecutable() throws {
        let environment = root.appendingPathComponent("envs/samtools")
        try CondaMetaRecordWriter.write(environment: environment, package: "samtools", version: "1.99", build: "h0_1")
        let tool = DemuxManagedTool(id: "samtools", executable: executable(in: "samtools", named: "samtools"))
        let evidence = ToolVersionEvidence.observed(version: "1.99", reportedLine: "samtools-1.99-h0_1")
        XCTAssertEqual(tool.id, ManagedToolID(rawValue: "samtools"))
        XCTAssertEqual(tool.evidence, evidence)

        let step = tool.step(
            "samtools sort", argv: ["samtools", "sort"], inputs: [file("in.fastq")],
            outputs: [file("out.bam")], wallTimeSeconds: 1.5, stderr: "warning")

        XCTAssertEqual(step.toolName, "samtools sort")
        XCTAssertEqual(step.toolVersion, "1.99")
        XCTAssertEqual(step.managedToolID, ManagedToolID(rawValue: "samtools"))
        XCTAssertEqual(step.toolVersionEvidence, evidence)
        XCTAssertEqual(step.argv, ["samtools", "sort"])
        XCTAssertEqual(step.inputs.map(\.path), [root.appendingPathComponent("in.fastq").path])
        XCTAssertEqual(step.outputs.map(\.path), [root.appendingPathComponent("out.bam").path])
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(step.wallTimeSeconds, 1.5)
        XCTAssertEqual(step.stderr, "warning")
    }

    /// One tool, two steps. Both read the same environment, so both record the same evidence.
    func testTwoStepsOfOneToolShareTheEvidence() throws {
        let environment = root.appendingPathComponent("envs/pysam")
        try CondaMetaRecordWriter.write(environment: environment, package: "pysam", version: "0.99.0", build: "py310h0_1")
        let tool = DemuxManagedTool(id: "pysam", executable: executable(in: "pysam", named: "python"))

        let first = tool.step("pysam retained-read demux filter", argv: [], inputs: [], outputs: [], wallTimeSeconds: 0, stderr: "")
        let second = tool.step("pysam retained-read demux filter", argv: [], inputs: [], outputs: [], wallTimeSeconds: 0, stderr: "")

        XCTAssertEqual(first.toolVersionEvidence, second.toolVersionEvidence)
        XCTAssertEqual(first.toolVersionEvidence, .observed(version: "0.99.0", reportedLine: "pysam-0.99.0-py310h0_1"))
        XCTAssertEqual(first.toolVersion, "0.99.0")
    }

    func testAnExecutableWithNoRecordRecordsTheLockPin() throws {
        let pin = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ManagedToolID(rawValue: "minimap2"))?.version)
        let tool = DemuxManagedTool(id: "minimap2", executable: executable(in: "minimap2", named: "minimap2"))

        XCTAssertEqual(tool.evidence, .lockPin(version: pin, id: ManagedToolID(rawValue: "minimap2")))
        let step = tool.step("minimap2", argv: [], inputs: [], outputs: [], wallTimeSeconds: 0, stderr: "")
        XCTAssertEqual(step.toolVersion, pin)
        XCTAssertEqual(step.managedToolID, ManagedToolID(rawValue: "minimap2"))
    }

    func testAnExecutableOutsideABinFolderRecordsTheLockPin() throws {
        let pin = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ManagedToolID(rawValue: "samtools"))?.version)
        let tool = DemuxManagedTool(id: "samtools", executable: root.appendingPathComponent("samtools"))

        XCTAssertEqual(tool.evidence, .lockPin(version: pin, id: ManagedToolID(rawValue: "samtools")))
    }

    func testAnIdTheLockDoesNotHoldRecordsUnknownAndStillNamesTheTool() {
        let tool = DemuxManagedTool(id: "no-such-tool", executable: executable(in: "no-such-tool", named: "tool"))

        XCTAssertEqual(tool.evidence, .unknown(.noProbe))
        let step = tool.step("tool", argv: [], inputs: [], outputs: [], wallTimeSeconds: 0, stderr: "")
        XCTAssertEqual(step.toolVersion, "unknown")
        XCTAssertEqual(step.managedToolID, ManagedToolID(rawValue: "no-such-tool"))
    }
}
