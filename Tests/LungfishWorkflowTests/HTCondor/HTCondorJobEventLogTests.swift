// HTCondorJobEventLogTests.swift - One read of a job's classic event log (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fixtures are real event logs from CHTC's oconnor-ap4000, HTCondor 26.1: K4's slice job of C3 (592727) and lane H
// milestone 2's node jobs of C4 (593368 held and removed, 593370 vacated, run again and removed). See
// Tests/Fixtures/htcondor/README.md.

import XCTest
@testable import LungfishWorkflow

/// The `Tests/Fixtures/htcondor` folder.
enum HTCondorFixtures {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/htcondor", isDirectory: true)

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func text(_ name: String) throws -> String { try String(contentsOf: url(name), encoding: .utf8) }
}

final class HTCondorJobEventLogTests: XCTestCase {
    func testJobEventLogReadsTerminatedUsageOnce() throws {
        let log = try HTCondorJobEventLog.read(HTCondorFixtures.url("k4-job2-z3.log"))

        XCTAssertEqual(log.job, HTCondorJobID(cluster: 592727, process: 0))
        XCTAssertEqual(log.job.description, "592727.0")
        XCTAssertEqual(log.state, .ended(.exited(returnValue: 0)))
        XCTAssertEqual(log.executions.count, 1)
        XCTAssertEqual(log.host, "e4075.chtc.wisc.edu")
        XCTAssertEqual(log.executions.first?.kind, .executing(host: "e4075.chtc.wisc.edu", slotName: "slot1_41@e4075.chtc.wisc.edu"))
        XCTAssertTrue(log.evictions.isEmpty)
        XCTAssertTrue(log.holds.isEmpty)

        // 14:47:55, the 005 time, less 14:45:32, the 001 time.
        XCTAssertEqual(log.wallTimeSeconds, 143)

        // The 005 event's Partitionable Resources table: usage, request and allocation.
        XCTAssertEqual(log.resource("Cpus"), HTCondorResourceUse(name: "Cpus", unit: nil, usage: 1.15, request: 1, allocated: 1))
        XCTAssertEqual(
            log.resource("Disk"),
            HTCondorResourceUse(name: "Disk", unit: "KB", usage: 4_626_536, request: 25_165_824, allocated: 25_165_824)
        )
        XCTAssertEqual(
            log.resource("Memory"),
            HTCondorResourceUse(name: "Memory", unit: "MB", usage: 35, request: 12_288, allocated: 12_288)
        )
        // Rows with empty columns keep each value under its own column.
        XCTAssertEqual(log.resource("GPUs"), HTCondorResourceUse(name: "GPUs", unit: nil, usage: nil, request: nil, allocated: 0))
        XCTAssertEqual(
            log.resource("TimeExecute"),
            HTCondorResourceUse(name: "TimeExecute", unit: "s", usage: 141, request: nil, allocated: nil)
        )
        XCTAssertEqual(log.peakImageSizeKB, 4_794_576)

        // Once: the same log read before its 005 event was written says the job runs on e4075 and names no wall time
        // and no usage. The reader reports what the log holds and never waits for more.
        let text = try HTCondorFixtures.text("k4-job2-z3.log")
        let beforeEnd = try XCTUnwrap(text.components(separatedBy: "\n005 (").first)
        let partial = try HTCondorJobEventLog(text: beforeEnd)
        XCTAssertEqual(partial.state, .running(host: "e4075.chtc.wisc.edu"))
        XCTAssertNil(partial.termination)
        XCTAssertNil(partial.wallTimeSeconds)
        XCTAssertNil(partial.resource("Memory"))
    }

