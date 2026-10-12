// NextflowEngineProcessTests.swift - The shared Nextflow engine on /bin/sh scripts, its log, tail, cancel and hooks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9 M1, panel decisions N5 to N8, W1 and W2, and the inventory's E10. Each case runs
// `NextflowEngineProcess` on a `/bin/sh` script from `EngineScriptRun`. Waits on processes and files
// allow 30 s for the parallel unit tier and end as soon as their condition holds.

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow
import Synchronization
import XCTest

final class NextflowEngineProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-engine")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Settings

    func testEveryNextflowEngineGetsTheFourSecondGraceAndTheDocumentedDefaults() {
        let configuration = NextflowEngineConfiguration(scratchPrefix: "workflow-run-", keepWorkEnvironmentKey: nil, waitsForDocker: true)

        XCTAssertEqual(NextflowEngineProcess.terminationGracePeriod, .seconds(4))
        XCTAssertEqual(configuration.terminationGracePeriod, .seconds(4), "N6, a workflow takes the engine's grace")
        XCTAssertEqual(configuration.logTailLineCount, 200)
        XCTAssertEqual(configuration.tracePollInterval, .seconds(5))
        XCTAssertEqual(NextflowEngineProcess.containerCleanupBound, .milliseconds(1500))
        XCTAssertLessThan(
            NextflowEngineProcess.terminationGracePeriod + NextflowEngineProcess.containerCleanupBound,
            .seconds(6),
            "N5, the grace and the container cleanup end inside the 6 s the GUI gives a cancelled command"
        )
    }

    // MARK: - Log

    func testTheLogHoldsThePreambleThenEachStreamUnderItsHeadingInTodaysBytes() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        echo "N E X T F L O W  ~  version 26.04.6"
        echo "first error" >&2
        echo ""
        printf 'last line with no line break'
        echo "second error" >&2
        """)

        let outcome = try await NextflowEngineProcess(configuration: .forTests())
            .run(run.launch, in: run.scratch, hooks: NextflowEngineHooks())

        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(outcome.logFile, run.launch.logFile)
        XCTAssertEqual(
            run.log(),
            EngineScriptRun.preamble
                + "\n--- stdout ---\n" + "N E X T F L O W  ~  version 26.04.6\nlast line with no line break"
                + "\n--- stderr ---\n" + "first error\nsecond error",
            "the bytes TaxTriage wrote at the end of a run, with blank lines dropped as ProcessManager always did"
        )
        XCTAssertEqual(outcome.stdoutTail, ["N E X T F L O W  ~  version 26.04.6", "last line with no line break"])
        XCTAssertEqual(outcome.stderrTail, ["first error", "second error"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: run.scratch.launchDirectory.path),
            ["work"],
            "the stderr sidecar leaves nothing in the scratch"
        )
    }

    func testEachStdoutLineReachesTheLogBeforeItsHookWhileTheEngineRuns() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        echo "first line"
        echo "an error" >&2
        wait_for release
        echo "second line"
        """)
        let recorder = EngineProgressRecorder(logFile: run.launch.logFile)
        let engine = NextflowEngineProcess(configuration: .forTests())

        let running = Task { try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks(progress: recorder)) }
        let linesSoFar = EngineScriptRun.preamble + "\n--- stdout ---\nfirst line"
        let streamed = await waitUntil(timeout: .seconds(30)) { run.log() == linesSoFar }
        let logWhileRunning = run.log()
        run.release()
        let outcome = try await running.value

        XCTAssertTrue(streamed, "the first line is in the log while the engine waits, so a KILL now leaves it, \(String(describing: logWhileRunning))")
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(
            run.log(),
            linesSoFar + "\nsecond line" + "\n--- stderr ---\nan error",
            "stderr joins the log only once the engine has ended"
        )
        XCTAssertEqual(recorder.lines, ["first line", "second line"], "W1, each stdout line reaches the progress hook, in order")
        XCTAssertEqual(recorder.linesFoundInTheLog, [true, true], "each line is in the log before the hook gets it")
    }

    func testTheOutcomeKeepsTheLastLinesOfEachStreamAndTheLogKeepsThemAll() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        i=1
        while [ "$i" -le 10 ]; do
          echo "out $i"
          echo "err $i" >&2
          i=$((i + 1))
        done
        """)

        let outcome = try await NextflowEngineProcess(configuration: .forTests(logTailLineCount: 3))
            .run(run.launch, in: run.scratch, hooks: NextflowEngineHooks())

        XCTAssertEqual(outcome.stdoutTail, ["out 8", "out 9", "out 10"])
        XCTAssertEqual(outcome.stderrTail, ["err 8", "err 9", "err 10"])
        let every = { (stream: String) in (1...10).map { "\(stream) \($0)" }.joined(separator: "\n") }
        XCTAssertEqual(
            run.log(),
            EngineScriptRun.preamble + "\n--- stdout ---\n" + every("out") + "\n--- stderr ---\n" + every("err"),
            "the tail bounds memory, never the log"
        )
    }

    func testTheLogStaysAtItsFinalNameAndIsCompleteWhenTheRunReturns() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        echo "before the release"
        wait_for release
        echo "after the release"
        echo "an error" >&2
        """)
        let engine = NextflowEngineProcess(configuration: .forTests())

        let running = Task { try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks()) }
        let written = await waitUntil(timeout: .seconds(30)) { run.log()?.hasSuffix("before the release") == true }
        XCTAssertTrue(written, "the engine's first line never reached the log")
        let fileWhileRunning = try Self.fileNumber(of: run.launch.logFile)
        run.release()
        _ = try await running.value

        XCTAssertEqual(try Self.fileNumber(of: run.launch.logFile), fileWhileRunning, "the log is written at its final name, never moved into place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.output.path), ["nextflow.log"], "no temporary file beside the log")
        XCTAssertEqual(
            run.log(),
            EngineScriptRun.preamble + "\n--- stdout ---\nbefore the release\nafter the release\n--- stderr ---\nan error",
            "N8, every byte is in place and synchronized once the run returns, before a step hashes the log"
        )
    }

    func testALaunchThatFailsLeavesTheLauncherErrorInTheLog() async throws {
        let run = try EngineScriptRun.make(in: root, body: "exit 0")
        let launch = NextflowEngineLaunch(
            executable: root.appendingPathComponent("no-such-launcher"),
            arguments: [],
            environment: [:],
            logFile: run.launch.logFile,
            logPreamble: EngineScriptRun.preamble,
            traceFile: nil
        )

        do {
            _ = try await NextflowEngineProcess(configuration: .forTests()).run(launch, in: run.scratch, hooks: NextflowEngineHooks())
            XCTFail("a launch of a missing executable must throw")
        } catch {
            let message = NextflowEngineProcess.launchFailureMessage(for: error)
            XCTAssertTrue(message.hasPrefix("Failed to spawn Nextflow: "), message)
            XCTAssertEqual(
                run.log(),
                EngineScriptRun.preamble + "\n--- launcher error ---\n" + message + "\n",
                "the launcher error part TaxTriage wrote before 2.9"
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.scratch.launchDirectory.path), ["work"])
    }

    // MARK: - Cancel

    func testACancelBeforeTheSpawnLaunchesNothingAndWritesNoLog() async throws {
        let run = try EngineScriptRun.make(in: root, body: "echo started")
        let observed = ObservedRuns()
        let engine = NextflowEngineProcess(configuration: .forTests())

        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcessObservation.$observer.withValue(observed.observer) {
                try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks())
            }
        }.result

        guard case .failure(let error) = outcome else {
            return XCTFail("a run cancelled before its spawn must not return an outcome")
        }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertEqual(observed.count, 0, "E10, no process is built, so none is spawned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.launch.logFile.path), "nothing ran, so no log is written")
    }

    func testACancelStopsTheTreeAfterTheGraceThenStopsTheContainersBeforeItReturns() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        trap 'echo TERM >> "$CONTROL/signals"' TERM
        (
          trap 'echo TERM >> "$CONTROL/child-signals"' TERM
          : > "$CONTROL/child-trapping"
          tick=0
          while [ "$tick" -lt 600 ]; do
            sleep 0.1
            tick=$((tick + 1))
          done
        ) &
        echo $! > "$CONTROL/child.pid"
        wait_for child-trapping
        echo "engine running"
        echo "engine warning" >&2
        echo $$ > "$CONTROL/engine.pid"
        wait_for stop
        """)
        let cleanup = RecordingContainerCleanup()
        let engine = NextflowEngineProcess(configuration: .forTests())

        let running = Task { try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks(cleanup: cleanup)) }
        var enginePID: Int32?
        await waitUntil(timeout: .seconds(30)) {
            enginePID = run.pid("engine.pid")
            return enginePID != nil
        }
        let engineID = try XCTUnwrap(enginePID, "the engine never set its traps")
        let childID = try XCTUnwrap(run.pid("child.pid"))
        cleanup.watch([engineID, childID])

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        running.cancel()
        let outcome = try await running.value
        let waited = clock.now - cancelledAt

        XCTAssertGreaterThanOrEqual(waited, .milliseconds(3500), "N6, the tree has its 4 s grace before KILL")
        XCTAssertLessThan(waited, .seconds(10), "the KILL ends the tree at the grace, \(waited)")
        XCTAssertFalse(
            engineTestProcessIsRunning(engineID) || engineTestProcessIsRunning(childID),
            "no process of the tree outlives the run"
        )
        XCTAssertEqual(outcome.exitCode, SIGKILL, "the engine trapped TERM, so KILL ended it")
        XCTAssertEqual(Set(Self.lines(in: run.root.appendingPathComponent("signals"))), ["TERM"], "the engine gets TERM first")
        XCTAssertEqual(Set(Self.lines(in: run.root.appendingPathComponent("child-signals"))), ["TERM"], "its child gets TERM too")
        XCTAssertEqual(
            cleanup.calls,
            [RecordingContainerCleanup.Call(workDirectory: run.scratch.workDirectory, bound: .milliseconds(1500), treeRunning: false)],
            "N5, the containers of the run's work folder stop once the host tree is gone, within 1.5 s"
        )
        // The shell may add a line to stderr for each `sleep` the TERM ended, after the warning.
        XCTAssertTrue(
            run.log()?.contains("\n--- stdout ---\nengine running\n--- stderr ---\nengine warning") == true,
            "a cancelled run's log is complete too, \(String(describing: run.log()))"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: run.scratch.workDirectory.path),
            "N7, the scratch waits for the caller's record and its finish"
        )
    }

    func testTheContainerCleanupNeverHoldsTheRunPastItsBound() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        echo $$ > "$CONTROL/engine.pid"
        wait_for stop
        """)
        let cleanup = HangingContainerCleanup()
        defer { cleanup.release() }
        let engine = NextflowEngineProcess(configuration: .forTests())

        let running = Task { try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks(cleanup: cleanup)) }
        let started = await waitUntil(timeout: .seconds(30)) { run.pid("engine.pid") != nil }
        XCTAssertTrue(started, "the engine never started")
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        running.cancel()
        _ = try await running.value
        let waited = clock.now - cancelledAt

        XCTAssertTrue(cleanup.wasStarted, "a cancelled run calls the cleanup")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(1400), "the run waits for the cleanup up to its bound")
        XCTAssertLessThan(waited, .seconds(15), "the run never waits past the bound for a cleanup that does not return")
        let cancelled = await waitUntil(timeout: .seconds(30)) { cleanup.wasCancelled }
        XCTAssertTrue(cancelled, "a cleanup still running at the bound is cancelled")
    }

    func testARunThatEndsOnItsOwnStopsNoContainers() async throws {
        let run = try EngineScriptRun.make(in: root, body: "echo done\nexit 3")
        let cleanup = RecordingContainerCleanup()

        let outcome = try await NextflowEngineProcess(configuration: .forTests())
            .run(run.launch, in: run.scratch, hooks: NextflowEngineHooks(cleanup: cleanup))

        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertEqual(cleanup.calls, [], "only a cancelled run stops containers")
    }

    // MARK: - Trace progress

    func testTheTracePollReportsCompletedRowsAndTheLastTaskNameAsTheyArrive() async throws {
        let run = try EngineScriptRun.make(in: root, body: """
        printf 'task_id\\thash\\tnative_id\\tname\\tstatus\\texit\\n' > "$TRACE"
        printf '1\\taa/000001\\t1001\\tNFCORE:FASTQC (S1)\\tCOMPLETED\\t0\\n' >> "$TRACE"
        wait_for release
        printf '2\\taa/000002\\t1002\\tNFCORE:KRAKEN2 (S1)\\tFAILED\\t1\\n' >> "$TRACE"
        printf '3\\taa/000003\\t1003\\tNFCORE:KRAKEN2 (S1)\\tCACHED\\t0\\n' >> "$TRACE"
        printf '4\\taa/000004\\t1004\\tNFCORE:MINIMAP2 (S1)\\tCOMPL' >> "$TRACE"
        """, pollsTrace: true)
        let recorder = EngineProgressRecorder(logFile: run.launch.logFile)
        let engine = NextflowEngineProcess(configuration: .forTests(tracePollInterval: .milliseconds(50)))
        let first = NextflowTraceProgress(completedTasks: 1, lastCompletedName: "NFCORE:FASTQC (S1)")
        let last = NextflowTraceProgress(completedTasks: 2, lastCompletedName: "NFCORE:KRAKEN2 (S1)")

        let running = Task { try await engine.run(run.launch, in: run.scratch, hooks: NextflowEngineHooks(progress: recorder)) }
        let polled = await waitUntil(timeout: .seconds(30)) { recorder.readings.last == first }
        run.release()
        _ = try await running.value
        let readings = recorder.readings

        XCTAssertTrue(polled, "W2, a poll reports the first row while the engine runs, \(readings)")
        XCTAssertEqual(readings.last, last, "the reading after the engine ends counts COMPLETED and CACHED rows, never a FAILED row or one still being written")
        XCTAssertEqual(readings.filter { $0 == first }.count, 1, "a reading reaches the hook only when it changed")
        XCTAssertEqual(readings.map(\.completedTasks), readings.map(\.completedTasks).sorted(), "the count never goes back")
    }

    func testATraceReadingCountsEndedCompletedAndCachedRowsByTheHeadersColumns() {
        XCTAssertNil(NextflowTraceProgress(traceText: ""), "no trace yet")
        XCTAssertNil(NextflowTraceProgress(traceText: "task_id\thash\tname\tstatus"), "a header still being written")
        XCTAssertNil(NextflowTraceProgress(traceText: "task_id\thash\n1\taa/000001\n"), "no name or status column")
        XCTAssertEqual(
            NextflowTraceProgress(traceText: "task_id\tname\tstatus\n"),
            NextflowTraceProgress(completedTasks: 0, lastCompletedName: nil)
        )
        let text = "status\tname\ttask_id\n"
            + "COMPLETED\tA (s1)\t1\n"
            + "ABORTED\tB (s1)\t2\n"
            + "CACHED\tC (s1)\t3\n"
            + "short row\n"
            + "COMPLETED\tD (s1)"
        XCTAssertEqual(
            NextflowTraceProgress(traceText: text),
            NextflowTraceProgress(completedTasks: 2, lastCompletedName: "C (s1)"),
            "columns found by name, an ABORTED or short row skipped, and the row with no line break left for the next reading"
        )
    }

    // MARK: - Helpers

    private static func fileNumber(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func lines(in url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

/// Counts the ToolProcess runs built while its observer is bound.
private final class ObservedRuns: Sendable {
    private let observations = Mutex(0)

    var observer: ToolProcessObserver {
        ToolProcessObserver { _ in self.observations.withLock { $0 += 1 } }
    }

    var count: Int { observations.withLock { $0 } }
}
