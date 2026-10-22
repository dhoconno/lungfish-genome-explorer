// ProcessTable.swift - The executor's view of the process table: /proc on Linux, libproc on macOS parity runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// One process as the table saw it.
struct ProcessEntry: Equatable, Sendable {
    var pid: pid_t
    var parent: pid_t
    var group: pid_t
    /// The one-letter state of `/proc/<pid>/stat` field 3. `Z` is a zombie and `X` a dead process.
    var state: Character

    var isLive: Bool { state != "Z" && state != "X" }
}

/// Snapshots of the process table and the walk of a process's descendants.
///
/// On Linux each entry comes from `/proc/<pid>/stat`, parsed after the last `)` because the command name may hold
/// spaces and parentheses. Tests pass an injected root folder laid out as `/proc` (tally K3.3), so their verdict does not
/// depend on a container runtime. macOS has no `/proc`, so the parity build reads the same three fields through libproc.
enum ProcessTable {
    /// Parses one `/proc/<pid>/stat` line into an entry, or nil when the line is not one.
    static func parseStat(_ text: String) -> ProcessEntry? {
        guard let close = text.lastIndex(of: ")"),
              let pid = pid_t(text[..<close].split(separator: " ", maxSplits: 1).first ?? "") else {
            return nil
        }
        let fields = text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let state = fields[0].first, fields[0].count == 1,
              let parent = pid_t(fields[1]), let group = pid_t(fields[2]) else {
            return nil
        }
        return ProcessEntry(pid: pid, parent: parent, group: group, state: state)
    }

    /// Reads every numeric folder of a `/proc`-shaped root. A process that ends between the listing and the read is skipped.
    static func snapshot(procRoot: String) -> [ProcessEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: procRoot)) ?? []
        var entries: [ProcessEntry] = []
        for name in names where !name.isEmpty && name.allSatisfy(\.isNumber) {
            if let text = readSmallFile("\(procRoot)/\(name)/stat"), let entry = parseStat(text) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// The live process table of this machine.
    static func snapshot() -> [ProcessEntry] {
        #if os(Linux)
        return snapshot(procRoot: "/proc")
        #else
        return darwinSnapshot()
        #endif
    }

    /// The live processes whose parent chain reaches `root`, plus the live members of `groups`, without `root` itself.
    /// This is the set the executor signals: what it found under its own PID and the groups of the children it started.
    static func liveDescendants(of root: pid_t, groups: Set<pid_t>, in entries: [ProcessEntry]) -> [ProcessEntry] {
        var children: [pid_t: [ProcessEntry]] = [:]
        for entry in entries where entry.pid != entry.parent {
            children[entry.parent, default: []].append(entry)
        }
        var found: [pid_t: ProcessEntry] = [:]
        var queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where found[child.pid] == nil && child.pid != root {
                found[child.pid] = child
                queue.append(child.pid)
            }
        }
        for entry in entries where groups.contains(entry.group) && entry.pid != root {
            found[entry.pid] = entry
        }
        return found.values.filter(\.isLive).sorted { $0.pid < $1.pid }
    }

    /// The value of one `Name:` line of `/proc/<pid>/status`, such as `PPid`, or nil.
    static func statusField(_ name: String, pid: pid_t, procRoot: String = "/proc") -> String? {
        guard let text = readSmallFile("\(procRoot)/\(pid)/status") else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("\(name):") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Reads a small file to the end with plain `read` calls, since `/proc` files report a size of 0.
    static func readSmallFile(_ path: String, limit: Int = 1 << 20) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < limit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    #if os(macOS)
    /// The process table through libproc. A zombie gives no BSD info on macOS and is skipped, which keeps it out of the
    /// live set as on Linux.
    private static func darwinSnapshot() -> [ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var entries: [ProcessEntry] = []
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            // SZOMB is 5 in <sys/proc.h>.
            let state: Character = info.pbi_status == 5 ? "Z" : "S"
            entries.append(ProcessEntry(pid: pid, parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), state: state))
        }
        return entries
    }
    #endif
}
