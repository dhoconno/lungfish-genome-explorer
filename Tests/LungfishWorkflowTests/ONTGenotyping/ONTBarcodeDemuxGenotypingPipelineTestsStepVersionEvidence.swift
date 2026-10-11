// ONTBarcodeDemuxGenotypingPipelineTestsStepVersionEvidence.swift - What the demux genotyping steps record for their tool versions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. The amplicon genotyping run records five kinds of tool step: minimap2, samtools sort,
// samtools merge, samtools index and the pysam retained-read demux filter. Until this lane each one wrote the
// literal `unknown` as its version and named no managed tool. The genotype golden holds 26 such steps in 12
// records. This suite runs the whole pipeline on stand-in tools, reads every record the run wrote and holds
// the steps to what they record.
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

    private func tally(_ steps: [DemuxToolEvidenceFixture.RecordedStep]) -> [String: Int] {
        steps.reduce(into: [:]) { $0[$1.toolName, default: 0] += 1 }
    }

    /// The pin at the base. Every one of the 26 steps records `unknown`, no managed tool and no evidence.
    func testTheFiveManagedToolStepsRecordTheLiteralUnknownAndNoEvidence() async throws {
        let fixture = try DemuxToolEvidenceFixture()
        defer { fixture.cleanup() }
        try await fixture.runCohort()

        let steps = try fixture.managedToolSteps()
        XCTAssertEqual(tally(steps), Self.goldenTally, "\(steps.map { "\($0.file) \($0.toolName)" })")
        XCTAssertEqual(steps.count, 26)
        for recorded in steps {
            XCTAssertEqual(recorded.toolVersion, "unknown", "\(recorded.file) \(recorded.toolName)")
            XCTAssertNil(recorded.managedToolID, "\(recorded.file) \(recorded.toolName)")
            XCTAssertNil(recorded.evidence, "\(recorded.file) \(recorded.toolName)")
        }
    }

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
