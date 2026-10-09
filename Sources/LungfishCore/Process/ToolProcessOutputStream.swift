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
/// read into the result. Closing the stream before the reader reached end of
/// file, while bytes were still unread, makes the output incomplete. A read
/// in progress when the stream closes returns empty data, and the read end
/// closes once it has. A run whose process is blocked on a full pipe never
/// ends, so never wait for it before reading or cancelling. Once the last
/// reference to this reader (and so to its ``ToolProcessRun``) is gone, the
/// read end closes, so a writer gets SIGPIPE instead of blocking forever on a
/// pipe nobody reads, and the run ends and is reaped on its own.
public final class ToolProcessOutputStream: Sendable {
    let channel: ToolProcessStreamChannel

    init(_ channel: ToolProcessStreamChannel) {
        self.channel = channel
    }

    deinit {
        channel.close()
    }

    /// True when a read failed with an error other than EINTR, so the bytes
    /// after it are missing.
    public var readFailed: Bool {
        channel.readFailed
    }

    /// True when the reader stopped without end of file. Either the run
    /// ended with the pipe empty but still open, because a process outside
    /// the run's group and tree held it, or the stream was closed, by
    /// ``ToolProcessRun/result()``, ``ToolProcessRun/waitBlocking()`` or
    /// dropping the run, while bytes were still unread or a writer still
    /// held the pipe.
    public var endedWithoutEndOfFile: Bool {
        channel.endedWithoutEndOfFile
    }

