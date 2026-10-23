// RunPlanRecipeCountTests.swift - The read counts run --plan states for each recipe step (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// BIO fix 2 of the K4 part B review (tally K4.1, BIO-r3 R8). Each recipe step states its input and output reads as
    /// integers counted from its files, in the recipe engine's units: the records of one file, the pairs of an R1 and R2
    /// file, and every record of a merged layout's three files. A report beside the reads is not counted, and a gzip file
    /// is read through the gzip the plan pins.
    func testRecipeStepsRecordReadCountsFromTheirFiles() throws {
        var fixture = try RunPlanFixture()
        let read = "@r\\nACGT\\n+\\nIIII\\n"
        let split = try fixture.addTool("fake-split", """
        printf '\(read)\(read)\(read)' > work/a_R1.fastq
        printf '\(read)\(read)\(read)' > work/a_R2.fastq
        echo '{"reads": 99}' > work/a_report.json
        """)
        let merge = try fixture.addTool("fake-merge", """
        printf '\(read)\(read)' | gzip -c > work/m_merged.fq.gz
        printf '\(read)' | gzip -c > work/m_R1.fq.gz
        printf '\(read)' | gzip -c > work/m_R2.fq.gz
        echo '{"reads": 99}' > work/m_report.json
        """)
        let filter = try fixture.addTool("fake-filter", "printf '\(read)' > work/f.fastq")
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        func step(_ id: String, _ tool: PlanToolPin, _ inputs: [String], _ outputs: [String]) -> PlanStep {
            PlanStep(
                id: id, title: "Run \(id)", kind: .recipe, tool: tool, arguments: [], deadlineSeconds: 60,
                inputs: inputs, outputs: outputs
            )
        }
        let plan = try fixture.writePlan([
            step("split", split, ["inputs/R1.fastq"], ["work/a_R1.fastq", "work/a_R2.fastq", "work/a_report.json"]),
            step("merge", merge, ["work/a_R1.fastq", "work/a_R2.fastq"],
                 ["work/m_merged.fq.gz", "work/m_R1.fq.gz", "work/m_R2.fq.gz", "work/m_report.json"]),
            step("filter", filter, ["work/m_merged.fq.gz"], ["work/f.fastq"]),
        ], manifestPin: manifest.pin, pins: [gzip])
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let steps = try XCTUnwrap(run.record?.steps)
        XCTAssertEqual(steps.map(\.id), ["split", "merge", "filter"])
        // split: 1 record in, 3 pairs out. merge: 3 pairs in, 2 merged reads and 1 unmerged pair out (2 + 1 + 1).
        // filter: 2 merged reads in, 1 read out.
        XCTAssertEqual(steps.map(\.inputReadCount), [1, 3, 2])
        XCTAssertEqual(steps.map(\.outputReadCount), [3, 4, 1])
        let reads = fixture.text("logs/gzip.used").split(separator: "\n")
        XCTAssertTrue(reads.contains { $0.hasPrefix("-dc ") && $0.hasSuffix("/work/m_merged.fq.gz") }, reads.joined(separator: "\n"))
    }
}
