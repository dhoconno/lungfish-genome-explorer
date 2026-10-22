import Foundation
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Spawn, wait and descriptors of the executor's launcher, and the peak memory it records (lane K3, milestones 1 and 3).
final class ExecutorLaunchTests: XCTestCase {
    private typealias Support = ExecutorTestSupport

    func testChildSeesOnlyStandardDescriptors() throws {
        let folder = try Support.scratchFolder()
        let binary = try Support.executorBinary()
        FileManager.default.createFile(atPath: "\(folder)/leak.txt", contents: Data("x".utf8))

        // In process: a descriptor opened without O_CLOEXEC is marked by the start-up sweep and never reaches a child.
        let leakedBeforeSweep = open("\(folder)/leak.txt", O_RDONLY)
        XCTAssertGreaterThanOrEqual(leakedBeforeSweep, 3)
        defer { close(leakedBeforeSweep) }
        XCTAssertGreaterThanOrEqual(ExecutorSpawn.markInheritedDescriptorsCloseOnExec(), 1)
        let probe = try Support.spawn(binary, ["list-fds"], folder: folder, name: "probe")
        XCTAssertEqual(Support.waitForExit(probe, timeout: 30)?.termination, .exited(code: 0))
        XCTAssertEqual(Support.text("\(folder)/probe.out").trimmingCharacters(in: .newlines), "0 1 2")

        // Through the binary: a descriptor the executor inherits stays out of its tool, as do the files it opened.
        let leakedToExecutor = open("\(folder)/leak.txt", O_RDONLY)
        XCTAssertGreaterThanOrEqual(leakedToExecutor, 3)
        defer { close(leakedToExecutor) }
        let (exit, record) = try Support.runStep(folder: folder, [binary, "list-fds"])
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.succeeded))
        XCTAssertEqual(record.outcome, "succeeded")
        XCTAssertEqual(Support.text("\(folder)/tool.out").trimmingCharacters(in: .newlines), "0 1 2")
    }

    func testChildStdinReadsEndOfFile() throws {
        let folder = try Support.scratchFolder()
        let (exit, record) = try Support.runStep(folder: folder, timeout: 20, ["/bin/cat"])
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.succeeded))
        XCTAssertEqual(record.toolExitCode, 0)
        XCTAssertEqual(Support.text("\(folder)/tool.out"), "")
    }

    func testChildEnvironmentIsTheStepEnvironmentOnly() throws {
        let folder = try Support.scratchFolder()
        let binary = try Support.executorBinary()
        let arguments = ["step", "--record", "\(folder)/record.json", "--stdout", "\(folder)/tool.out",
                         "--stderr", "\(folder)/tool.err", "--env", "ONLY=1", "--", "/usr/bin/env"]
        let pid = try Support.spawn(binary, arguments, folder: folder, name: "executor")
        XCTAssertEqual(Support.waitForExit(pid, timeout: 30)?.termination, .exited(code: 0))
        XCTAssertEqual(Support.text("\(folder)/tool.out"), "ONLY=1\n")
        XCTAssertEqual(try Support.record(in: folder).environmentNames, ["ONLY"])
    }

    func testNonzeroExitIsRecordedAsStepFailure() throws {
        let folder = try Support.scratchFolder()
        let (exit, record) = try Support.runStep(folder: folder, ["/bin/sh", "-c", "exit 7"])
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertEqual(record.toolExitCode, 7)
        XCTAssertEqual(record.reason, "The tool exited with status 7.")
        XCTAssertNotNil(record.peakResidentBytes)
    }

    func testRefusedRunHasItsOwnExitCodeAndStartsNoTool() throws {
        let folder = try Support.scratchFolder()
        let (exit, record) = try Support.runStep(
            folder: folder, options: ["--grace", "121"], ["/bin/sh", "-c", "echo ran > \"$DIR/ran\""]
        )
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.refused))
        XCTAssertNotEqual(ExecutorExitCode.refused, ExecutorExitCode.failed)
        XCTAssertNotEqual(ExecutorExitCode.refused, ExecutorExitCode.interrupted)
        XCTAssertEqual(record.outcome, "refused")
        XCTAssertEqual(record.reason, "The grace of 121 seconds is outside 0 to 120 seconds. No tool ran.")
        XCTAssertNil(record.toolPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(folder)/ran"))
    }

    func testChildSubreaperWrapperReportsENOSYSOffLinux() {
        #if os(Linux)
        // The test process never calls the setter (tally-r2 K3-1), so the getter reads 0 here.
        let getter = ChildSubreaper.get()
        XCTAssertEqual(getter.result, 0)
        XCTAssertEqual(getter.value, 0)
        #else
        XCTAssertEqual(ChildSubreaper.set(), ENOSYS)
        XCTAssertEqual(ChildSubreaper.get().result, ENOSYS)
        XCTAssertNil(ChildSubreaper.get().value)
        XCTAssertEqual(ChildSubreaper.errnoName(ENOSYS), "ENOSYS")
        #endif
    }

    func testProcessTableParsesStatAfterLastParenthesis() throws {
        let root = try Support.scratchFolder()
        let stats = [
            "100": "100 (sh) S 1 100 100 0 -1",
            "101": "101 (a) b (c)) R 100 100 100 0 -1",
            "102": "102 (bgzip) Z 101 100 100 0 -1",
            "103": "103 (java) S 1 103 103 0 -1",
            "104": "104 (orphan) S 1 100 7 0 -1",
            "self": "999 (x) S 1 1 1",
        ]
        for (name, line) in stats {
            try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true)
            try Data(line.utf8).write(to: URL(fileURLWithPath: "\(root)/\(name)/stat"))
        }
        let entries = ProcessTable.snapshot(procRoot: root)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.first { $0.pid == 101 }, ProcessEntry(pid: 101, parent: 100, group: 100, state: "R"))
        // 102 is a zombie, 103 is not under 100, and 104 left 100's tree but not its group.
        let live = ProcessTable.liveDescendants(of: 100, groups: [100], in: entries).map(\.pid)
        XCTAssertEqual(live, [101, 104])
        XCTAssertEqual(ProcessTable.liveDescendants(of: 100, groups: [], in: entries).map(\.pid), [101])
    }

    func testPeakResidentBytesMatchTouchedAllocation() throws {
        let folder = try Support.scratchFolder()
        let pid = try Support.spawn(try Support.executorBinary(), ["touch-memory", "256"], folder: folder, name: "touch")
        let exit = try XCTUnwrap(Support.waitForExit(pid, timeout: 60))
        XCTAssertEqual(exit.termination, .exited(code: 0))
        let target = Double(256 << 20)
        let peak = Double(exit.peakResidentBytes)
        XCTAssertGreaterThan(peak, target * 0.85, "peak \(exit.peakResidentBytes) bytes")
        XCTAssertLessThan(peak, target * 1.15, "peak \(exit.peakResidentBytes) bytes")

        // The launcher's own reap records the same figure in the step record.
        let (stepExit, record) = try Support.runStep(folder: folder, [try Support.executorBinary(), "touch-memory", "256"])
        XCTAssertEqual(stepExit.termination, .exited(code: 0))
        let recorded = Double(try XCTUnwrap(record.peakResidentBytes))
        XCTAssertGreaterThan(recorded, target * 0.85, "recorded \(recorded) bytes")
        XCTAssertLessThan(recorded, target * 1.15, "recorded \(recorded) bytes")
    }
}
