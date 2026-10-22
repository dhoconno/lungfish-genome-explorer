import Foundation
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Signals, grace, the subreaper and the sweep, each through the built binary (lane K3, milestone 2).
///
/// The orphan cases are Linux only, since macOS has no subreaper and an orphan goes to launchd. On macOS the same tests
/// keep the detached process's parent alive, or keep it in the tool's group, and assert the group kill and the walk.
final class ExecutorSignalTests: XCTestCase {
    private typealias Support = ExecutorTestSupport

    /// A shell line that starts `body` in a new session through the executor's probe. On Linux the subshell around it
    /// exits at once, so the session leader is orphaned and re-parents to the executor. On macOS it stays the tool's child.
    private func detached(_ body: String) -> String {
        #if os(Linux)
        return "( \"$EXE\" setsid-exec /bin/sh -c '\(body)' & )"
        #else
        return "\"$EXE\" setsid-exec /bin/sh -c '\(body)' &"
        #endif
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        #if os(Linux)
        return ProcessTable.statusField("PPid", pid: pid).flatMap { pid_t($0) }
        #else
        return Support.parent(of: pid)
        #endif
    }

    func testSIGTERMReachesGroupAndSetsidDescendantThenSIGKILLAfterGrace() throws {
        let folder = try Support.scratchFolder()
        let grandchild = detached(
            "trap \"\" TERM; echo $$ > \"$DIR/g.tmp\"; mv \"$DIR/g.tmp\" \"$DIR/g.pid\"; while :; do sleep 1; done"
        )
        let script = "trap '' TERM; \(grandchild)\necho $$ > \"$DIR/t.tmp\"; mv \"$DIR/t.tmp\" \"$DIR/t.pid\"\nwhile :; do sleep 1; done"
        let executor = try Support.startStep(folder: folder, options: ["--grace", "2"], ["/bin/sh", "-c", script])
        let tool = try Support.pid(in: folder, "t.pid")
        let orphan = try Support.pid(in: folder, "g.pid")
        #if os(Linux)
        // The subshell has exited, so the session leader's parent is the executor, the subreaper.
        XCTAssertTrue(Support.waitUntil(timeout: 5) { self.parentPID(of: orphan) == executor },
                      "PPid \(String(describing: parentPID(of: orphan))), executor \(executor)")
        #else
        XCTAssertEqual(parentPID(of: orphan), tool)
        #endif
        let entry = try XCTUnwrap(ProcessTable.snapshot().first { $0.pid == orphan })
        XCTAssertNotEqual(entry.group, tool, "the detached process left the tool's group")

        let sent = ContinuousClock.now
        XCTAssertEqual(kill(executor, SIGTERM), 0)
        let exit = try XCTUnwrap(Support.waitForExit(executor, timeout: 30))
        let elapsed = StepController.seconds(since: sent)
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.interrupted))
        XCTAssertGreaterThanOrEqual(elapsed, 1.8, "SIGKILL came before the grace")
        XCTAssertLessThan(elapsed, 10)
        let record = try Support.record(in: folder)
        XCTAssertEqual(record.outcome, "interrupted")
        XCTAssertEqual(record.signal, SIGTERM)
        XCTAssertTrue(record.escalatedToSIGKILL)
        XCTAssertTrue(record.stoppedProcesses.contains(orphan), "stopped \(record.stoppedProcesses)")
        XCTAssertTrue(Support.isGone(orphan), "the detached process is still running or a zombie")
        XCTAssertTrue(Support.isGone(tool))
    }

    func testSignalDuringStepWritesCancelledRecordWithinGrace() throws {
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            let folder = try Support.scratchFolder()
            let executor = try Support.startStep(
                folder: folder, options: ["--grace", "10"],
                ["/bin/sh", "-c", "echo $$ > \"$DIR/t.tmp\"; mv \"$DIR/t.tmp\" \"$DIR/t.pid\"; exec /bin/sleep 60"]
            )
            let tool = try Support.pid(in: folder, "t.pid")
            let sent = ContinuousClock.now
            XCTAssertEqual(kill(executor, signal), 0)
            let exit = try XCTUnwrap(Support.waitForExit(executor, timeout: 30), "signal \(signal)")
            XCTAssertLessThan(StepController.seconds(since: sent), 10, "signal \(signal) took past the grace")
            XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.interrupted), "signal \(signal)")
            let record = try Support.record(in: folder)
            XCTAssertEqual(record.outcome, "interrupted")
            XCTAssertEqual(record.signal, signal)
            XCTAssertEqual(record.exitCode, ExecutorExitCode.interrupted)
            XCTAssertFalse(record.escalatedToSIGKILL)
            XCTAssertEqual(record.toolSignal, SIGTERM)
            XCTAssertTrue(Support.isGone(tool))
        }
    }

    func testLingeringDescendantFailsStep() throws {
        let folder = try Support.scratchFolder()
        let body = "echo $$ > \"$DIR/g.tmp\"; mv \"$DIR/g.tmp\" \"$DIR/g.pid\"; while :; do sleep 1; done"
        #if os(Linux)
        let start = detached(body)
        #else
        let start = "( /bin/sh -c '\(body)' & )"
        #endif
        let script = "\(start)\nwhile [ ! -s \"$DIR/g.pid\" ]; do sleep 0.1; done\nexit 0"
        let (exit, record) = try Support.runStep(folder: folder, options: ["--grace", "5"], ["/bin/sh", "-c", script])
        let orphan = try Support.pid(in: folder, "g.pid", timeout: 1)
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertEqual(record.toolExitCode, 0)
        XCTAssertEqual(record.reason, StepReason.lingeringProcess)
        XCTAssertTrue(record.reason?.hasPrefix("A process the tool started was still running after the tool exited.") ?? false)
        XCTAssertTrue(record.stoppedProcesses.contains(orphan), "stopped \(record.stoppedProcesses)")
        XCTAssertTrue(Support.isGone(orphan))
    }

    func testLingeringWriterFailsStepBeforeOutputDigest() throws {
        let folder = try Support.scratchFolder()
        let body = "echo $$ > \"$DIR/g.tmp\"; mv \"$DIR/g.tmp\" \"$DIR/g.pid\"; while :; do echo x >> \"$DIR/out.txt\"; sleep 0.2; done"
        #if os(Linux)
        let start = detached(body)
        #else
        let start = "( /bin/sh -c '\(body)' & )"
        #endif
        let script = "\(start)\nwhile [ ! -s \"$DIR/out.txt\" ]; do sleep 0.1; done\nexit 0"
        let (exit, record) = try Support.runStep(
            folder: folder, options: ["--grace", "5", "--output", "\(folder)/out.txt"], ["/bin/sh", "-c", script]
        )
        let writer = try Support.pid(in: folder, "g.pid", timeout: 1)
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertEqual(record.toolExitCode, 0)
        XCTAssertEqual(record.reason, StepReason.lingeringProcess)
        XCTAssertEqual(record.outputs, [], "a digest was taken of an output still being written")
        XCTAssertTrue(Support.isGone(writer))
        let size = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/out.txt")[.size] as? Int) ?? -1
        usleep(600_000)
        let later = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/out.txt")[.size] as? Int) ?? -1
        XCTAssertEqual(size, later, "something still writes the output")
    }

    func testSweepNeverReapsTrackedChild() throws {
        let folder = try Support.scratchFolder()
        let script = "i=0\nwhile [ $i -lt 10 ]; do \(detached("exit 0"))\ni=$((i+1)); sleep 0.05; done\nsleep 0.5\nexit 7"
        let (exit, record) = try Support.runStep(
            folder: folder, options: ["--sweep-interval-ms", "5"], ["/bin/sh", "-c", script]
        )
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertEqual(record.toolExitCode, 7, "the tool's own exit status reached its wait")
        XCTAssertEqual(record.reason, "The tool exited with status 7.")
        XCTAssertGreaterThan(record.peakResidentBytes ?? 0, 0)
        #if os(Linux)
        XCTAssertEqual(record.adoptedOrphansReaped, 10)
        #else
        XCTAssertEqual(record.adoptedOrphansReaped, 0)
        #endif
    }

    func testRunRecordStatesSubreaperSetOnLinux() throws {
        let folder = try Support.scratchFolder()
        let (exit, record) = try Support.runStep(folder: folder, ["/bin/sh", "-c", "exit 0"])
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.succeeded))
        XCTAssertEqual(record.outcome, "succeeded")
        #if os(Linux)
        XCTAssertEqual(record.subreaper.state, "set")
        XCTAssertEqual(record.subreaper.setterResult, 0)
        XCTAssertEqual(record.subreaper.getterValue, 1)
        XCTAssertEqual(record.orphanSweep, "subreaper")
        #else
        XCTAssertEqual(record.subreaper.state, "unavailable")
        XCTAssertEqual(record.subreaper.setterResultName, "ENOSYS")
        XCTAssertEqual(record.orphanSweep, "parentWalkOnly")
        #endif
    }

    func testStepWallLimitStopsTheTree() throws {
        let folder = try Support.scratchFolder()
        let script = "trap '' TERM; echo $$ > \"$DIR/t.pid\"; while :; do sleep 1; done"
        let (exit, record) = try Support.runStep(
            folder: folder, options: ["--deadline", "1", "--grace", "1"], ["/bin/sh", "-c", script]
        )
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertEqual(record.reason, "The tool ran past its deadline of 1 seconds. The executor stopped it.")
        XCTAssertTrue(record.escalatedToSIGKILL)
        XCTAssertEqual(record.toolSignal, SIGKILL)
        XCTAssertLessThan(record.wallSeconds, 8)
        XCTAssertTrue(Support.isGone(try Support.pid(in: folder, "t.pid", timeout: 1)))
    }

    #if os(Linux)
    func testChildStartsWithEmptySignalMaskAndNullStdin() throws {
        let folder = try Support.scratchFolder()
        let (exit, _) = try Support.runStep(folder: folder, ["/bin/cat", "/proc/self/status"])
        XCTAssertEqual(exit.termination, .exited(code: 0))
        let status = Support.text("\(folder)/tool.out")
        func mask(_ name: String) -> UInt64? {
            status.split(separator: "\n").first { $0.hasPrefix("\(name):") }
                .flatMap { UInt64($0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces), radix: 16) }
        }
        XCTAssertEqual(mask("SigBlk"), 0)
        let ignored = try XCTUnwrap(mask("SigIgn"))
        for signal in ExecutorSpawn.defaultedSignals {
            XCTAssertEqual(ignored & (1 << UInt64(signal - 1)), 0, "signal \(signal) is ignored in the child")
        }
        let second = try Support.scratchFolder()
        _ = try Support.runStep(folder: second, ["/bin/readlink", "/proc/self/fd/0"])
        XCTAssertEqual(Support.text("\(second)/tool.out"), "/dev/null\n")
    }
    #endif
}
