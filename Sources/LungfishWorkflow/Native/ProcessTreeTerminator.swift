// ProcessTreeTerminator.swift - Recursive native process cleanup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log
import LungfishCore

/// One row of the whole-system process table, as `pid=,ppid=` plus liveness
/// state — the minimum ``ProcessTreeTerminator`` needs to compute a
/// descendant tree and detect zombies.
public struct ProcessTableRow: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let isZombie: Bool

    public init(pid: Int32, parentPID: Int32, isZombie: Bool) {
        self.pid = pid
        self.parentPID = parentPID
        self.isZombie = isZombie
    }
}

/// Reads the whole-system process table.
///
/// PERF-11: the default implementation queries `libproc`
/// (`proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)`) directly —
/// microseconds, no subprocess — in place of the previous `/bin/ps -Ao
/// pid=,ppid=` and `/bin/ps -o stat= -p <pid>` spawns, which measured
/// roughly 25 ms and 2.3 ms respectively and were called once per PID per
/// termination-loop iteration. Tests inject a fake lister to assert no
/// `/bin/ps` process is ever launched.
public protocol ProcessTableLister: Sendable {
    func snapshot() -> [ProcessTableRow]
}

public struct LibprocProcessTableLister: ProcessTableLister {
    public init() {}

    public func snapshot() -> [ProcessTableRow] {
        var bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }
        // The process table can grow between the sizing call and the fetch;
        // over-allocate and let the fetch tell us the real count.
        var pids = [Int32](repeating: 0, count: Int(bufferSize) * 2)
        let fetchedBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        guard fetchedBytes > 0 else { return [] }
        let count = min(pids.count, Int(fetchedBytes) / MemoryLayout<Int32>.size)
        bufferSize = Int32(count)

        var rows: [ProcessTableRow] = []
        rows.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            rows.append(
                ProcessTableRow(
                    pid: pid,
                    parentPID: Int32(bitPattern: info.pbi_ppid),
                    isZombie: info.pbi_status == UInt32(SZOMB)
                )
            )
        }
        return rows
    }
}

