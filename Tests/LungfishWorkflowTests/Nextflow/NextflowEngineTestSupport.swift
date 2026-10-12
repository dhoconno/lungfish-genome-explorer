// NextflowEngineTestSupport.swift - Scripts, recorders and stubs the Nextflow engine tests share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9 M1. The engine tests run `NextflowEngineProcess` on `/bin/sh` scripts that stand
// in for Nextflow, so they need no managed tool, no Docker and no network.

import Darwin
import Foundation
import LungfishCore
@testable import LungfishWorkflow
import Synchronization

/// One engine run on a `/bin/sh` script, with its own launch folder, work folder and output folder.
/// The script sees `CONTROL`, the run's folder, where a test creates release files, and `TRACE`, the
/// trace file.
struct EngineScriptRun {
    static let preamble = "# Stand-in launch metadata\nlauncher_command: /bin/sh engine.sh\n"

    /// A shell function the scripts use to wait for a release file, giving up with 124 after 30 s.
    static let waitFunction = """
    wait_for() {
      tick=0
      while [ ! -e "$CONTROL/$1" ]; do
        [ "$tick" -ge 600 ] && exit 124
        sleep 0.05
        tick=$((tick + 1))
      done
    }
    """

    let root: URL
    let launch: NextflowEngineLaunch
    let scratch: NextflowEngineScratch

    /// Writes `body` as the engine script in a new folder under `parent`.
    static func make(in parent: URL, body: String, pollsTrace: Bool = false) throws -> EngineScriptRun {
        let root = parent.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let launchDirectory = root.appendingPathComponent("launch", isDirectory: true)
        let workDirectory = launchDirectory.appendingPathComponent("work", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("engine.sh")
        try ("#!/bin/sh\n" + waitFunction + "\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        let trace = output.appendingPathComponent("trace.txt")
        let launch = NextflowEngineLaunch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["PATH": "/usr/bin:/bin", "CONTROL": root.path, "TRACE": trace.path],
            logFile: output.appendingPathComponent("nextflow.log"),
            logPreamble: preamble,
            traceFile: pollsTrace ? trace : nil
        )
        let scratch = NextflowEngineScratch(launchDirectory: launchDirectory, workDirectory: workDirectory, removalRoot: launchDirectory)
        return EngineScriptRun(root: root, launch: launch, scratch: scratch)
    }

    var output: URL { launch.logFile.deletingLastPathComponent() }

    /// Lets a script waiting in `wait_for name` go on.
    func release(_ name: String = "release") {
        FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil)
    }

    /// The log's text, or nil before it exists.
    func log() -> String? {
        try? String(contentsOf: launch.logFile, encoding: .utf8)
    }

    /// The pid a script wrote into the file `name` in its folder, or nil before it did.
    func pid(_ name: String) -> Int32? {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

extension NextflowEngineConfiguration {
    /// The settings an engine test runs with, the defaults unless the case names its own.
    static func forTests(
        terminationGracePeriod: Duration = NextflowEngineProcess.terminationGracePeriod,
        logTailLineCount: Int = 200,
        tracePollInterval: Duration = .seconds(5),
        waitsForDocker: Bool = false,
        keepWorkEnvironmentKey: String? = "LUNGFISH_ENGINE_TEST_KEEP_WORK"
    ) -> NextflowEngineConfiguration {
        NextflowEngineConfiguration(
            scratchPrefix: "nextflow-engine-test-",
            keepWorkEnvironmentKey: keepWorkEnvironmentKey,
            waitsForDocker: waitsForDocker,
            terminationGracePeriod: terminationGracePeriod,
            logTailLineCount: logTailLineCount,
            tracePollInterval: tracePollInterval
        )
    }
}

/// Whether `pid` names a process that has not exited. A zombie only waits to be reaped, so it has exited.
func engineTestProcessIsRunning(_ pid: Int32) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
    return Int32(info.kp_proc.p_stat) != SZOMB
}

/// Records the engine's progress calls, and whether each stdout line was already in the log when the
/// engine handed it over.
final class EngineProgressRecorder: NextflowProgressReporting, Sendable {
    private struct State {
        var lines: [String] = []
        var linesFoundInTheLog: [Bool] = []
        var readings: [NextflowTraceProgress] = []
    }

