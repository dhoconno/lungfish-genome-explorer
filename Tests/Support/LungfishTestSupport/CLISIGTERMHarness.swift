// CLISIGTERMHarness.swift - Launches lungfish-cli, sends SIGTERM and checks how the command stopped
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane S30, decision G1 (docs/plans/2026-10-13-phase-2-10.md). The app cancels a CLI route
// with SIGTERM and gives the command a 6-second grace before SIGKILL (2.9 N6). A command that
// converts SIGTERM into a cancel exits 125 inside that grace, has written its `cancelled` record by
// then, and leaves no process of its tree running. The CLI suites check those three facts here, and
// the cancel check of Q30's route parity harness calls the same assertions.

import Darwin
import Foundation
import LungfishCore
import XCTest

/// The SIGTERM cancel check of a command that a GUI route launches.
///
/// A test starts the built `lungfish-cli` with ``launchCLI(_:environment:workingDirectory:testClass:)``,
/// waits until the command is doing its work, then calls ``assertSIGTERMCancels(_:within:record:isolation:file:line:)``,
/// which sends one SIGTERM to the CLI alone and asserts the exit status, the record and the tree.
/// Each part is public on its own, so a caller that cancels through the app's transport instead
/// asserts what it observed with ``assertCancelledExit(status:elapsed:within:detail:file:line:)``,
/// ``assertRecordCancelled(_:file:line:)`` and ``assertNoProcessLeft(_:timeout:file:line:)``,
/// with ``processTree(of:)`` read before its cancel.
public enum CLISIGTERMHarness {
    /// `CLIExitCode.cancelled`, the status of a command that stopped on a cancel.
    public static let cancelledExitStatus: Int32 = 125

    /// The status a command's record holds once a cancel stopped its run.
    public static let cancelledRecordStatus = "cancelled"

    /// The time the app's CLI routes give a command between SIGTERM and SIGKILL,
    /// `CLIProcessLauncher.operationGrace` (2.9 N6). The command must exit, its record written,
    /// inside it. LungfishTestSupport stays free of LungfishKit, so the value is repeated here,
    /// and a caller that imports LungfishKit may pass the launcher's own value as `within`.
    public static let operationGrace: Duration = .seconds(6)

    /// How long a check waits for a process to start or leave and for a file to appear. Each wait
    /// returns as soon as its condition holds.
    public static let processWait: Duration = .seconds(30)

    // MARK: - Launching

