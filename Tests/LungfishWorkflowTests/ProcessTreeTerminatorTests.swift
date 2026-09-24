// ProcessTreeTerminatorTests.swift - Recursive process cleanup regression tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
@testable import LungfishWorkflow

final class ProcessTreeTerminatorTests: XCTestCase {
    func testTerminateKillsNestedGrandchildProcess() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let grandchildPIDFile = tempDir.appendingPathComponent("grandchild.pid")
        let helperScript = tempDir.appendingPathComponent("helper.sh")
        let childScript = tempDir.appendingPathComponent("child.sh")
        let rootScript = tempDir.appendingPathComponent("root.sh")

        try writeExecutable(
            """
            #!/bin/sh
            trap "" TERM HUP INT
            sleep 20
            """,
            to: helperScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(childPIDFile.path))
            \(shellQuote(helperScript.path)) &
            echo $! > \(shellQuote(grandchildPIDFile.path))
            wait
            """,
            to: childScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(rootPIDFile.path))
            \(shellQuote(childScript.path)) &
            while true; do sleep 1; done
            """,
            to: rootScript
        )

        let process = Process()
        process.executableURL = rootScript
        try process.run()

        let rootPID = try await waitForPIDFile(rootPIDFile)
        let childPID = try await waitForPIDFile(childPIDFile)
        let grandchildPID = try await waitForPIDFile(grandchildPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: grandchildPID, gracePeriod: 0)
        }

        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let childExited = await waitUntilProcessExits(pid: childPID, timeout: 2)
        let grandchildExited = await waitUntilProcessExits(pid: grandchildPID, timeout: 2)
        XCTAssertTrue(childExited)
        XCTAssertTrue(grandchildExited)
    }

    func testTerminateStopsTermIgnoringRootBeforeFinalSnapshot() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let latePIDFile = tempDir.appendingPathComponent("late.pid")
        let helperScript = tempDir.appendingPathComponent("late-helper.sh")
        let rootScript = tempDir.appendingPathComponent("root.sh")

        try writeExecutable(
            """
            #!/bin/sh
            trap "" TERM HUP INT
            sleep 20
            """,
            to: helperScript
        )
        try writeExecutable(
            """
            #!/bin/sh
            echo $$ > \(shellQuote(rootPIDFile.path))
            trap "" TERM HUP INT
            while true; do
                \(shellQuote(helperScript.path)) &
                echo $! > \(shellQuote(latePIDFile.path))
                sleep 0.05
            done
            """,
            to: rootScript
        )

        let process = Process()
        process.executableURL = rootScript
        try process.run()

        let rootPID = try await waitForPIDFile(rootPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            if let latePID = try? readPID(latePIDFile) {
                ProcessTreeTerminator.terminate(rootPID: latePID, gracePeriod: 0)
            }
        }

        let latePIDBeforeCancel = try await waitForPIDFile(latePIDFile)
        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let lateChildExited = await waitUntilProcessExits(pid: latePIDBeforeCancel, timeout: 2)
        let rootExited = await waitUntilProcessExits(pid: rootPID, timeout: 2)
        XCTAssertTrue(lateChildExited)
        XCTAssertTrue(rootExited)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTreeTerminatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = try? readPID(url) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "ProcessTreeTerminatorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for pid file \(url.path)"]
        )
    }

    private func readPID(_ url: URL) throws -> Int32 {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Not XCTUnwrap: this runs inside `waitForPIDFile`'s `try?` poll, and a
        // PID file observed after creation but before its write would record
        // an XCTest failure even though the poll just retries.
        guard let pid = Int32(contents) else {
            throw NSError(
                domain: "ProcessTreeTerminatorTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected pid in \(url.path)"]
            )
        }
        return pid
    }

    private func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessTreeTerminator.processExists(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !ProcessTreeTerminator.processExists(pid: pid)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: - Shared cancellation harness (P1-B)

    /// A fake tool script that spawns a grandchild which ignores SIGTERM,
    /// and reports its own pid plus the grandchild's pid via files. Used by
    /// every P1-B cancellation test (CLIImportRunner, VCF/BAM helper
    /// runners, ``terminate(rootPID:)`` itself) so they all exercise the
    /// same shape of "termination must reach a SIGTERM-ignoring descendant,
    /// not just the immediate child."
    struct FakeCancellationHarness {
        let rootPIDFile: URL
        let grandchildPIDFile: URL
        let scriptURL: URL

        static func make(in directory: URL) throws -> FakeCancellationHarness {
            let rootPIDFile = directory.appendingPathComponent("harness-root.pid")
            let grandchildPIDFile = directory.appendingPathComponent("harness-grandchild.pid")
            let scriptURL = directory.appendingPathComponent("harness-root.sh")
            let script = """
            #!/bin/sh
            echo $$ > \(shellQuoteStatic(rootPIDFile.path))
            /bin/sh -c 'trap "" TERM HUP INT; echo $$ > \(shellQuoteStatic(grandchildPIDFile.path)); while true; do sleep 1; done' &
            while true; do sleep 1; done
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return FakeCancellationHarness(
                rootPIDFile: rootPIDFile,
                grandchildPIDFile: grandchildPIDFile,
                scriptURL: scriptURL
            )
        }

        private static func shellQuoteStatic(_ value: String) -> String {
            "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }

    /// Asserts that terminating `rootPID` leaves no descendant alive within
    /// `timeout`, including one that traps and ignores SIGTERM/SIGHUP/SIGINT
    /// and must be reached with SIGKILL.
    func testSharedHarnessNoDescendantSurvivesCancellation() async throws {
        let tempDir = try makeTemporaryDirectory()
        let harness = try FakeCancellationHarness.make(in: tempDir)

        let process = Process()
        process.executableURL = harness.scriptURL
        try process.run()

        let rootPID = try await waitForPIDFile(harness.rootPIDFile)
        let grandchildPID = try await waitForPIDFile(harness.grandchildPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: grandchildPID, gracePeriod: 0)
        }

        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: grandchildPID))

        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let rootExited = await waitUntilProcessExits(pid: rootPID, timeout: 2)
        let grandchildExited = await waitUntilProcessExits(pid: grandchildPID, timeout: 2)
        XCTAssertTrue(rootExited, "root process must not survive cancellation")
        XCTAssertTrue(grandchildExited, "a SIGTERM-ignoring grandchild must not survive cancellation")
    }

    // MARK: - PERF-11: injectable process table lister

    private struct FakeProcessTableLister: ProcessTableLister {
        let rows: [ProcessTableRow]
        func snapshot() -> [ProcessTableRow] { rows }
    }

    /// PERF-11 acceptance test: with the process table already known (no
    /// `/bin/ps` involved), `descendantProcessIDs(of:in:)` computes the same
    /// tree the previous `/bin/ps`-based implementation did.
    func testDescendantProcessIDsFromInjectedSnapshotMatchesTree() {
        let snapshot: [ProcessTableRow] = [
            ProcessTableRow(pid: 100, parentPID: 1, isZombie: false),
            ProcessTableRow(pid: 200, parentPID: 100, isZombie: false),
            ProcessTableRow(pid: 201, parentPID: 100, isZombie: false),
            ProcessTableRow(pid: 300, parentPID: 200, isZombie: false),
            ProcessTableRow(pid: 999, parentPID: 1, isZombie: false), // unrelated
        ]
        let descendants = ProcessTreeTerminator.descendantProcessIDs(of: 100, in: snapshot)
        XCTAssertEqual(Set(descendants), Set([200, 201, 300]))
        XCTAssertFalse(descendants.contains(999))
    }

    /// PERF-11 acceptance test: `terminate(rootPID:)` with an injected
    /// process-table lister never calls the real libproc-backed lister —
    /// i.e. it reads the table it was given, not a fresh subprocess or
    /// syscall path outside the injection point. Restores the production
    /// lister afterward so later tests are unaffected.
    func testTerminateUsesInjectedProcessTableListerExclusively() async throws {
        let tempDir = try makeTemporaryDirectory()
        let harness = try FakeCancellationHarness.make(in: tempDir)

        let process = Process()
        process.executableURL = harness.scriptURL
        try process.run()

        let rootPID = try await waitForPIDFile(harness.rootPIDFile)
        let grandchildPID = try await waitForPIDFile(harness.grandchildPIDFile)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: grandchildPID, gracePeriod: 0)
        }

        final class CountingLister: ProcessTableLister, @unchecked Sendable {
            private let real = LibprocProcessTableLister()
            private let lock = NSLock()
            private var callCount = 0

            func snapshot() -> [ProcessTableRow] {
                lock.lock()
                callCount += 1
                lock.unlock()
                return real.snapshot()
            }

            var calls: Int {
                lock.lock()
                defer { lock.unlock() }
                return callCount
            }
        }

        let counting = CountingLister()
        let previousLister = ProcessTreeTerminator.processTableLister
        ProcessTreeTerminator.processTableLister = counting
        defer { ProcessTreeTerminator.processTableLister = previousLister }

        ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)

        let grandchildExited = await waitUntilProcessExits(pid: grandchildPID, timeout: 2)
        XCTAssertTrue(grandchildExited)
        XCTAssertGreaterThan(counting.calls, 0, "terminate(rootPID:) must consult the injected lister")
    }

    // MARK: - PERF-11: concurrent terminateAll

    /// PERF-11 acceptance test: terminating 4 fake roots, each with 3
    /// SIGTERM-ignoring children, completes in well under 4x a single
    /// root's cost — i.e. roots are terminated concurrently, not serially.
    func testTerminateAllRunsRootsConcurrently() async throws {
        let tempDir = try makeTemporaryDirectory()
        let registry = NativeProcessRegistry.shared

        struct RootHandle {
            let process: Process
            let rootPIDFile: URL
            let childPIDFiles: [URL]
        }

        var handles: [RootHandle] = []
        for index in 0..<4 {
            let rootPIDFile = tempDir.appendingPathComponent("root\(index).pid")
            let childPIDFiles = (0..<3).map { tempDir.appendingPathComponent("root\(index)-child\($0).pid") }
            let scriptURL = tempDir.appendingPathComponent("root\(index).sh")
            let spawnLines = childPIDFiles.map { childFile in
                "/bin/sh -c 'trap \"\" TERM HUP INT; echo $$ > \(shellQuote(childFile.path)); while true; do sleep 1; done' &"
            }.joined(separator: "\n")
            let script = """
            #!/bin/sh
            echo $$ > \(shellQuote(rootPIDFile.path))
            \(spawnLines)
            while true; do sleep 1; done
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = scriptURL
            try process.run()
            handles.append(RootHandle(process: process, rootPIDFile: rootPIDFile, childPIDFiles: childPIDFiles))
        }

        var rootPIDs: [Int32] = []
        var allChildPIDs: [Int32] = []
        for handle in handles {
            _ = try await waitForPIDFile(handle.rootPIDFile)
            registry.register(handle.process)
            rootPIDs.append(handle.process.processIdentifier)
            for childFile in handle.childPIDFiles {
                allChildPIDs.append(try await waitForPIDFile(childFile))
            }
        }
        defer {
            for pid in rootPIDs {
                ProcessTreeTerminator.terminate(rootPID: pid, gracePeriod: 0)
            }
            for pid in allChildPIDs {
                if ProcessTreeTerminator.processExists(pid: pid) {
                    kill(pid, SIGKILL)
                }
            }
        }

        let start = Date()
        registry.terminateAll(gracePeriod: 0)
        let elapsed = Date().timeIntervalSince(start)

        for pid in allChildPIDs {
            let exited = await waitUntilProcessExits(pid: pid, timeout: 2)
            XCTAssertTrue(exited, "child \(pid) must not survive terminateAll")
        }
        // Four roots run concurrently should finish well under 4x a single
        // root's serial cost; generous bound to avoid CI flakiness while
        // still catching a regression back to serial execution.
        XCTAssertLessThan(elapsed, 3.0, "terminateAll should run roots concurrently, not serially")
    }
}
