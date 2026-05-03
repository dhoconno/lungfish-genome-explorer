// ProcessTreeTerminator.swift - Recursive native process cleanup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log
import LungfishCore

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

    public static func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    public static func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
        guard rootPID > 0 else { return [] }

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,ppid="]

        let stdoutPipe = Pipe()
        ps.standardOutput = stdoutPipe
        ps.standardError = Pipe()

        do {
            try ps.run()
        } catch {
            logger.warning("Unable to enumerate process descendants: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        guard ps.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        var childrenByParent: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else {
                continue
            }
            childrenByParent[ppid, default: []].append(pid)
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

        var orderedPIDs = descendantProcessIDs(of: rootPID)
        orderedPIDs.append(rootPID)

        var seen = Set<Int32>()
        orderedPIDs = orderedPIDs.filter { pid in
            pid > 0 && seen.insert(pid).inserted
        }

        for pid in orderedPIDs.reversed() where processExists(pid: pid) {
            kill(pid, SIGTERM)
        }

        if gracePeriod > 0 {
            usleep(useconds_t(max(0, gracePeriod) * 1_000_000))
        }

        for pid in orderedPIDs.reversed() where processExists(pid: pid) {
            kill(pid, SIGKILL)
        }
    }
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

    public func terminateAll(gracePeriod: TimeInterval = 0.5) {
        let snapshot: [Process]
        lock.lock()
        snapshot = Array(processes.values)
        lock.unlock()

        for process in snapshot {
            ProcessTreeTerminator.terminate(rootProcess: process, gracePeriod: gracePeriod)
        }
    }

    public var activeProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }
}