/// Utilities for terminating native tool process trees.
///
/// Foundation's `Process.terminate()` only signals the root process. Many
/// bioinformatics tools spawn helper processes, Python workers, or shell
/// children, so cancellation must target the full descendant tree.
public enum ProcessTreeTerminator {
    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "ProcessTreeTerminator"
    )

    /// Lock-protected box for the overridable process-table source, so tests
    /// can prove no `/bin/ps` subprocess is launched without introducing
    /// nonisolated global mutable state. Production code always uses the
    /// default ``LibprocProcessTableLister``.
    private final class ProcessTableListerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lister: any ProcessTableLister = LibprocProcessTableLister()

        var current: any ProcessTableLister {
            lock.lock()
            defer { lock.unlock() }
            return lister
        }

        func set(_ newLister: any ProcessTableLister) {
            lock.lock()
            lister = newLister
            lock.unlock()
        }
    }

    private static let processTableListerBox = ProcessTableListerBox()

    /// Overridable process-table source, for tests that must prove no
    /// `/bin/ps` subprocess is launched. Production code always uses the
    /// default ``LibprocProcessTableLister``.
    public static var processTableLister: any ProcessTableLister {
        get { processTableListerBox.current }
        set { processTableListerBox.set(newValue) }
    }

    public static func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return !isZombieProcess(pid: pid)
        }
        return errno != ESRCH
    }

    private static func isZombieProcess(pid: Int32) -> Bool {
        // `kill(pid, 0)` already proved the PID is live enough to receive a
        // signal; only a single-row libproc lookup is needed to tell a
        // zombie from a live process, no full-table snapshot required.
        var info = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return info.pbi_status == UInt32(SZOMB)
    }

    public static func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
        guard rootPID > 0 else { return [] }
        return descendantProcessIDs(of: rootPID, in: processTableLister.snapshot())
    }

    /// Same as ``descendantProcessIDs(of:)`` but computed from an
    /// already-fetched snapshot, so a caller walking several roots (or
    /// re-checking liveness in a loop) pays for one process-table read
    /// instead of one per PID (PERF-11).
    public static func descendantProcessIDs(of rootPID: Int32, in snapshot: [ProcessTableRow]) -> [Int32] {
        guard rootPID > 0 else { return [] }

        var childrenByParent: [Int32: [Int32]] = [:]
        childrenByParent.reserveCapacity(snapshot.count)
        for row in snapshot {
            childrenByParent[row.parentPID, default: []].append(row.pid)
        }

        var descendants: [Int32] = []
        var queue: [Int32] = [rootPID]
        var seen: Set<Int32> = [rootPID]

        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in childrenByParent[parent, default: []] where seen.insert(child).inserted {
                descendants.append(child)
                queue.append(child)
            }
        }

        return descendants
    }

    public static func terminate(rootProcess: Process, gracePeriod: TimeInterval = 0.5) {
        let rootPID = rootProcess.processIdentifier
        guard rootPID > 0 else {
            if rootProcess.isRunning {
                rootProcess.terminate()
            }
            return
        }

        terminate(rootPID: rootPID, gracePeriod: gracePeriod)
    }

    public static func terminate(rootPID: Int32, gracePeriod: TimeInterval = 0.5) {
        guard rootPID > 0 else { return }

        // PERF-11: every liveness check and descendant lookup below reads
        // from a snapshot already fetched this call, rather than spawning
        // `/bin/ps` (or even a fresh libproc query) per PID. A `snapshot ==
        // nil` row means "not found in the last table read", which is
        // treated as "not running" — the same meaning `processExists`
        // returning false had.
        func isAlive(_ pid: Int32, in snapshot: [Int32: ProcessTableRow]) -> Bool {
            guard let row = snapshot[pid] else { return false }
            return !row.isZombie
        }

        func orderedProcessTree(in snapshot: [ProcessTableRow]) -> [Int32] {
            var orderedPIDs = descendantProcessIDs(of: rootPID, in: snapshot)
            orderedPIDs.append(rootPID)

            var seen = Set<Int32>()
            return orderedPIDs.filter { pid in
                pid > 0 && seen.insert(pid).inserted
            }
        }

        func indexed(_ snapshot: [ProcessTableRow]) -> [Int32: ProcessTableRow] {
            Dictionary(snapshot.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func signalDescendantsBeforeRoot(
            _ pids: [Int32],
            in indexedSnapshot: [Int32: ProcessTableRow],
            signal: Int32,
            includeRoot: Bool = true
        ) {
            guard let rootIndex = pids.lastIndex(of: rootPID) else { return }
            for pid in pids[..<rootIndex].reversed() where isAlive(pid, in: indexedSnapshot) {
                kill(pid, signal)
            }
            if includeRoot && isAlive(rootPID, in: indexedSnapshot) {
                kill(rootPID, signal)
            }
        }

        func uniquePIDs(_ pids: [Int32]) -> [Int32] {
            var seen = Set<Int32>()
            return pids.filter { pid in
                pid > 0 && seen.insert(pid).inserted
            }
        }

        func expandWithDescendants(_ pids: [Int32], in snapshot: [ProcessTableRow]) -> [Int32] {
            uniquePIDs(pids + pids.flatMap { descendantProcessIDs(of: $0, in: snapshot) })
        }

        /// Takes one fresh process-table snapshot per polling iteration
        /// (not one per PID) to decide who is still alive.
        func waitForPIDsToExit(_ pids: [Int32], timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            let pids = uniquePIDs(pids.filter { $0 != rootPID })
            while Date() < deadline {
                let snapshot = processTableLister.snapshot()
                let expanded = expandWithDescendants(pids, in: snapshot)
                let indexedLive = indexed(snapshot)
                let livePIDs = expanded.filter { isAlive($0, in: indexedLive) }
                if livePIDs.isEmpty {
                    return
                }
                for pid in livePIDs {
                    kill(pid, SIGKILL)
                }
                usleep(25_000)
            }
        }

        let firstSnapshot = processTableLister.snapshot()
        let initialTree = orderedProcessTree(in: firstSnapshot)
        signalDescendantsBeforeRoot(initialTree, in: indexed(firstSnapshot), signal: SIGTERM)
        if gracePeriod > 0 {
            usleep(useconds_t(max(0, gracePeriod) * 1_000_000))
        } else {
            usleep(50_000)
        }

        let stopSnapshot = indexed(processTableLister.snapshot())
        let rootWasStopped: Bool = {
            guard isAlive(rootPID, in: stopSnapshot) else { return false }
            return kill(rootPID, SIGSTOP) == 0
        }()

        // Shell wrappers can spawn helpers immediately after a snapshot. Stop
        // the root before the late snapshot so it cannot create new direct
        // children while descendants are being killed.
        let lateSnapshot = processTableLister.snapshot()
        let finalTree = expandWithDescendants(initialTree + orderedProcessTree(in: lateSnapshot), in: lateSnapshot)
        signalDescendantsBeforeRoot(finalTree, in: indexed(lateSnapshot), signal: SIGKILL, includeRoot: false)
        waitForPIDsToExit(finalTree, timeout: 0.25)

        let finalCheckSnapshot = indexed(processTableLister.snapshot())
        if isAlive(rootPID, in: finalCheckSnapshot) {
            kill(rootPID, SIGKILL)
        }
        if rootWasStopped {
            let continueSnapshot = indexed(processTableLister.snapshot())
            if isAlive(rootPID, in: continueSnapshot) {
                kill(rootPID, SIGCONT)
            }
        }
    }
}

/// Waits for a helper subprocess to exit while honoring cooperative
/// cancellation, without polling with `Thread.sleep` and without leaving
/// descendant tool processes alive when cancelled.
///
/// The previous pattern used across several helper-subprocess call sites
/// (`AppDelegate+ImportCenter.swift`'s VCF helper runners,
/// `BAMImportHelperClient`) polled `process.isRunning` on a 100 ms
/// `Thread.sleep` loop and called `process.terminate()` on cancellation,
/// which signals only the helper root — descendant tool processes such as
/// `bcftools` or `samtools` were left running (PERF-13). This utility
/// registers the process with ``NativeProcessRegistry`` for the duration of
/// the wait (so app quit also reaches it), waits for exit via
/// `Process.terminationHandler` rather than blocking on `waitUntilExit()`
/// or a sleep loop, and on cancellation terminates the whole process tree
/// with ``ProcessTreeTerminator``.
///
/// - Returns: `true` if cancellation was requested and the tree was
///   terminated; `false` if the process exited normally first.
@discardableResult
public func waitForHelperProcessExit(
    _ process: Process,
    shouldCancel: @escaping @Sendable () -> Bool,
    pollInterval: TimeInterval = 0.05,
    postCancelWait: TimeInterval = 2.0
) -> Bool {
    NativeProcessRegistry.shared.register(process)
    defer { NativeProcessRegistry.shared.unregister(process) }

    final class ExitGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var exited = false

        func markExited() {
            condition.lock()
            exited = true
            condition.signal()
            condition.unlock()
        }

        /// Blocks the caller until `markExited()` runs or `deadline` passes,
        /// polling `shouldCancel` at `pollInterval` in between. When
        /// cancellation fires, invokes `onCancel` synchronously (still
        /// holding no lock) and continues waiting for the real exit signal.
        func wait(
            pollInterval: TimeInterval,
            shouldCancel: () -> Bool,
            onCancel: () -> Void
        ) -> Bool {
            var cancelled = false
            condition.lock()
            while !exited {
                if !cancelled && shouldCancel() {
                    cancelled = true
                    condition.unlock()
                    onCancel()
                    condition.lock()
                    continue
                }
                _ = condition.wait(until: Date().addingTimeInterval(pollInterval))
            }
            condition.unlock()
            return cancelled
        }

        func waitBounded(deadline: Date) {
            condition.lock()
            while !exited && Date() < deadline {
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            }
            condition.unlock()
        }
    }

    let gate = ExitGate()
    process.terminationHandler = { _ in gate.markExited() }
    defer { process.terminationHandler = nil }

    let requestedCancel = gate.wait(
        pollInterval: pollInterval,
        shouldCancel: shouldCancel,
        onCancel: { ProcessTreeTerminator.terminate(rootProcess: process) }
    )

    if requestedCancel {
        // `terminate(rootProcess:)` already waits out the tree, but the
        // termination handler fires asynchronously off Foundation's own
        // notification thread; give it a brief bounded window to observe
        // the exit instead of calling the blocking `waitUntilExit()`.
        gate.waitBounded(deadline: Date().addingTimeInterval(postCancelWait))
    }

    return requestedCancel
}