    private let logFile: URL
    private let state = Mutex(State())

    init(logFile: URL) {
        self.logFile = logFile
    }

    func engineLine(_ line: String) {
        let inTheLog = (try? String(contentsOf: logFile, encoding: .utf8))?.hasSuffix(line) ?? false
        state.withLock {
            $0.lines.append(line)
            $0.linesFoundInTheLog.append(inTheLog)
        }
    }

    func traceProgress(_ progress: NextflowTraceProgress) {
        state.withLock { $0.readings.append(progress) }
    }

    var lines: [String] { state.withLock { $0.lines } }
    var linesFoundInTheLog: [Bool] { state.withLock { $0.linesFoundInTheLog } }
    var readings: [NextflowTraceProgress] { state.withLock { $0.readings } }
}

/// Records each container cleanup call with whether a watched process still ran at that moment.
final class RecordingContainerCleanup: NextflowContainerCleanup, Sendable {
    struct Call: Sendable, Equatable {
        let workDirectory: URL
        let bound: Duration
        let treeRunning: Bool
    }

    private let watched = Mutex<[Int32]>([])
    private let recorded = Mutex<[Call]>([])

    /// The processes whose state each call records.
    func watch(_ pids: [Int32]) {
        watched.withLock { $0 = pids }
    }

    func stopContainers(boundTo workDirectory: URL, within bound: Duration) async {
        let pids = watched.withLock { $0 }
        let treeRunning = pids.contains { engineTestProcessIsRunning($0) }
        recorded.withLock { $0.append(Call(workDirectory: workDirectory, bound: bound, treeRunning: treeRunning)) }
    }

    var calls: [Call] { recorded.withLock { $0 } }
}

/// A container cleanup that never returns on its own, and records the cancel the engine sends it.
final class HangingContainerCleanup: NextflowContainerCleanup, Sendable {
    private let released = NextflowOneShotSignal()
    private let started = Mutex(false)
    private let sawCancel = Mutex(false)

    func stopContainers(boundTo workDirectory: URL, within bound: Duration) async {
        started.withLock { $0 = true }
        await withTaskCancellationHandler {
            await released.wait()
        } onCancel: {
            sawCancel.withLock { $0 = true }
        }
    }

    /// Lets the cleanup return, so no task outlives the case.
    func release() {
        released.fire()
    }

    var wasStarted: Bool { started.withLock { $0 } }
    var wasCancelled: Bool { sawCancel.withLock { $0 } }
}

/// A Docker probe that answers from a script of reachable flags, the last one repeating, and counts
/// how often it is asked.
final class ScriptedDockerProbe: ContainerRuntimeProbing, Sendable {
    private let answers: [Bool]
    private let queries = Mutex(0)

    init(answers: [Bool]) {
        self.answers = answers
    }

    var daemonQueries: Int { queries.withLock { $0 } }

    func dockerCLIPath() -> String? { "/usr/local/bin/docker" }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        let index = queries.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        let reachable = answers.isEmpty ? false : answers[min(index, answers.count - 1)]
        return DockerDaemonProbe(
            reachable: reachable,
            clientVersion: "28.3.2",
            serverVersion: reachable ? "28.3.2" : nil,
            detail: reachable ? nil : "Cannot connect to the Docker daemon"
        )
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }
}

/// Collects the progress a Docker wait reports.
final class ProgressMessages: Sendable {
    private let messages = Mutex<[String]>([])

    var report: @Sendable (Double, String) -> Void {
        { fraction, message in self.messages.withLock { $0.append("\(fraction) \(message)") } }
    }

    var all: [String] { messages.withLock { $0 } }
}
