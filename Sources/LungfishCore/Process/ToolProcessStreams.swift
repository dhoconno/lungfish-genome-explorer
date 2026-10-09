// ToolProcessStreams.swift - Descriptors, output drains and stdin feeding for ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import Synchronization

/// File descriptor helpers. ToolProcess owns every descriptor it creates and
/// closes each exactly once. The child's ends are duplicated onto 0, 1 and 2
/// by posix_spawn and closed in the parent right after the spawn, so the only
/// writers left on an output pipe are the child's process group and tree.
enum ToolProcessDescriptors {
    struct OpenError: Error {
        let reason: String
    }

    static func makePipe() throws(OpenError) -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw OpenError(reason: "Could not create a pipe. \(lastErrorText())")
        }
        // Close-on-exec keeps a process launched elsewhere in the app at the
        // same moment from inheriting this pipe and holding it open.
        return (aboveStandardStreams(fds[0]), aboveStandardStreams(fds[1]))
    }

    static func openForReading(_ path: String) throws(OpenError) -> Int32 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw OpenError(reason: "Could not open \(path) for reading. \(lastErrorText())")
        }
        return aboveStandardStreams(fd)
    }

    static func openForWriting(_ path: String) throws(OpenError) -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw OpenError(reason: "Could not open \(path) for writing. \(lastErrorText())")
        }
        return aboveStandardStreams(fd)
    }

    /// Marks `fd` close-on-exec and moves it above 2, so the spawn's dup2
    /// onto 0, 1 and 2 can never overwrite another of the child's descriptors
    /// in an app whose own standard streams are closed.
    private static func aboveStandardStreams(_ fd: Int32) -> Int32 {
        guard fd <= 2 else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            return fd
        }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        guard moved >= 0 else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            return fd
        }
        close(fd)
        return moved
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    static func lastErrorText() -> String {
        String(cString: strerror(errno))
    }
}

/// How a captured stream ended.
struct ToolProcessCapture: Sendable {
    var data: Data
    var truncated: Bool
    /// Closed before end of file, after the drain grace period or a cancellation.
    var abandoned: Bool
    /// A read failed with an error other than EAGAIN or EINTR.
    var readFailed: Bool
}

/// Reads one captured output stream from launch until end of file.
///
/// Reads are nonblocking and driven by a dispatch read source on the run's
/// serial queue into one buffer the drain keeps, so the drain never parks a
/// thread on a pipe and can be abandoned when a lingering descendant keeps
/// the pipe open. Lines are framed only when someone observes them. The
/// source's cancel handler closes the descriptor and then reports the
/// stream closed, so a finished run has no descriptor left open.
final class ToolProcessStreamDrain: Sendable {
    let stream: ToolProcessStream

    private struct DrainState {
        var buffer = [UInt8](repeating: 0, count: ToolProcessStreamDrain.readChunkSize)
        var framer: ProcessOutputLineFramer?
        var bytes = Data()
        var truncated = false
        var closed = false
        var abandoned = false
        var readFailed = false
    }

    static let readChunkSize = 64 * 1024
    private static let readBudgetPerEvent = 1024 * 1024

    private let fd: Int32
    private let limit: Int?
    private let source: DispatchSourceRead
    private let state: Mutex<DrainState>
    private let onLine: (@Sendable (ToolProcessStream, String) -> Void)?
    private let onActivity: @Sendable () -> Void
    private let onClosed: @Sendable () -> Void

    init(
        stream: ToolProcessStream,
        fd: Int32,
        limit: Int?,
        maxLineBytes: Int,
        queue: DispatchQueue,
        onLine: (@Sendable (ToolProcessStream, String) -> Void)?,
        onActivity: @escaping @Sendable () -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        ToolProcessDescriptors.setNonBlocking(fd)
        self.stream = stream
        self.fd = fd
        self.limit = limit
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var initial = DrainState()
        initial.framer = onLine == nil ? nil : ProcessOutputLineFramer(maxLineBytes: maxLineBytes)
        self.state = Mutex(initial)
        self.onLine = onLine
        self.onActivity = onActivity
        self.onClosed = onClosed
    }

    /// Starts reading. Call once.
    func start() {
        let fd = self.fd
        let onClosed = self.onClosed
        source.setEventHandler { [self] in
            readAvailable()
        }
        source.setCancelHandler {
            close(fd)
            onClosed()
        }
        source.activate()
    }

    /// Marks the stream as cut short even if end of file arrives later,
    /// because the run is about to kill the writers that still hold it.
    func markAbandoned() {
        state.withLock { $0.abandoned = true }
    }

