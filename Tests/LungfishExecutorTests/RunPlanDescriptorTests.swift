// RunPlanDescriptorTests.swift - run --plan writes each step's logs through descriptors it owns (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// SWIFT fix 5 (b) of the K4 part A review: a link planted at a step's log path refuses the step through the real
    /// binary, and the link's target keeps its bytes (RUNNING-A-TOOL.md, Output into a descriptor you own).
    func testRunPlanRefusesSymlinkedLogPath() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        try FileManager.default.createDirectory(atPath: fixture.planFolder + "/logs", withIntermediateDirectories: true)
        try RunPlanFixture.write("keep", to: fixture.root + "/outside.txt")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.planFolder + "/logs/copy.stdout", withDestinationPath: fixture.root + "/outside.txt"
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "copy")
        XCTAssertEqual(record.steps.first?.outcome, .refused)
        let reason = record.steps.first?.reason ?? ""
        XCTAssertTrue(reason.contains("logs/copy.stdout") && reason.contains("symbolic link"), reason)
        XCTAssertEqual(ExecutorTestSupport.text(fixture.root + "/outside.txt"), "keep")
        XCTAssertFalse(fixture.exists("out/R1.fastq"))
    }

    /// SWIFT fix 6 of the K4 part A review: an executor started with descriptors 0, 1 and 2 closed still gives the tool
    /// its stdout and stderr, since a log descriptor that lands on one of them is moved above 2 before the spawn.
    func testRunPlanWithStandardDescriptorsClosedKeepsTheStepLogs() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        let pid = try ExecutorTestSupport.spawn(
            "/bin/sh",
            ["-c", "exec \"$0\" \"$@\" <&- >&- 2>&-", fixture.binary, "run", "--plan", plan, "--image-manifest", manifest],
            folder: fixture.root, name: "closed"
        )
        let run = try fixture.finish(pid, planPath: plan)
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, "\(run.exit)")
        XCTAssertEqual(fixture.text("logs/copy.stderr"), "copied inputs/R1.fastq\n")
        XCTAssertEqual(run.record?.steps.first?.stderrTail, "copied inputs/R1.fastq\n")
        XCTAssertEqual(fixture.text("out/R1.fastq"), "@r1\nACGT\n+\nIIII\n")
    }
}