public final class NativeProcessRegistry: @unchecked Sendable {
    public static let shared = NativeProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    private init() {}

    public func register(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    public func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    /// Terminates every registered process tree concurrently.
    ///
    /// PERF-11: the previous implementation terminated each root serially,
    /// so N roots each paid their own grace period plus per-PID `ps` cost —
    /// measured at roughly 1 s per root, so quitting with four running tools
    /// took about 4 s of blocking time. `ProcessTreeTerminator.terminate`
    /// already sleeps out a single grace period per call; running those
    /// calls concurrently means N roots cost about one grace period total
    /// instead of N.
    ///
    /// Synchronous rather than `async`: `applicationWillTerminate` is a
    /// synchronous AppKit callback that cannot suspend, so this blocks the
    /// calling thread until every tree is handled — callers that must not
    /// block their own thread (e.g. the main thread) should dispatch this
    /// call itself onto a background queue rather than expecting internal
    /// concurrency to free the caller.
    public func terminateAll(gracePeriod: TimeInterval = 0.5) {
        let snapshot: [Process]
        lock.lock()
        snapshot = Array(processes.values)
        lock.unlock()

        guard !snapshot.isEmpty else { return }
        guard snapshot.count > 1 else {
            ProcessTreeTerminator.terminate(rootProcess: snapshot[0], gracePeriod: gracePeriod)
            return
        }

        let group = DispatchGroup()
        for process in snapshot {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: gracePeriod)
                group.leave()
            }
        }
        group.wait()
    }

    public var activeProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }
}

