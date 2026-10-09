// ONTBarcodeDemuxGenotypingPipeline+MappingPipe.swift - Helpers of the minimap2 into samtools sort pipe
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import Synchronization

/// The pipe that streams sample-prefixed reads into minimap2's stdin.
///
/// ToolProcess opens `readURL`, a `/dev/fd` path, which on Darwin duplicates
/// the read end, and hands that copy to minimap2. Both ends are
/// close-on-exec so no other launch inherits them, and each closes once.
final class ONTGenotypingStreamedInput: Sendable {
    let readURL: URL
    let writeHandle: FileHandle
    private let readFD: Int32
    private let open = Mutex((read: true, write: true))

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        readFD = fds[0]
        readURL = URL(fileURLWithPath: "/dev/fd/\(fds[0])")
        writeHandle = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    }

    deinit {
        closeReadEnd()
        closeWriteEnd()
    }

    func closeReadEnd() {
        let wasOpen = open.withLock { state in
            defer { state.read = false }
            return state.read
        }
        if wasOpen { close(readFD) }
    }

    func closeWriteEnd() {
        let wasOpen = open.withLock { state in
            defer { state.write = false }
            return state.write
        }
        if wasOpen { try? writeHandle.close() }
    }
}

extension ONTBarcodeDemuxGenotypingPipeline {
    /// The stage to report for a failed minimap2 into samtools sort pipe, or
    /// nil when both exited 0.
    ///
    /// A stage the pipeline stopped because the other failed is not the
    /// cause. When both failed on their own, minimap2 is reported, unless it
    /// died of SIGPIPE, SIGTERM or SIGKILL while samtools sort exited with an
    /// error of its own, which then explains it.
    static func mappingPipelineFailure(
        minimap2: ToolProcessResult,
        sort: ToolProcessResult
    ) -> (tool: String, status: Int32)? {
        let minimap2Failed = minimap2.termination != .exited(code: 0)
        let sortFailed = sort.termination != .exited(code: 0)
        guard minimap2Failed || sortFailed else { return nil }
        let minimap2Caused = minimap2Failed && minimap2.stop == nil
        let sortCaused = sortFailed && sort.stop == nil
        let terminationSignals: Set<Int32> = [SIGPIPE, SIGTERM, SIGKILL]
        func diedOfTermination(_ result: ToolProcessResult) -> Bool {
            if case .signaled(let signal) = result.termination { return terminationSignals.contains(signal) }
            return false
        }
        if minimap2Caused && sortCaused {
            if diedOfTermination(minimap2) && !diedOfTermination(sort) {
                return ("samtools sort", sort.status)
            }
            return ("minimap2", minimap2.status)
        }
        if sortCaused {
            return ("samtools sort", sort.status)
        }
        if minimap2Caused {
            return ("minimap2", minimap2.status)
        }
        // Both were stopped, which only a cancellation or timeout does.
        return minimap2Failed ? ("minimap2", minimap2.status) : ("samtools sort", sort.status)
    }

    /// Removes a sorted BAM and the temporary chunks samtools sort writes
    /// beside it (`<output>.tmp.NNNN.bam`).
    static func removePartialSortOutput(_ outputBAMURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputBAMURL)
        let directory = outputBAMURL.deletingLastPathComponent()
        let prefix = outputBAMURL.lastPathComponent + ".tmp."
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