    /// Reads up to `count` bytes, blocking the calling thread until some
    /// arrive. Returns empty data at end of file, after a read error, or once
    /// the run has ended and nothing is left in the pipe. Never call it on
    /// the main thread.
    public func read(upTo count: Int) -> Data {
        precondition(count > 0, "read(upTo:) needs a positive count")
        return channel.read(upTo: count)
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

    /// Closes the read end. Safe to call more than once.
    func close() {
        channel.close()
    }

    /// `error` with this reader's failures folded into the results it
    /// carries. Call it after ``close()``, which settles the flags.
    func folded(into error: ToolProcessError) -> ToolProcessError {
        switch error {
        case .invalidSpec:
            return error
        case .launchFailed(let label, let reason, let results):
            return .launchFailed(label: label, reason: reason, results: results.map(folded(into:)))
        case .timedOut(let timeout, let results):
            return .timedOut(timeout, results: results.map(folded(into:)))
        case .cancelled(let results):
            return .cancelled(results: results.map(folded(into:)))
        }
    }

    /// `result` with this reader's failures folded in, so a caller checks
    /// ``ToolProcessResult/outputComplete`` alone, as for any other output.
    /// Call it after ``close()``, which settles the flags.
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

/// The descriptors and flags behind a streamed stdout. The run attaches the
/// pipe and wakes a blocked reader through it, and the caller's
/// ``ToolProcessOutputStream`` reads and closes it. Only the caller's reader
/// owns the read end, so dropping it closes the pipe even while the run goes on.
///
/// Reads are counted. A close marks the channel closed and wakes a reader
/// blocked in poll, and the last reader out closes the descriptors, so no
/// read ever runs on a descriptor that was closed, or closed and reused. The
/// flags are settled when the channel closes. A close before end of file
/// with bytes still unread, or with a writer still holding the pipe, counts
/// as ending without end of file, so the result cannot pass as complete.
final class ToolProcessStreamChannel: Sendable {
    private struct State {
        var read: Int32 = -1
        var wakeRead: Int32 = -1
        var wakeWrite: Int32 = -1
        var closeRequested = false
        var descriptorsClosed = false
        var activeReads = 0
        var reachedEndOfFile = false
        var readFailed = false
        var endedWithoutEndOfFile = false
        /// Called whenever a read returns bytes.
        var onActivity: (@Sendable () -> Void)?
        /// The read buffer, lent to one read at a time, so a read allocates
        /// only the bytes it returns.
        var spareBuffer: [UInt8]?

        /// Takes every open descriptor for closing, once.
        mutating func takeDescriptors() -> [Int32] {
            guard !descriptorsClosed else { return [] }
            descriptorsClosed = true
            return [read, wakeRead, wakeWrite].filter { $0 >= 0 }
        }
    }

    private enum ReadEnding {
        case bytes
        case endOfFile
        case failed
        case runEnded
        case closed
    }

    private let state = Mutex(State())

    deinit {
        close()
    }

    var readFailed: Bool {
        state.withLock { $0.readFailed }
    }

    var endedWithoutEndOfFile: Bool {
        state.withLock { $0.endedWithoutEndOfFile }
    }

    func read(upTo count: Int) -> Data {
        let entered = state.withLock { state -> (fd: Int32, wake: Int32, onActivity: (@Sendable () -> Void)?, buffer: [UInt8]?)? in
            guard !state.closeRequested, state.read >= 0 else { return nil }
            state.activeReads += 1
            defer { state.spareBuffer = nil }
            return (state.read, state.wakeRead, state.onActivity, state.spareBuffer)
        }
        guard let (fd, wake, onActivity, spare) = entered else { return Data() }
        var buffer = spare.flatMap { $0.count >= count ? $0 : nil } ?? [UInt8](repeating: 0, count: count)
        var data = Data()
        var ending = ReadEnding.failed
        reading: while true {
            if wake >= 0 {
                var fds = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    ending = .failed
                    break reading
                }
                if state.withLock({ $0.closeRequested }) {
                    ending = .closed
                    break reading
                }
                if fds[0].revents == 0 {
                    // Only the wake is ready. The run is over, every process
                    // of it has closed the pipe, and no byte is buffered.
                    ending = .runEnded
                    break reading
                }
            }
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            if got > 0 {
                data = Data(buffer[0..<got])
                ending = .bytes
            } else if got == 0 {
                ending = .endOfFile
            } else if errno == EINTR {
                continue
            } else {
                ending = .failed
            }
            break reading
        }
        leave(ending, returning: buffer)
        guard ending == .bytes else { return Data() }
        onActivity?()
        return data
    }

    /// Ends one read. Flags change only while the channel is open, because
    /// a close settles them, and the last reader out of a closed channel
    /// closes its descriptors.
    private func leave(_ ending: ReadEnding, returning buffer: [UInt8]) {
        let fds = state.withLock { state -> [Int32] in
            state.activeReads -= 1
            state.spareBuffer = buffer
            if !state.closeRequested {
                switch ending {
                case .endOfFile: state.reachedEndOfFile = true
                case .failed: state.readFailed = true
                case .runEnded: state.endedWithoutEndOfFile = true
                case .bytes, .closed: break
                }
            }
            guard state.closeRequested, state.activeReads == 0 else { return [] }
            return state.takeDescriptors()
        }
        fds.forEach { _ = Darwin.close($0) }
    }

    /// Takes the read end of the stdout pipe once the process is spawned.
    /// `onActivity` runs whenever a read returns bytes.
    func attach(_ fd: Int32, onActivity: @escaping @Sendable () -> Void) {
        // The wake pipe lets a blocked read return once the run is over or
        // the channel closes. If it cannot be made, reads simply block until
        // end of file.
        let wake = try? ToolProcessDescriptors.makePipe()
        if let wake {
            ToolProcessDescriptors.setNonBlocking(wake.write)
        }
        let closeNow = state.withLock { state -> Bool in
            guard !state.closeRequested else { return true }
            state.read = fd
            state.wakeRead = wake?.read ?? -1
            state.wakeWrite = wake?.write ?? -1
            state.onActivity = onActivity
            return false
        }
        if closeNow {
            // The caller's reader is already gone, so nobody will read.
            ([fd] + [wake?.read, wake?.write].compactMap { $0 }).forEach { _ = Darwin.close($0) }
        }
    }

    /// Wakes a blocked reader once the run is over.
    func runEnded() {
        state.withLock { state in
            guard !state.descriptorsClosed else { return }
            Self.wake(state.wakeWrite)
        }
    }

    /// Closes the channel and settles its flags. Safe to call more than once.
    /// A reader still inside a read is woken, and the last one out closes the
    /// descriptors.
    func close() {
        let fds = state.withLock { state -> [Int32] in
            guard !state.closeRequested else { return [] }
            state.closeRequested = true
            if state.read >= 0, !state.reachedEndOfFile, !state.readFailed, !Self.atEndOfFile(state.read) {
                state.endedWithoutEndOfFile = true
            }
            guard state.activeReads == 0 else {
                Self.wake(state.wakeWrite)
                return []
            }
            return state.takeDescriptors()
        }
        fds.forEach { _ = Darwin.close($0) }
    }

    private static func wake(_ fd: Int32) {
        guard fd >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(fd, &byte, 1)
    }

    /// True when every writer has closed the pipe and no byte is left in it,
    /// so a reader that stopped early lost nothing. fstat on a pipe reports
    /// the bytes buffered in it.
    private static func atEndOfFile(_ fd: Int32) -> Bool {
        var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&probe, 1, 0) == 1, probe.revents & Int16(POLLHUP) != 0 else { return false }
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_size == 0
    }
}
