// ONTBarcodeDemuxGenotypingPipelineTestsStepVersionEvidence.swift - What the demux genotyping steps record for their tool versions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. The amplicon genotyping run records five kinds of tool step: minimap2, samtools sort,
// samtools merge, samtools index and the pysam retained-read demux filter. Until this lane each one wrote the
// literal `unknown` as its version and named no managed tool. The genotype golden holds 26 such steps in 12
// records. This suite runs the whole pipeline on stand-in tools, reads every record the run wrote and holds
// the steps to what they record now. The pin that held the `unknown` literals at the base is commit 11320cbdb.
//
// A step names its lock entry in `managedToolID` and the version the environment that ran it holds in
// `toolVersionEvidence`. The version is read from the environment's conda-meta after the run, so an
// environment that differs from the lock records its own version, and the lock's pin stands in only for an
// environment that holds no record of the package. The pysam filter step names the pysam package in the
// evidence, because the filter logic is the app's own script and pysam is only the library it imports.
//
// The class name carries `ONTBarcodeDemuxGenotypingPipelineTests`, the hazard suite name the unit tier skips,
// because this suite spawns the same stand-in processes as that suite and has to run serially like it.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTBarcodeDemuxGenotypingPipelineTestsStepVersionEvidence: XCTestCase {
    /// The genotype golden's steps by tool, 26 in all, which a two-sample cohort run reproduces.
    private static let goldenTally: [String: Int] = [
        "minimap2": 6, "samtools sort": 6, "samtools merge": 3, "samtools index": 3,
        "pysam retained-read demux filter": 8,
    ]

    /// The lock entry and conda package of each step name.
    private static let toolOfStep: [String: (id: String, package: String)] = [
        "minimap2": ("minimap2", "minimap2"),
        "samtools sort": ("samtools", "samtools"),
        "samtools merge": ("samtools", "samtools"),
        "samtools index": ("samtools", "samtools"),
        "pysam retained-read demux filter": ("pysam", "pysam"),
    ]

    /// Versions that no lock pins, installed into the stand-in environments by the tests that need them.
    private static let installed: [String: (version: String, build: String)] = [
        "minimap2": ("2.99", "h1111111_0"),
        "samtools": ("1.99", "h2222222_1"),
        "pysam": ("0.99.0", "py310h3333333_1"),
    ]

    private func tally(_ steps: [DemuxToolEvidenceFixture.RecordedStep]) -> [String: Int] {
        steps.reduce(into: [:]) { $0[$1.toolName, default: 0] += 1 }
    }

    private func lockPin(of id: String) throws -> String {
        try XCTUnwrap(ManagedToolLock.bundled.entry(id: ManagedToolID(rawValue: id))?.version, id)
    }

    private func install(_ id: String, into fixture: DemuxToolEvidenceFixture) throws {
        let (version, build) = try XCTUnwrap(Self.installed[id])
        try fixture.writeCondaMeta(environment: id, package: id, version: version, build: build)
    }

    // MARK: - The environment that ran

    /// Every one of the 26 steps records the conda-meta version of its own environment, which is not the
    /// lock's version here, with the package record as the reported line and no host path anywhere.
    func testEveryToolStepRecordsTheCondaMetaVersionOfTheEnvironmentThatRan() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        for id in ["minimap2", "samtools", "pysam"] { try install(id, into: fixture) }
        try await fixture.runCohort()

        let steps = try fixture.managedToolSteps()
        XCTAssertEqual(tally(steps), Self.goldenTally, "\(steps.map { "\($0.file) \($0.toolName)" })")
        XCTAssertEqual(steps.count, 26)
        for recorded in steps {
            let label = "\(recorded.file) \(recorded.toolName)"
            let tool = try XCTUnwrap(Self.toolOfStep[recorded.toolName], label)
            let (version, build) = try XCTUnwrap(Self.installed[tool.id], label)
            XCTAssertNotEqual(version, try lockPin(of: tool.id), "the stand-in environment differs from the lock")
            XCTAssertEqual(recorded.toolVersion, version, label)
            XCTAssertEqual(recorded.managedToolID, tool.id, label)
            let evidence = try XCTUnwrap(recorded.evidence, label)
            XCTAssertEqual(evidence["source"] as? String, "observed", label)
            XCTAssertEqual(evidence["version"] as? String, version, label)
            let line = try XCTUnwrap(evidence["reportedLine"] as? String, label)
            XCTAssertEqual(line, "\(tool.package)-\(version)-\(build)", label)
            XCTAssertFalse(line.contains("/"), "the line holds no path: \(line)")
            XCTAssertFalse(line.contains(fixture.root.path), label)
        }
        // The cohort runs in the Illumina mode, so every tool its steps name is one that kind lists.
        let listed = try XCTUnwrap(AnalysisToolRegistry.descriptor(forRawID: "illumina-amplicon-genotyping")).runsTools
        XCTAssertTrue(Set(steps.compactMap(\.managedToolID)).isSubset(of: Set(listed.map(\.rawValue))))
    }

    /// The pysam filter step names the pysam package as its evidence, because the filter logic is the app's
    /// own script (decision O9).
    func testThePysamFilterStepNamesThePysamPackage() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        try install("pysam", into: fixture)
        try await fixture.runCohort()

        let filterSteps = try fixture.managedToolSteps().filter {
            $0.toolName == "pysam retained-read demux filter"
        }
        XCTAssertEqual(filterSteps.count, Self.goldenTally["pysam retained-read demux filter"])
        for recorded in filterSteps {
            XCTAssertEqual(recorded.managedToolID, "pysam", recorded.file)
            XCTAssertEqual(recorded.evidence?["reportedLine"] as? String, "pysam-0.99.0-py310h3333333_1", recorded.file)
        }
    }

    // MARK: - The lock's pin

    /// An environment with no conda-meta records the lock's pin, as a pin, for each of the 26 steps.
    func testAnEnvironmentWithoutCondaMetaRecordsTheLockPin() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        try await fixture.runCohort()

        let steps = try fixture.managedToolSteps()
        XCTAssertEqual(tally(steps), Self.goldenTally)
        for recorded in steps {
            let label = "\(recorded.file) \(recorded.toolName)"
            let tool = try XCTUnwrap(Self.toolOfStep[recorded.toolName], label)
            let pin = try lockPin(of: tool.id)
            XCTAssertEqual(recorded.toolVersion, pin, label)
            XCTAssertEqual(recorded.managedToolID, tool.id, label)
            XCTAssertEqual(recorded.evidence?["source"] as? String, "lockPin", label)
            XCTAssertEqual(recorded.evidence?["version"] as? String, pin, label)
            XCTAssertEqual(recorded.evidence?["managedToolID"] as? String, tool.id, label)
            XCTAssertNil(recorded.evidence?["reportedLine"], "a pin reports no line: \(label)")
        }
    }

    /// Each tool is read from its own environment. A record in the samtools environment says nothing about
    /// minimap2 or pysam, whose steps keep the lock's pin.
    func testEachToolIsReadFromItsOwnEnvironment() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        try install("samtools", into: fixture)
        try await fixture.runCohort()

        for recorded in try fixture.managedToolSteps() {
            let label = "\(recorded.file) \(recorded.toolName)"
            let tool = try XCTUnwrap(Self.toolOfStep[recorded.toolName], label)
            let source = recorded.evidence?["source"] as? String
            if tool.id == "samtools" {
                XCTAssertEqual(source, "observed", label)
                XCTAssertEqual(recorded.toolVersion, "1.99", label)
            } else {
                XCTAssertEqual(source, "lockPin", label)
                XCTAssertEqual(recorded.toolVersion, try lockPin(of: tool.id), label)
            }
        }
    }

    // MARK: - Unchanged

    /// The legacy dictionary record holds no version key on its tool steps, before and after this lane.
    /// It is a released format, and adding a key would change it (BIO inventory section 5).
    func testTheLegacyRecordToolStepsHoldNoVersionKey() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        try await fixture.runCohort()

        let legacy = try fixture.legacyRecordSteps().filter {
            DemuxToolEvidenceFixture.managedToolStepNames.contains($0["toolName"] as? String ?? "")
        }
        XCTAssertEqual(
            Set(legacy.compactMap { $0["toolName"] as? String }),
            DemuxToolEvidenceFixture.managedToolStepNames,
            "a two-sample cohort runs all five kinds of tool step"
        )
        for step in legacy {
            XCTAssertNil(step["toolVersion"], "\(step["toolName"] ?? "")")
            XCTAssertNil(step["managedToolID"], "\(step["toolName"] ?? "")")
            XCTAssertNil(step["toolVersionEvidence"], "\(step["toolName"] ?? "")")
        }
    }
}
