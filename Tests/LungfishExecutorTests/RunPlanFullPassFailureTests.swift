// RunPlanFullPassFailureTests.swift - The failure branches of run --plan's statistics and Q20 and Q30 passes (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// QA fix 5 (a) of the K4 part B review: a seqkit that replaces the file its standard output was bound to fails the
    /// statistics step, which keeps no table and no input file, since the record keeps only the bytes the step wrote.
    func testStatisticsStepFailsWhenItsOutputFileIsReplaced() throws {
        var fixture = try RunPlanFixture()
        let bgzip = try fixture.addTool("bgzip", "for a in \"$@\"; do last=\"$a\"; done\ngzip -c < \"$last\"")
        let seqkit = try fixture.addTool(
            "seqkit", "rm -f out/sample.seqkit-stats.tsv\nprintf 'file\\tformat\\n' > out/sample.seqkit-stats.tsv"
        )
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let payload = "out/sample.fastq.gz"
        let settings = noneStorage(.none)
        let plan = try fixture.writePlan([
            PlanStep(
                id: "storage", title: "Store reads", kind: .storage, tool: bgzip, arguments: [], deadlineSeconds: 60,
                inputs: ["inputs/R1.fastq"], outputs: [payload]
            ),
            PlanStep(
                id: "statistics", title: "Compute statistics", kind: .statistics, tool: seqkit,
                arguments: ["stats", "-a", "-T", payload], deadlineSeconds: 60, inputs: [payload], outputs: [],
                standardOutput: "out/sample.seqkit-stats.tsv"
            ),
        ], manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping, pins: [gzip])
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.failedStepID, "statistics")
        let stats = try XCTUnwrap(record.steps.last)
        XCTAssertEqual(stats.outcome, .failed)
        XCTAssertNil(stats.standardOutput)
        XCTAssertNil(stats.inputFile)
        XCTAssertTrue(stats.reason?.hasSuffix("is not the file the step wrote.") == true, stats.reason ?? "")
    }

    /// QA fix 5 (b) of the K4 part B review (BIO N6): a Q20 and Q30 count of a file that cannot be read fails the step
    /// with no counts, ends the run there and starts no later step. The interrupted and deadline branches of the count
    /// loop need a payload that outlasts a signal, so this build does not test them.
    func testQualityCountFailureFailsTheRunWithRecord() throws {
        var fixture = try RunPlanFixture()
        let never = try fixture.addTool("never", "echo never > out/never.txt")
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([
            PlanStep(
                id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
                deadlineSeconds: 60, inputs: ["out/missing.fastq"], outputs: []
            ),
            RunPlanFixture.step("never", never, outputs: ["out/never.txt"]),
        ], manifestPin: manifest.pin, pins: [gzip])
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.failedStepID, "quality-count")
        XCTAssertEqual(record.steps.map(\.id), ["quality-count"])
        let count = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(count.outcome, .failed)
        XCTAssertNil(count.qualityCounts)
        let reason = count.reason ?? ""
        XCTAssertTrue(reason.hasPrefix("The executor could not count the Q20 and Q30 bases of step quality-count."), reason)
        XCTAssertFalse(fixture.exists("out/never.txt"))
    }
}
