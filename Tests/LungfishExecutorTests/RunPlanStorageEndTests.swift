// RunPlanStorageEndTests.swift - How a storage launch of run --plan ends: deadline, SIGTERM, failure, memory (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension RunPlanTests {
    /// The storage step's launches as `run-record.json` holds them, read as JSON objects, so a test reads each key by the
    /// name the record writes.
    static func storageLaunches(in fixture: RunPlanFixture) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/" + ExecutorRunRecord.fileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        let storage = try XCTUnwrap(steps.first?["storage"] as? [String: Any])
        return try XCTUnwrap(storage["launches"] as? [[String: Any]])
    }

    /// The tool id of each launch, in the order the step started them.
    static func toolIDs(of launches: [[String: Any]]) -> [String] {
        launches.map { ($0["tool"] as? [String: Any])?["id"] as? String ?? "" }
    }

    /// A clumpify that prints the heap line, writes its PID to tmp/ by rename (the step keeps no declared output when it
    /// fails) and then sleeps for `seconds`.
    static func hangingClumpify(seconds: Int) -> String {
        "echo 'java.lang.OutOfMemoryError: Java heap space' >&2\necho $$ > tmp/pid.tmp\nmv tmp/pid.tmp tmp/pid.txt\nsleep \(seconds)"
    }

    /// SWIFT fix 3 (a) and QA fix 2 of the K4 part B review (tally-r2 K4-06, K4-09): a clumpify that never exits is
    /// stopped at the plan's deadline. The step and its clumpify launch keep the controller's deadline sentence, the step
    /// keeps no payload, and nothing is left running. BBTools' `bgzip -h` probe (BIO N3, fix B2) runs first within the
    /// same deadline and succeeds, so the step's 2 seconds leave the probe room on a loaded host.
    func testClumpifyHangEndsAtPlanDeadlineWithFailedRecord() throws {
        let (fixture, plan, manifest) = try clumpifyPlan(Self.hangingClumpify(seconds: 30), deadline: 2)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "storage")
        XCTAssertLessThan(record.wallSeconds, 20)
        XCTAssertEqual(record.payloads, [])
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.outputs, [])
        XCTAssertNil(step.outputReadCount)
        XCTAssertTrue(step.stderrTail.contains("java.lang.OutOfMemoryError: Java heap space"), step.stderrTail)
        let launches = try Self.storageLaunches(in: fixture)
        XCTAssertEqual(Self.toolIDs(of: launches), ["bgzip", "clumpify.sh"])
        XCTAssertEqual(step.storage?.launches?.first?.outcome, .succeeded)
        XCTAssertNil(step.storage?.launches?.first?.reason)
        let clumpify = try XCTUnwrap(launches.last)
        XCTAssertTrue(clumpify["toolSignal"] != nil || (clumpify["toolExitCode"] as? Int ?? 0) != 0)
        // The launch's deadline is what was left of the step's 2 seconds when it started (K2 review O-1).
        let launchReason = clumpify["reason"] as? String ?? ""
        let lead = "The tool ran past its deadline of "
        XCTAssertTrue(launchReason.hasPrefix(lead) && launchReason.hasSuffix(" seconds. The executor stopped it."), launchReason)
        let seconds = Double(launchReason.dropFirst(lead.count).prefix { $0 != " " }) ?? .infinity
        XCTAssertLessThanOrEqual(seconds, 2, launchReason)
        XCTAssertNotNil(clumpify["escalatedToSIGKILL"] as? Bool)
        XCTAssertNotNil(clumpify["stoppedProcesses"] as? [Any])
        let reason = step.reason ?? ""
        XCTAssertTrue(reason.hasPrefix(launchReason + " The storage step failed."), reason)
        let toolPID = try ExecutorTestSupport.pid(in: fixture.planFolder + "/tmp", "pid.txt", timeout: 1)
        XCTAssertTrue(ExecutorTestSupport.isGone(toolPID, timeout: 10), "the tool \(toolPID) is still running")
    }

    /// SWIFT fix 3 (b) and QA fix 3 of the K4 part B review: SIGTERM during a storage launch crosses the thread and
    /// semaphore bridge to the controller, ends the run as interrupted at the storage step and leaves no tool and no
    /// temporary record. The step keeps BBTools' `bgzip -h` probe and the one clumpify launch the signal ended.
    func testStorageStepSIGTERMWritesInterruptedRecordAndLeavesNoProcess() throws {
        let (fixture, plan, manifest) = try clumpifyPlan(Self.hangingClumpify(seconds: 60))
        let pid = try fixture.start(plan, ["--image-manifest", manifest])
        let toolPID: pid_t
        do {
            toolPID = try ExecutorTestSupport.pid(in: fixture.planFolder + "/tmp", "pid.txt", timeout: 30)
        } catch {
            kill(pid, SIGKILL)
            _ = ExecutorTestSupport.waitForExit(pid, timeout: 10)
            throw error
        }
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        let run = try fixture.finish(pid, planPath: plan, timeout: 30)
        XCTAssertEqual(run.status, ExecutorExitCode.interrupted, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .interrupted)
        XCTAssertEqual(record.signal, SIGTERM)
        XCTAssertEqual(record.failedStepID, "storage")
        XCTAssertEqual(record.payloads, [])
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .interrupted)
        XCTAssertEqual(step.outputs, [])
        XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["bgzip", "clumpify.sh"])
        XCTAssertTrue(ExecutorTestSupport.isGone(toolPID, timeout: 10), "the tool \(toolPID) is still running")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.planFolder)
            .filter { $0.hasPrefix(".run-record.json.tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    /// SWIFT fix 3 (c) of the K4 part B review (ruling N8): a storage failure whose stderr names a file by its absolute
    /// path in the work root states that path relative to the work root in the step's and the run's reasons.
    func testStorageFailureReasonHoldsNoWorkRootPath() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("echo \"$PWD/inputs/R1.fastq: no such file\" >&2\nexit 1")
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertTrue(step.stderrTail.contains("/inputs/R1.fastq: no such file"), step.stderrTail)
        for reason in [step.reason ?? "", record.reason ?? ""] {
            XCTAssertTrue(reason.contains(" inputs/R1.fastq: no such file"), reason)
            XCTAssertFalse(reason.contains(fixture.planFolder), reason)
        }
    }

    /// QA fix 2 of the K4 part B review, the ruling's first case: a clumpify that exits 1 after printing the heap lines
    /// fails the step with those lines. After BBTools' `bgzip -h` probe the step holds one clumpify launch, so no other
    /// route stores the reads.
    func testClumpifyExitOneWithHeapLinesFailsWithoutFallback() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("""
        echo 'java.lang.OutOfMemoryError: Java heap space' >&2
        echo 'Terminating due to java.lang.OutOfMemoryError: Java heap space' >&2
        exit 1
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.payloads, [])
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.outputs, [])
        XCTAssertEqual(step.toolExitCode, 1)
        XCTAssertTrue(step.stderrTail.contains("Terminating due to java.lang.OutOfMemoryError: Java heap space"), step.stderrTail)
        XCTAssertTrue(step.reason?.hasPrefix("The storage step failed.") == true, step.reason ?? "")
        XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["bgzip", "clumpify.sh"])
        XCTAssertEqual(step.storage?.launches?.first?.argv.last, "-h")
    }

    /// BIO fix 4 of the K4 part B review (tally K4.2): the storage step states the peak resident memory of its
    /// launches, and each launch states its own.
    func testStorageStepRecordsPeakMemoryOfItsLaunches() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("""
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        gzip -c < "$IN" > "$OUT"
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.first)
        let peak = try XCTUnwrap(step.peakResidentBytes)
        XCTAssertGreaterThan(peak, 0)
        let launches = try Self.storageLaunches(in: fixture)
        XCTAssertEqual(launches.compactMap { ($0["peakResidentBytes"] as? Int).map(UInt64.init) }.max(), peak)
    }
}