    func testJobEventLogNamesEvictionAndHold() throws {
        let reason = "Cannot expand $$ expression (LgeNoSuchAttribute)."
        let removedByUser = "via condor_rm (by user dhoconno)"

        // Node job (b): a machine-ad macro with no default, held at match before it ran, then removed.
        let held = try HTCondorJobEventLog.read(HTCondorFixtures.url("h2b-hold.log"))
        XCTAssertEqual(held.job, HTCondorJobID(cluster: 593368, process: 0))
        XCTAssertEqual(held.holds.map(\.kind), [.held(reason: reason, code: 0, subcode: 0)])
        XCTAssertTrue(held.executions.isEmpty)
        XCTAssertNil(held.host)
        XCTAssertNil(held.wallTimeSeconds)
        XCTAssertEqual(held.state, .removed(reason: removedByUser))
        // Read before the condor_rm, the same log says held.
        let beforeRemoval = try XCTUnwrap(try HTCondorFixtures.text("h2b-hold.log").components(separatedBy: "\n009 (").first)
        XCTAssertEqual(try HTCondorJobEventLog(text: beforeRemoval).state, .held(reason: reason, code: 0, subcode: 0))

        // Node job (c): vacated on e2475, run again on e4073, removed there.
        let vacated = try HTCondorJobEventLog.read(HTCondorFixtures.url("h2c-vacate.log"))
        XCTAssertEqual(vacated.job, HTCondorJobID(cluster: 593370, process: 0))
        XCTAssertEqual(vacated.executions.map(\.kind), [
            .executing(host: "e2475.chtc.wisc.edu", slotName: "slot1_23@e2475.chtc.wisc.edu"),
            .executing(host: "e4073.chtc.wisc.edu", slotName: "slot1_50@e4073.chtc.wisc.edu"),
        ])
        XCTAssertEqual(
            vacated.evictions.map(\.kind),
            [.evicted(reason: "Job vacated by schedd"), .evicted(reason: removedByUser)]
        )
        XCTAssertEqual(vacated.host, "e4073.chtc.wisc.edu")
        XCTAssertNil(vacated.termination)
        XCTAssertNil(vacated.wallTimeSeconds, "a log with no 005 names no wall time")
        XCTAssertEqual(vacated.state, .removed(reason: removedByUser))
        // The vacate's own table: 247 s of execution on e2475, and the disk the image took.
        let vacate = try XCTUnwrap(vacated.evictions.first)
        XCTAssertEqual(vacate.resources.first { $0.name == "TimeExecute" }?.usage, 247)
        XCTAssertEqual(
            vacate.resources.first { $0.name == "Disk" },
            HTCondorResourceUse(name: "Disk", unit: "KB", usage: 383_202, request: 4_194_304, allocated: 4_194_304)
        )
        // Read between the vacate and the second start, the log says evicted and waiting to run again.
        let text = try HTCondorFixtures.text("h2c-vacate.log")
        let afterVacate = try XCTUnwrap(text.components(separatedBy: "\n040 (593370.000.000) 2026-10-24 11:27:05").first)
        XCTAssertEqual(try HTCondorJobEventLog(text: afterVacate).state, .evicted)
    }

    func testJobEventLogRefusesWhatItCannotRead() throws {
        let text = try HTCondorFixtures.text("k4-job2-z3.log")

        XCTAssertThrowsError(try HTCondorJobEventLog(text: "")) { error in
            XCTAssertEqual(error as? HTCondorJobEventLogError, .noEvents)
        }
        // The old time form, with no year, is refused rather than read as some year.
        let legacy = "001 (592727.000.000) 10/23 14:45:32 Job executing on host: <128.105.69.126:9618>\n...\n"
        XCTAssertThrowsError(try HTCondorJobEventLog(text: legacy)) { error in
            guard case .malformedEvent(line: 1, _)? = error as? HTCondorJobEventLogError else {
                return XCTFail("expected a malformed event on line 1, got \(error)")
            }
        }
        // Each job writes its own log, so a log naming two jobs is refused.
        let other = text.replacingOccurrences(of: "005 (592727.000.000)", with: "005 (592728.000.000)")
        XCTAssertThrowsError(try HTCondorJobEventLog(text: other)) { error in
            XCTAssertEqual(
                error as? HTCondorJobEventLogError,
                .moreThanOneJob(first: HTCondorJobID(cluster: 592727, process: 0), other: HTCondorJobID(cluster: 592728, process: 0))
            )
        }
    }
}