enum NativeProcessCompletionReason {
    case completed
    case cancelled
    case timedOut
}

final class NativeProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cancelled = false
    private var timedOut = false

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func resumeOnce(_ body: (NativeProcessCompletionReason) -> Void) {
        let reason: NativeProcessCompletionReason
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        if cancelled {
            reason = .cancelled
        } else if timedOut {
            reason = .timedOut
        } else {
            reason = .completed
        }
        lock.unlock()
        body(reason)
    }
}

public final class NativeProcessCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminationRequested = false

    public init() {}

    public func store(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
        NativeProcessRegistry.shared.register(process)
    }

    public func clear(_ process: Process) {
        let shouldUnregister: Bool
        lock.lock()
        if self.process === process {
            self.process = nil
            terminationRequested = false
            shouldUnregister = true
        } else {
            shouldUnregister = false
        }
        lock.unlock()

        if shouldUnregister {
            NativeProcessRegistry.shared.unregister(process)
        }
    }

    public func terminateProcessTree(gracePeriod: TimeInterval = 0.5) {
        let process: Process?
        lock.lock()
        terminationRequested = true
        process = self.process
        lock.unlock()

        guard let process else { return }
        ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: gracePeriod)
    }

    public func requestProcessTreeTermination(gracePeriod: TimeInterval = 0.5) {
        let process: Process?
        lock.lock()
        terminationRequested = true
        process = self.process
        lock.unlock()

        guard let process else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: gracePeriod)
        }
    }

    public var isTerminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    public func terminateIfRequested(gracePeriod: TimeInterval = 0.5) {
        let shouldTerminate: Bool
        let process: Process?
        lock.lock()
        shouldTerminate = terminationRequested
        process = self.process
        lock.unlock()

        guard shouldTerminate, let process else { return }
        ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: gracePeriod)
    }
}
