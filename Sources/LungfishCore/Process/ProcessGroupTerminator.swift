// ProcessGroupTerminator.swift - Terminates a ToolProcess stage's group and tree on a shared timer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os
import Synchronization

/// Terminates the process group and descendant tree of a ToolProcess stage
/// without parking a thread while the grace period runs.
///
/// SIGTERM goes to the group and to every descendant found in the process
/// table. One serial queue shared by every termination then looks again every
/// ``checkInterval``. A termination is over as soon as the leader has exited
/// and no process of its group or tree is running, so a tool that honours
/// SIGTERM is done in a few tens of milliseconds, not after the grace. At the
/// deadline the survivors get SIGKILL, and the termination still waits, for
/// at most ``killSettleLimit``, until they are really gone, so a group counts
/// as settled only once it is empty.
///
/// The checks are cheap (the leader, one group listing and the known tree
/// members by pid and start time). A process-table snapshot, which finds
/// descendants that left the group, is taken at the start, at least every
/// ``snapshotInterval``, at the deadline and once more before a termination
/// is declared over, and one snapshot serves every pending termination.
///
/// The leader must stay unreaped until `completion` runs, so its pid keeps
/// naming the group. A descendant that leaves both the group and the tree,
/// for example by calling setsid after its parent exited, cannot be found.
enum ProcessGroupTerminator {
    static let checkInterval: Duration = .milliseconds(20)
    static let snapshotInterval: Duration = .milliseconds(100)
    static let killSettleLimit: Duration = .seconds(1)

    private struct Termination {
        let leader: pid_t
        let killAt: ContinuousClock.Instant
        /// Set once SIGKILL went out. The termination ends by then at the latest.
        var settleBy: ContinuousClock.Instant?
        /// Descendants found in a snapshot, by pid with their start time, so
        /// a pid reused by an unrelated process is never signalled.
        var tree: [pid_t: UInt64] = [:]
        var lastSnapshot: ContinuousClock.Instant
        let completion: @Sendable () -> Void
    }

    private struct Pending {
        var terminations: [Int: Termination] = [:]
        var nextID = 0
        var timerArmed = false
    }

    private static let logger = Logger(subsystem: LogSubsystem.core, category: "ToolProcess")
    private static let clock = ContinuousClock()
    /// The one queue every termination's checks run on. It only ever runs
    /// short, nonblocking work.
    private static let queue = DispatchQueue(label: "org.lungfish.tool-process.terminator", qos: .userInitiated)
    /// Touched only on `queue`. The Mutex makes that safe to state.
    private static let pending = Mutex(Pending())

    /// Sends SIGTERM to the group led by `leader` and to its tree now, SIGKILL
    /// to whatever is left after `gracePeriod`, and calls `completion` on a
    /// private queue once the group and tree are empty.
    static func terminate(
        processGroupLeader leader: pid_t,
        gracePeriod: Duration,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async {
            begin(leader: leader, gracePeriod: gracePeriod, completion: completion)
        }
    }

    private static func begin(leader: pid_t, gracePeriod: Duration, completion: @escaping @Sendable () -> Void) {
        guard leader > 1 else {
            completion()
            return
        }
        let now = clock.now
        killpg(leader, SIGTERM)
        var termination = Termination(
            leader: leader,
            killAt: now.advanced(by: max(gracePeriod, .zero)),
            lastSnapshot: now,
            completion: completion
        )
        discover(&termination, in: childrenByParent(ProcessTreeTerminator.processTableLister.snapshot()), signal: SIGTERM)
        pending.withLock { state in
            state.terminations[state.nextID] = termination
            state.nextID += 1
        }
        armTimer()
    }

    private static func armTimer() {
        let arm = pending.withLock { state -> Bool in
            guard !state.terminations.isEmpty, !state.timerArmed else { return false }
            state.timerArmed = true
            return true
        }
        guard arm else { return }
        queue.asyncAfter(deadline: .now() + ToolProcessExecution.dispatchInterval(checkInterval)) {
            tick()
        }
    }

    private static func tick() {
        let now = clock.now
        var terminations = pending.withLock { state -> [Int: Termination] in
            state.timerArmed = false
            return state.terminations
        }
        guard !terminations.isEmpty else { return }

        // Forget tree members that are gone, then decide whether this look
        // needs a snapshot: one is due, a deadline passed, or a termination
        // looks finished and must be confirmed.
        var needSnapshot = false
        for id in Array(terminations.keys) {
            guard var termination = terminations[id] else { continue }
            termination.tree = termination.tree.filter { ToolProcessSpawner.runningStartTime($0.key) == $0.value }
            terminations[id] = termination
            if termination.settleBy == nil && now >= termination.killAt
                || termination.lastSnapshot.duration(to: now) >= snapshotInterval
                || isEmpty(termination) {
                needSnapshot = true
            }
        }
        let children = needSnapshot ? childrenByParent(ProcessTreeTerminator.processTableLister.snapshot()) : nil

        var finished: [Int] = []
        for id in terminations.keys.sorted() {
            guard var termination = terminations[id] else { continue }
            if let children {
                discover(&termination, in: children, signal: termination.settleBy == nil ? SIGTERM : SIGKILL)
                termination.lastSnapshot = now
            }
            if isEmpty(termination) {
                finished.append(id)
            } else if let settleBy = termination.settleBy {
                kill(termination, signal: SIGKILL)
                if now >= settleBy {
                    logger.warning("Process group \(termination.leader) still had running members \(String(describing: killSettleLimit), privacy: .public) after SIGKILL")
                    finished.append(id)
                }
            } else if now >= termination.killAt {
                kill(termination, signal: SIGKILL)
                termination.settleBy = now.advanced(by: killSettleLimit)
            }
            terminations[id] = termination
        }

        let completions = pending.withLock { state -> [@Sendable () -> Void] in
            for (id, termination) in terminations where state.terminations[id] != nil {
                state.terminations[id] = termination
            }
            return finished.compactMap { state.terminations.removeValue(forKey: $0)?.completion }
        }
        completions.forEach { $0() }
        armTimer()
    }

    /// True when the leader has exited and no process of its group or known
    /// tree is running.
    private static func isEmpty(_ termination: Termination) -> Bool {
        termination.tree.isEmpty
            && !ToolProcessSpawner.isRunning(termination.leader)
            && ToolProcessSpawner.liveGroupMembers(termination.leader).isEmpty
    }

    private static func kill(_ termination: Termination, signal: Int32) {
        killpg(termination.leader, signal)
        for pid in termination.tree.keys {
            Darwin.kill(pid, signal)
        }
    }

    /// Adds every running descendant of the leader and of the known tree to
    /// the tree, and sends each new one `signal`.
    private static func discover(_ termination: inout Termination, in children: [pid_t: [pid_t]], signal: Int32) {
        var queue = [termination.leader] + Array(termination.tree.keys)
        var seen = Set(queue)
        while let parent = queue.popLast() {
            for child in children[parent, default: []] where seen.insert(child).inserted {
                queue.append(child)
                guard termination.tree[child] == nil, let started = ToolProcessSpawner.runningStartTime(child) else { continue }
                termination.tree[child] = started
                Darwin.kill(child, signal)
            }
        }
    }

    private static func childrenByParent(_ snapshot: [ProcessTableRow]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for row in snapshot where !row.isZombie {
            children[row.parentPID, default: []].append(row.pid)
        }
        return children
    }
}
