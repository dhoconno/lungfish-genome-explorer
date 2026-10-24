// WorkRootDiskSampler.swift - The largest size the work root reached while the storage step ran (vote C4-4, CH-8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Walks the work root in process, with no launch, once when the storage step starts, then every `interval` seconds on
/// a queue of its own, and once more when the step ends, and keeps the largest total it saw (CHTC CH-8 of vote C4-4).
/// HTCondor's starter samples a job's disk use about every 300 seconds and at the job's end, so a scratch file that a
/// storage step writes and deletes within that span never reaches the job log, and this peak is the record's figure
/// for the node's scratch disk. A walk sums the sizes of the regular files under the root, each file once by device and
/// inode, and follows no link.
final class WorkRootDiskSampler: Sendable {
    /// The pause between two walks, under the one second that CH-8 allows.
    static let interval = 0.25

    private let root: String
    private let peak: Mutex<UInt64>
    private let stop = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private let sampling: Bool

    /// Takes the first walk and, unless `interval` is nil, starts the walks between the step's start and its end.
    init(root: String, interval: Double? = WorkRootDiskSampler.interval) {
        self.root = root
        peak = Mutex(WorkRootDiskSampler.bytes(under: root))
        sampling = interval != nil
        guard let interval else { return }
        DispatchQueue(label: "lungfish-executor.work-root-disk").async { [self] in
            while stop.wait(timeout: .now() + interval) == .timedOut {
                record(WorkRootDiskSampler.bytes(under: root))
            }
            stopped.signal()
        }
    }

    /// Stops the walks, takes the last one and returns the largest total in bytes. Call it once.
    func finish() -> UInt64 {
        if sampling {
            stop.signal()
            stopped.wait()
        }
        record(WorkRootDiskSampler.bytes(under: root))
        return peak.withLock { $0 }
    }

    private func record(_ bytes: UInt64) {
        peak.withLock { $0 = max($0, bytes) }
    }

    private struct FileID: Hashable {
        var device: UInt64
        var inode: UInt64
    }

    /// The sum of the sizes of the regular files under `root`, each once, links not followed. A file or folder removed
    /// while the walk runs is skipped.
    static func bytes(under root: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = Set<FileID>()
        var folders = [root]
        while let folder = folders.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names {
                let path = folder + "/" + name
                var status = stat()
                guard lstat(path, &status) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    folders.append(path)
                case S_IFREG:
                    let id = FileID(
                        device: UInt64(truncatingIfNeeded: status.st_dev), inode: UInt64(truncatingIfNeeded: status.st_ino)
                    )
                    if seen.insert(id).inserted { total += UInt64(max(0, Int64(status.st_size))) }
                default:
                    continue
                }
            }
        }
        return total
    }
}
