// ToolProcessOutputStream.swift - The caller's reader of a streamed ToolProcess stdout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import Synchronization

/// Standard output of a run whose spec sets ``ToolProcessOutput/stream``,
/// read raw by the caller while the process runs.
///
/// The bytes arrive exactly as the process wrote them, with no line framing,
/// no 64 KB cut and every lone CR kept, and ToolProcess keeps none of them.
/// The pipe holds the process back whenever the reader is slower than the
/// writer, so a stream of gigabytes needs only the reader's own buffer.
/// When the spec does not stream, the reader is at end of file at once.
///
/// Read from one thread at a time, until end of file or until the run is
/// cancelled. Then call ``ToolProcessRun/waitBlocking()`` or
/// ``ToolProcessRun/result()``, which closes the read end and folds a failed
/// read into the result. A run whose process is blocked on a full pipe never
/// ends, so never wait for it before reading or cancelling.
public final class ToolProcessOutputStream: Sendable {
    private struct Descriptors {
        var read: Int32 = -1
        var wakeRead: Int32 = -1
        var wakeWrite: Int32 = -1
        var closed = false
    }

    private let descriptors = Mutex(Descriptors())
    private let readFailedFlag = Atomic<Bool>(false)
    private let cutShortFlag = Atomic<Bool>(false)

    init() {}

    deinit {
        close()
    }

    /// True when a read failed with an error other than EINTR, so the bytes
    /// after it are missing.
    public var readFailed: Bool {
        readFailedFlag.load(ordering: .acquiring)
    }

    /// True when the run ended with the pipe empty but still open, because
    /// a process outside the run's group and tree held it, so the reader
    /// stopped without end of file.
    public var endedWithoutEndOfFile: Bool {
        cutShortFlag.load(ordering: .acquiring)
    }

    /// Reads up to `count` bytes, blocking the calling thread until some
    /// arrive. Returns empty data at end of file, after a read error, or once
    /// the run has ended and nothing is left in the pipe. Never call it on
    /// the main thread.
    public func read(upTo count: Int) -> Data {
        precondition(count > 0, "read(upTo:) needs a positive count")
        let (fd, wake) = descriptors.withLock { ($0.closed ? -1 : $0.read, $0.wakeRead) }
        guard fd >= 0 else { return Data() }
        var data = Data(count: count)
        while true {
            if wake >= 0 {
                var fds = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    readFailedFlag.store(true, ordering: .releasing)
                    return Data()
                }
                if fds[0].revents == 0 {
                    // Only the wake is ready. The run is over, every process
                    // of it has closed the pipe, and no byte is buffered.
                    cutShortFlag.store(true, ordering: .releasing)
                    return Data()
                }
            }
            let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            if got > 0 {
                data.count = got
                return data
            }
            if got == 0 { return Data() }
            if errno == EINTR { continue }
            readFailedFlag.store(true, ordering: .releasing)
            return Data()
        }
    }

    /// Reads on a GCD thread of its own until end of file or until `consume`
    /// returns false, so an async caller never parks a cooperative thread on
    /// the pipe. Returns the final state.
    public func drain<State: Sendable>(
        _ initial: State,
        chunkSize: Int = 64 * 1024,
        _ consume: @escaping @Sendable (inout State, Data) -> Bool
    ) async -> State {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "org.lungfish.tool-process.stream-reader", qos: .userInitiated).async {
                var state = initial
                while true {
                    let chunk = self.read(upTo: chunkSize)
                    if chunk.isEmpty || !consume(&state, chunk) { break }
                }
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - Owned by the run

    /// Takes the read end of the stdout pipe once the process is spawned.
    func attach(_ fd: Int32) {
        // The wake pipe lets a blocked read return once the run is over. If
        // it cannot be made, reads simply block until end of file.
        let wake = try? ToolProcessDescriptors.makePipe()
        if let wake {
            ToolProcessDescriptors.setNonBlocking(wake.write)
        }
        descriptors.withLock {
            $0.read = fd
            $0.wakeRead = wake?.read ?? -1
            $0.wakeWrite = wake?.write ?? -1
        }
    }

    /// Wakes a blocked reader once the run is over.
    func runEnded() {
        descriptors.withLock { state in
            guard !state.closed, state.wakeWrite >= 0 else { return }
            var byte: UInt8 = 1
            _ = Darwin.write(state.wakeWrite, &byte, 1)
        }
    }

    /// Closes every descriptor. Safe to call more than once.
    func close() {
        let fds = descriptors.withLock { state -> [Int32] in
            guard !state.closed else { return [] }
            state.closed = true
            return [state.read, state.wakeRead, state.wakeWrite].filter { $0 >= 0 }
        }
        fds.forEach { _ = Darwin.close($0) }
    }

    /// `result` with this reader's failures folded in, so a caller checks
    /// ``ToolProcessResult/outputComplete`` alone, as for any other output.
    func folded(into result: ToolProcessResult) -> ToolProcessResult {
        let readFailed = self.readFailed
        let cutShort = endedWithoutEndOfFile
        guard readFailed || cutShort else { return result }
        return ToolProcessResult(
            label: result.label,
            pid: result.pid,
            termination: result.termination,
            stop: result.stop,
            stdout: result.stdout,
            stderr: result.stderr,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated,
            outputDrainTimedOut: result.outputDrainTimedOut || cutShort,
            outputReadFailed: result.outputReadFailed || readFailed,
            wallTime: result.wallTime
        )
    }
}
