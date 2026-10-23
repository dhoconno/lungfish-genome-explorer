// RunPlanMergedToMixedTests.swift - The merged-to-mixed step that run --plan runs itself (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// A plan whose first step writes one merged read and one unmerged pair, and whose `interleave` step, with no argv
    /// and `gzip` as its tool, joins the `inputs` it names into `out/mixed.fastq`.
    private func mergedToMixedPlan(_ inputs: [String]) throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let split = try fixture.addTool("split-reads", """
        printf '@m1\\nACGTAC\\n+\\nIIIIII\\n' > out/merged.fastq
        printf '@p1\\nAC\\n+\\nII\\n' > out/R1.fastq
        printf '@p1\\nGT\\n+\\nII\\n' > out/R2.fastq
        """)
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([
            RunPlanFixture.step("split", split, outputs: ["out/merged.fastq", "out/R1.fastq", "out/R2.fastq"]),
            PlanStep(
                id: "interleave", title: "Join merged and unmerged reads", kind: .interleave, tool: gzip, arguments: [],
                deadlineSeconds: 60, inputs: inputs, outputs: ["out/mixed.fastq"]
            ),
        ], manifestPin: manifest.pin)
        return (fixture, plan, manifest.path)
    }

    /// QA fix 4 and BIO fix 2 of the K4 part B review (tally K4.1): the merged-to-mixed step writes the merged read and
    /// then the pair, and its record holds the output's digest, the records written and the mixed-layout counts.
    func testMergedToMixedStepJoinsMergedAndPairedReads() throws {
        let (fixture, plan, manifest) = try mergedToMixedPlan(["out/merged.fastq", "out/R1.fastq", "out/R2.fastq"])
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.id, "interleave")
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        XCTAssertEqual(step.argv, [])
        XCTAssertEqual(step.outputReadCount, 3)
        XCTAssertNil(step.inputReadCount)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/out/mixed.fastq"))
        XCTAssertEqual(step.outputs, [ExecutorStepRecord.Output(
            path: "out/mixed.fastq", bytes: UInt64(bytes.count), sha256: PortableDigest.sha256Hex(of: bytes)
        )])
        XCTAssertEqual(step.storage?.mixedLayout, ExecutorMixedLayoutCounts(mergedReads: 1, pairs: 1, unpairedReads: 0))
        XCTAssertEqual(run.record?.payloads, [])
    }

    /// QA fix 4 of the K4 part B review: a merged-to-mixed step with the merged reads and only one unmerged file fails
    /// with the executor's sentence and writes nothing.
    func testMergedToMixedStepWithOneUnmergedFileFails() throws {
        let (fixture, plan, manifest) = try mergedToMixedPlan(["out/merged.fastq", "out/R1.fastq"])
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        XCTAssertEqual(run.record?.failedStepID, "interleave")
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.reason, "Step interleave needs the merged reads and, when present, both unmerged files.")
        XCTAssertEqual(step.outputs, [])
        XCTAssertFalse(fixture.exists("out/mixed.fastq"))
    }
}