    /// The `lungfish-cli` the test runner injected, or the one built beside the test bundle of
    /// `testClass`, or nil when there is neither.
    public static func cliBinaryURL(for testClass: AnyClass) -> URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: testClass).bundleURL.deletingLastPathComponent()
        )
    }

    /// This process's environment with `overrides` laid over it, without the variables of an IDE
    /// test session. A child is a plain process and must not join that session.
    public static func childEnvironment(overriding overrides: [String: String] = [:]) -> [String: String] {
        ProcessInfo.processInfo.environment
            .filter { key, value in
                !(key.hasPrefix("XCTest") || key.hasPrefix("XCInject")
                    || (key == "DYLD_INSERT_LIBRARIES" && value.contains("XCTest")))
            }
            .merging(overrides) { _, override in override }
    }

    /// Starts the built `lungfish-cli` with `arguments`, its environment from
    /// ``childEnvironment(overriding:)`` with `environment` laid over it.
    ///
    /// - Throws: `XCTSkip` when no CLI was built, or the launch error.
    public static func launchCLI(
        _ arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        testClass: AnyClass
    ) throws -> Run {
        guard let cli = cliBinaryURL(for: testClass) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        return try launch(
            executableURL: cli,
            arguments: arguments,
            environment: childEnvironment(overriding: environment),
            workingDirectory: workingDirectory
        )
    }

    /// Starts any program on ``ToolProcess``, in its own process group, with exactly `environment`.
    /// A test whose child is not the CLI, such as an xctest child, starts it here.
    ///
    /// - Throws: The launch error, when nothing started.
    public static func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil
    ) throws -> Run {
        let spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminationGracePeriod: .seconds(2),
            // ToolProcess ends a descendant that still holds the output once this grace runs out,
            // which would hide a process the command left. It outlasts the wait for the tree, so
            // the harness finds such a process first.
            drainGracePeriod: processWait + .seconds(10),
            label: "sigterm-harness-\(executableURL.lastPathComponent)"
        )
        let run = try ToolProcess.start(spec)
        guard let pid = run.pid else {
            // Nothing started, so the run is already over and its error says why.
            _ = try run.waitBlocking()
            throw ToolProcessError.launchFailed(label: spec.label, reason: "no process started", results: [])
        }
        return Run(processIdentifier: pid, run: run)
    }

    /// Starts `count` CPU burners for a test that needs every core busy.
    ///
    /// Each burner is a `/bin/sh` loop that spins while the process `pid` exists and ends by itself within one
    /// loop turn once that process is gone. A burner whose loop never tests anything ends only when its test
    /// stops it, so a test process that dies first, by a crash or by a gate's kill, leaves it spinning for good
    /// (the 29 orphans of the unit tier at H). A test still stops the returned runs in a `defer`, which ends the
    /// burners at the end of the test and not at the end of the process.
    ///
    /// - Parameters:
    ///   - count: How many burners to start.
    ///   - pid: The process the burners live and die with, this process unless a test names another.
    /// - Throws: The launch error, with the burners already started stopped first, or a `launchFailed` error
    ///   when `pid` is not a process a burner can follow, since `kill -0 0` always succeeds.
    public static func launchBurners(
        count: Int,
        whileRunning pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> [Run] {
        guard pid > 1 else {
            throw ToolProcessError.launchFailed(
                label: "sigterm-harness-burner", reason: "\(pid) is not a process a burner can follow", results: []
            )
        }
        var burners: [Run] = []
        do {
            for _ in 0..<count {
                let burner = try launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "while kill -0 \(pid) 2>/dev/null; do :; done"],
                    environment: [:]
                )
                burners.append(burner)
            }
        } catch {
            burners.forEach { $0.stop() }
            throw error
        }
        return burners
    }

    /// Sends one SIGTERM to `run` alone, as `kill <pid>` does, waits up to `timeout` for it to
    /// exit, and then up to `timeout` for the rest of its tree to go. The tree is read just before
    /// the signal, so it holds every process the run had started. A process of the tree that still
    /// runs after the second wait, or every one that runs when the run itself does not exit, is
    /// recorded in ``Stop/left`` and killed.
    public static func cancel(_ run: Run, timeout: Duration = processWait) async -> Stop {
        let tree = processTree(of: run.processIdentifier)
        let sent = run.sendSIGTERM()
        let exited = await waitUntil(timeout: timeout, pollInterval: .milliseconds(10)) { !run.isRunning }
        guard exited else {
            // The command ignored the signal. Record the tree that still runs and kill it, so
            // the tree check fails beside the exit check and the test leaves nothing behind.
            let stillRunning = tree.filter { !hasExited($0) }
            for pid in stillRunning {
                kill(pid, SIGKILL)
            }
            run.stop()
            return Stop(
                tree: tree, left: stillRunning, outputHeldOpen: false, termination: nil, elapsed: nil,
                standardOutput: "", standardError: ""
            )
        }
        let elapsed = ContinuousClock.now - sent
        // Read before the result, which waits while a process the command left holds its output.
        let left = await processesLeft(tree, timeout: timeout)
        let result = await run.result()
        return Stop(
            tree: tree,
            left: left,
            outputHeldOpen: result?.outputDrainTimedOut ?? false,
            termination: result?.termination,
            elapsed: elapsed,
            standardOutput: result?.stdoutText ?? "",
            standardError: result?.stderrText ?? ""
        )
    }

    /// Waits up to `timeout` for every process in `processes` to exit, then kills each one that
    /// still runs and returns them, so a failing test leaves nothing behind.
    static func processesLeft(_ processes: [Int32], timeout: Duration) async -> [Int32] {
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            processes.allSatisfy(hasExited)
        }
        let left = processes.filter { !hasExited($0) }
        for pid in left {
            kill(pid, SIGKILL)
        }
        return left
    }

    /// Whether `pid` has exited, an unreaped zombie included. The kernel's process table reports
    /// a zombie's state, which libproc cannot read, and ToolProcess keeps a leader unreaped while
    /// a descendant still holds its output.
    static func hasExited(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return !ProcessTreeTerminator.processExists(pid: pid)
        }
        return size == 0 || Int32(info.kp_proc.p_stat) == SZOMB
    }

    // MARK: - Waiting and reading the tree

    /// The process `pid` and every descendant of it now.
    public static func processTree(of pid: Int32) -> [Int32] {
        [pid] + ProcessTreeTerminator.descendantProcessIDs(of: pid)
    }

    /// Waits until `file` exists.
    @discardableResult
    public static func waitForFile(_ file: URL, timeout: Duration = processWait) async -> Bool {
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// Waits until `file` holds a process ID, as a stand-in tool writes `$$` to it, and returns it.
    public static func waitForProcessID(in file: URL, timeout: Duration = processWait) async -> Int32? {
        var pid: Int32?
        await waitUntil(timeout: timeout, pollInterval: .milliseconds(20)) {
            pid = (try? String(contentsOf: file, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return pid
    }
}

// MARK: - A run and how it stopped

extension CLISIGTERMHarness {
    /// One process the harness started.
    public final class Run: Sendable {
        /// The ID of the started process.
        public let processIdentifier: Int32
        private let run: ToolProcessRun

        init(processIdentifier: Int32, run: ToolProcessRun) {
            self.processIdentifier = processIdentifier
            self.run = run
        }

        /// Whether the process has not exited. A zombie counts as exited.
        public var isRunning: Bool {
            !CLISIGTERMHarness.hasExited(processIdentifier)
        }

        /// Sends SIGTERM to this process alone and returns when it was sent.
        @discardableResult
        public func sendSIGTERM() -> ContinuousClock.Instant {
            let sent = ContinuousClock.now
            kill(processIdentifier, SIGTERM)
            return sent
        }

        /// Stops the process and its tree if they still run, for a test's teardown. It returns at once.
        public func stop() {
            run.cancel()
        }

        /// The result once the run is over, nil when ToolProcess reports none.
        func result() async -> ToolProcessResult? {
            do throws(ToolProcessError) {
                return try await run.result()
            } catch {
                guard case .cancelled(let results) = error else { return nil }
                return results.first
            }
        }
    }

    /// How a run ended after a SIGTERM.
    public struct Stop: Sendable {
        /// The process and its descendants, read just before the SIGTERM.
        public let tree: [Int32]
        /// The processes of ``tree`` that still ran after the process exited and the wait for
        /// them ended. The harness killed each one.
        public let left: [Int32]
        /// Whether a process outside ``tree``, one started during the cancel, still held the
        /// output open after the process exited, until ToolProcess ended it.
        public let outputHeldOpen: Bool
        /// How the process ended, or nil when it still ran after the wait.
        public let termination: ToolProcessTermination?
        /// The time from the SIGTERM to the exit, or nil when the process did not exit.
        public let elapsed: Duration?
        /// What the process wrote to standard output.
        public let standardOutput: String
        /// What the process wrote to standard error.
        public let standardError: String

        /// The exit code, or nil when a signal ended the process or it did not exit.
        public var exitStatus: Int32? {
            guard case .exited(let code) = termination else { return nil }
            return code
        }

        /// How the process ended and the end of its standard error, for a failure message.
        public var diagnostics: String {
            let ending = termination.map { "\($0)" } ?? "still running"
            return " It ended as \(ending). Its standard error ends with: \(standardError.suffix(2_000))"
        }
    }
}

// MARK: - Assertions

extension CLISIGTERMHarness {
    /// Sends one SIGTERM to `run` and asserts the three facts of a converted cancel. The command
    /// exits 125 inside `grace`, `readStatus` then reads the run's record as cancelled, and no
    /// process of the tree is left.
    ///
    /// - Parameter readStatus: Reads the status of the command's record, called once after the exit.
    @discardableResult
    public static func assertSIGTERMCancels(
        _ run: Run,
        within grace: Duration = operationGrace,
        record readStatus: () throws -> String?,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Stop {
        let stop = await cancel(run)
        assertCancelledExit(stop, within: grace, file: file, line: line)
        assertRecordCancelled(readStatus, file: file, line: line)
        assertNoProcessLeft(stop, file: file, line: line)
        return stop
    }

    /// Asserts that the run of `stop` exited with status 125 inside `grace` after its SIGTERM.
    public static func assertCancelledExit(
        _ stop: Stop,
        within grace: Duration = operationGrace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard stop.termination != nil else {
            XCTFail("The process still ran \(processWait) after SIGTERM.\(stop.diagnostics)", file: file, line: line)
            return
        }
        assertCancelledExit(
            status: stop.exitStatus,
            elapsed: stop.elapsed,
            within: grace,
            detail: stop.diagnostics,
            file: file,
            line: line
        )
    }

    /// Asserts a cancelled exit observed another way, such as through the app's transport.
    ///
    /// - Parameters:
    ///   - status: The exit code, nil when a signal ended the process.
    ///   - elapsed: The time from the cancel to the exit, nil when the process did not exit.
    ///   - detail: Appended to each failure message.
    public static func assertCancelledExit(
        status: Int32?,
        elapsed: Duration?,
        within grace: Duration = operationGrace,
        detail: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(status, cancelledExitStatus, "A cancelled command exits \(cancelledExitStatus).\(detail)", file: file, line: line)
        guard let elapsed else {
            XCTFail("The command did not exit after the cancel.\(detail)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            elapsed, grace,
            "The command exits, its record written, inside the \(grace) the app gives it before SIGKILL.\(detail)",
            file: file, line: line
        )
    }

    /// Asserts that `readStatus` reads the run's record as cancelled.
    public static func assertRecordCancelled(
        _ readStatus: () throws -> String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let status = try readStatus()
            XCTAssertEqual(status, cancelledRecordStatus, "The command records its run as cancelled.", file: file, line: line)
        } catch {
            XCTFail("The command's record cannot be read: \(error)", file: file, line: line)
        }
    }

    /// Asserts that no process of the run's tree outlived the run, as ``cancel(_:timeout:)`` found.
    public static func assertNoProcessLeft(
        _ stop: Stop,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            stop.left, [],
            "Processes of the command's tree still ran after it exited, out of \(stop.tree). The harness killed them.",
            file: file, line: line
        )
        XCTAssertFalse(
            stop.outputHeldOpen,
            "A process the command started during the cancel held its output open after it exited.",
            file: file, line: line
        )
    }

    /// Asserts that every process in `processes` is gone within `timeout`, for a cancel observed
    /// another way. Each one that still runs is killed after the failure.
    public static func assertNoProcessLeft(
        _ processes: [Int32],
        timeout: Duration = processWait,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let left = await processesLeft(processes, timeout: timeout)
        XCTAssertEqual(
            left, [],
            "Processes of the command's tree still ran \(timeout) after the cancel, out of \(processes). They were killed.",
            file: file, line: line
        )
    }
}