    /// Reads what the pipe holds now, then closes the stream without waiting
    /// for end of file. Must run on the run's queue.
    func abandon() {
        guard !isClosed else { return }
        markAbandoned()
        readAvailable()
        finish(readFailed: false)
    }

    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// The bytes kept and how the stream ended.
    func captured() -> ToolProcessCapture {
        state.withLock { drain in
            var data = drain.bytes
            if let limit, data.count > limit {
                data = Data(data.suffix(limit))
            }
            return ToolProcessCapture(
                data: data,
                truncated: drain.truncated,
                abandoned: drain.abandoned,
                readFailed: drain.readFailed
            )
        }
    }

    private enum ReadOutcome {
        case data([String])
        case wouldBlock
        case endOfFile
        case failed
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var budget = Self.readBudgetPerEvent
        while budget > 0 {
            let outcome = readOnce(budget: &budget)
            switch outcome {
            case .data(let lines):
                onActivity()
                if let onLine {
                    for line in lines {
                        onLine(stream, line)
                    }
                }
            case .wouldBlock:
                return
            case .endOfFile:
                finish(readFailed: false)
                return
            case .failed:
                finish(readFailed: true)
                return
            }
        }
    }

    private func readOnce(budget: inout Int) -> ReadOutcome {
        let fd = self.fd
        let limit = self.limit
        let (outcome, count) = state.withLock { drain -> (ReadOutcome, Int) in
            while true {
                let count = drain.buffer.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    let chunk = Data(drain.buffer[0..<count])
                    Self.keep(chunk, in: &drain, limit: limit)
                    let lines = drain.framer?.append(chunk) ?? []
                    return (.data(lines), count)
                }
                if count == 0 {
                    return (.endOfFile, 0)
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return (.wouldBlock, 0)
                default:
                    return (.failed, 0)
                }
            }
        }
        budget -= count
        return outcome
    }

    private static func keep(_ chunk: Data, in drain: inout DrainState, limit: Int?) {
        guard let limit else {
            drain.bytes.append(chunk)
            return
        }
        guard limit > 0 else {
            drain.truncated = true
            return
        }
        drain.bytes.append(chunk)
        if drain.bytes.count > limit {
            drain.truncated = true
            // Trim in batches so a long stream costs amortized linear time.
            if drain.bytes.count > limit + max(limit, readChunkSize) {
                drain.bytes = Data(drain.bytes.suffix(limit))
            }
        }
    }

    private func finish(readFailed: Bool) {
        let lines = state.withLock { drain -> [String]? in
            guard !drain.closed else { return nil }
            drain.closed = true
            drain.readFailed = drain.readFailed || readFailed
            return drain.framer?.finish() ?? []
        }
        guard let lines else { return }
        if let onLine {
            for line in lines {
                onLine(stream, line)
            }
        }
        source.cancel()
    }
}

/// Writes ``ToolProcessInput/data(_:)`` bytes into the child's stdin pipe.
///
/// Writes are nonblocking and the pipe ignores SIGPIPE, so a child that exits
/// without reading everything ends the feed instead of killing the app or
/// blocking a thread. The source's cancel handler closes the write end, which
/// is what gives the child end of file, and then reports the feed closed.
final class ToolProcessInputFeeder: Sendable {
    private let fd: Int32
    private let data: Data
    private let source: DispatchSourceWrite
    private let offset = Mutex(0)
    private let onClosed: @Sendable () -> Void

    init(fd: Int32, data: Data, queue: DispatchQueue, onClosed: @escaping @Sendable () -> Void) {
        ToolProcessDescriptors.setNonBlocking(fd)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        self.fd = fd
        self.data = data
        self.source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        self.onClosed = onClosed
    }

    /// Starts writing. Call once.
    func start() {
        let fd = self.fd
        let onClosed = self.onClosed
        source.setEventHandler { [self] in
            writeAvailable()
        }
        source.setCancelHandler {
            close(fd)
            onClosed()
        }
        source.activate()
    }

    /// Stops feeding and closes the write end. Safe to call more than once.
    func stop() {
        source.cancel()
    }

    private func writeAvailable() {
        var position = offset.withLock { $0 }
        let total = data.count
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                position = total
                return
            }
            while position < total {
                let count = write(fd, base + position, min(total - position, 64 * 1024))
                if count > 0 {
                    position += count
                    continue
                }
                if count < 0 && errno == EINTR {
                    continue
                }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return
                }
                // EPIPE means the reader is gone. Any other error ends the feed too.
                position = total
            }
        }
        offset.withLock { $0 = position }
        if position >= total {
            source.cancel()
        }
    }
}
