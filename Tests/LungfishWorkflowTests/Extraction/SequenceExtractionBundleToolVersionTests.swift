// SequenceExtractionBundleToolVersionTests.swift - What the bgzip and samtools steps of an extracted bundle record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11, landing 4 Handoff 1. The record of an extracted region bundle names the bgzip and
// samtools faidx steps that made its genome. A step used to record the word unknown when the version
// probe failed, which the tool-identity ratchet counts as a fallback. It now records the version the
// way the FASTQ ingestion steps do. A probe that answers is observed. One that does not leaves the
// lock's pin for the tool's id, recorded as a pin and never as a measurement, and the step names the
// tool by that id.

import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SequenceExtractionBundleToolVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "extraction-tool-version")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A runner with no tools in the folders it looks in, so every version probe fails.
    private func runnerWhoseProbesFail() -> NativeToolRunner {
        NativeToolRunner(
            toolsDirectory: root.appendingPathComponent("no-tools", isDirectory: true),
            homeDirectory: root.appendingPathComponent("no-home", isDirectory: true)
        )
    }

    /// A bundle folder whose genome holds the compressed sequence and the two indexes the build leaves.
    private func makeBundleWithCompressedGenome() throws -> URL {
        let bundle = root.appendingPathComponent("Region.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        for name in ["sequence.fa.gz", "sequence.fa.gz.fai", "sequence.fa.gz.gzi"] {
            try Data("stand-in for \(name)".utf8).write(to: genome.appendingPathComponent(name))
        }
        return bundle
    }

    /// A probe that fails leaves the lock's pin for the tool's own id (bgzip is htslib, samtools is
    /// samtools). The step records that version as a pin, names the tool by its id, and never
    /// records the word unknown for a tool the lock pins.
    func testAFailedProbeIsRecordedAsTheLockPinAndNeverAsTheWordUnknown() async throws {
        let runner = runnerWhoseProbesFail()
        let tools: [NativeTool] = [.bgzip, .samtools]
        for tool in tools {
            let probe = await runner.getToolVersion(tool)
            XCTAssertNil(probe, "the stand-in runner has to fail the \(tool) probe, or this test checks nothing")
        }

        let steps = try await SequenceExtractionBundleBuilder(toolRunner: runner).genomeToolSteps(
            bundleURL: try makeBundleWithCompressedGenome(), startedAt: Date(), completedAt: Date()
        )

        XCTAssertEqual(steps.map(\.toolName), ["bgzip", "samtools faidx"])
        for (step, tool) in zip(steps, tools) {
            let id = tool.managedToolID
            let pin = try XCTUnwrap(ManagedToolLock.bundled.entry(id: id)?.version, "the lock pins \(tool)")
            XCTAssertNotEqual(step.toolVersion, "unknown", "\(step.toolName) is not recorded as unknown")
            XCTAssertEqual(step.toolVersion, pin, "\(step.toolName) records the pinned version")
            XCTAssertEqual(step.toolVersionEvidence, .lockPin(version: pin, id: id), "\(step.toolName) is a pin")
            XCTAssertNotEqual(
                step.toolVersionEvidence, .observed(version: pin, reportedLine: nil), "\(step.toolName) is not a measurement"
            )
            XCTAssertEqual(step.managedToolID, id, "\(step.toolName) names its tool by the lock entry")
        }
    }

    /// The step keeps what it ran and what it wrote whatever the probe said.
    func testTheStepsKeepTheirArgvAndTheFilesTheyWrite() async throws {
        let steps = try await SequenceExtractionBundleBuilder(toolRunner: runnerWhoseProbesFail()).genomeToolSteps(
            bundleURL: try makeBundleWithCompressedGenome(), startedAt: Date(), completedAt: Date()
        )

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].argv.first, "bgzip")
        XCTAssertEqual(steps[0].argv.last, "sequence.fa")
        XCTAssertEqual(steps[0].outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["sequence.fa.gz"])
        XCTAssertEqual(steps[1].argv, ["samtools", "faidx", "sequence.fa.gz"])
        XCTAssertEqual(steps[1].inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["sequence.fa.gz"])
        XCTAssertEqual(
            Set(steps[1].outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
            ["sequence.fa.gz.fai", "sequence.fa.gz.gzi"]
        )
    }

    /// A bundle with no compressed genome names neither tool.
    func testABundleWithNoCompressedGenomeRecordsNoToolStep() async throws {
        let bundle = root.appendingPathComponent("Plain.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("genome", isDirectory: true), withIntermediateDirectories: true
        )
        let steps = try await SequenceExtractionBundleBuilder(toolRunner: runnerWhoseProbesFail()).genomeToolSteps(
            bundleURL: bundle, startedAt: Date(), completedAt: Date()
        )
        XCTAssertTrue(steps.isEmpty)
    }
}
