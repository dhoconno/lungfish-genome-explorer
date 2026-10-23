// RunRecordWriter.swift - Writes run-record.json at the work root, last, by one rename (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Writes the run record as the run's last act (ARCH-r3 ruling 2): a temporary file made in the work root with
/// `O_EXCL | O_NOFOLLOW`, written whole and synced, then renamed over `run-record.json` through the work root's
/// descriptor, so a reader sees the old record or the whole new one and a planted link is replaced, never followed.
enum RunRecordWriter {
    static func write(_ record: ExecutorRunRecord, workRoot: String) throws(ExecutorSpawn.Failure) {
        let data: Data
        do {
            data = try record.encoded()
        } catch {
            throw ExecutorSpawn.Failure(reason: "Could not encode the run record. \(error)")
        }
        let directory = open(workRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw ExecutorSpawn.Failure(reason: "Could not open the work root to write the run record. \(String(cString: strerror(errno)))")
        }
        defer { close(directory) }
        let temporary = ".\(ExecutorRunRecord.fileName).tmp-\(getpid())"
        _ = unlinkat(directory, temporary, 0)
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw ExecutorSpawn.Failure(reason: "Could not create the run record. \(String(cString: strerror(errno)))")
        }
        let written = writeAll(fd, data) && fsync(fd) == 0
        close(fd)
        guard written, renameat(directory, temporary, directory, ExecutorRunRecord.fileName) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = unlinkat(directory, temporary, 0)
            throw ExecutorSpawn.Failure(reason: "Could not write the run record. \(reason)")
        }
        _ = fsync(directory)
    }
}
