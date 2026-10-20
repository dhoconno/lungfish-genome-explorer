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
        // Close-on-exec keeps a process launched elsewhere in the app from
        // inheriting this pipe and holding it open. pipe() takes no flags on
        // Darwin, so a Foundation Process spawned on another thread between
        // pipe() and the fcntl below can still inherit it. ToolProcess's own
        // spawns use POSIX_SPAWN_CLOEXEC_DEFAULT and cannot. The window
        // closes once the remaining Foundation Process spawns, which
        // scripts/ratchets/process-spawn.sh counts, move to ToolProcess.
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

    /// A close-on-exec copy of a descriptor the caller owns, above 2, for the
    /// child to write. The caller's descriptor stays open and unchanged, and
    /// the copy shares its open file, so nothing is reopened by path.
    static func duplicate(_ fd: Int32) throws(OpenError) -> Int32 {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else {
            throw OpenError(reason: "Could not duplicate descriptor \(fd) for the child. \(lastErrorText())")
        }
        return copy
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
                    // The bytes are kept and framed straight from the read
                    // buffer, so each chunk is copied once, into the capture.
                    let buffer = drain.buffer
                    let lines = buffer.withUnsafeBytes { raw -> [String] in
                        let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<count])
                        Self.keep(chunk, in: &drain, limit: limit)
                        return drain.framer?.append(bytes: chunk) ?? []
                    }
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

    private static func keep(_ chunk: UnsafeRawBufferPointer, in drain: inout DrainState, limit: Int?) {
        guard let base = chunk.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        guard let limit else {
            drain.bytes.append(base, count: chunk.count)
            return
        }
        guard limit > 0 else {
            drain.truncated = true
            return
        }
        drain.bytes.append(base, count: chunk.count)
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

/// Writes a child's stdin pipe, the bytes of ``ToolProcessInput/data(_:)``
/// and each write of the ``ToolProcessInputStream`` of a
/// ``ToolProcessInput/stream`` stdin.
///
/// Writes are nonblocking and the pipe ignores SIGPIPE, so a child that exits
/// without reading everything ends the feed instead of killing the app or
/// blocking a thread. Bytes wait here only while the pipe is full, and the
/// write source is suspended while none wait. Each chunk's completion runs
/// once, with nil when the pipe took its last byte and with the reason
/// otherwise. The source's cancel handler closes the write end, which is what
/// gives the child end of file, and then reports the feed closed.
final class ToolProcessInputFeeder: Sendable {
    typealias Completion = @Sendable (ToolProcessInputStream.WriteError?) -> Void

    private struct Chunk {
        var data: Data
        var offset = 0
        var completion: Completion?
    }

    private struct FeedState {
        var chunks: [Chunk] = []
        /// The write end closes once every chunk is written.
        var finishRequested: Bool
        /// Why the feed ended, once it has. Nothing is written after.
        var ended: ToolProcessInputStream.WriteError?
        var suspended = false
    }

    private enum WriteStep {
        case written
        case pipeFull(offset: Int)
        case failed(ToolProcessInputStream.WriteError)
    }

    private let fd: Int32
    private let source: DispatchSourceWrite
    private let state: Mutex<FeedState>
    private let onClosed: @Sendable () -> Void

    /// Feeds `data` and then closes the write end, or, when `data` is nil,
    /// feeds each chunk ``enqueue(_:completion:)`` hands it until
    /// ``finishInput()``.
    init(fd: Int32, data: Data?, queue: DispatchQueue, onClosed: @escaping @Sendable () -> Void) {
        ToolProcessDescriptors.setNonBlocking(fd)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        self.fd = fd
        var initial = FeedState(finishRequested: data != nil)
        if let data {
            initial.chunks = [Chunk(data: data)]
        }
        self.state = Mutex(initial)
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

    /// Queues `data` behind the chunks already waiting. `completion` runs
    /// once, with nil when the pipe took the last byte, or with why not.
    func enqueue(_ data: Data, completion: @escaping Completion) {
        let refusal = state.withLock { feed -> ToolProcessInputStream.WriteError? in
            if let ended = feed.ended { return ended }
            if feed.finishRequested { return .closed }
            feed.chunks.append(Chunk(data: data, completion: completion))
            resumeIfSuspended(&feed)
            return nil
        }
        if let refusal {
            completion(refusal)
        }
    }

    /// Closes the write end once every queued chunk is written, which gives
    /// the child end of file. Safe to call more than once.
    func finishInput() {
        let cancelNow = state.withLock { feed -> Bool in
            guard feed.ended == nil, !feed.finishRequested else { return false }
            feed.finishRequested = true
            // The source writes the chunks still waiting and then cancels.
            guard feed.chunks.isEmpty else { return false }
            feed.ended = .closed
            resumeIfSuspended(&feed)
            return true
        }
        if cancelNow {
            source.cancel()
        }
    }

    /// Stops feeding and closes the write end, because nothing reads it any
    /// more. A chunk still waiting completes with
    /// ``ToolProcessInputStream/WriteError/readerGone``. Safe to call more
    /// than once.
    func stop() {
        let dropped = state.withLock { feed -> [Completion] in
            // A suspended source never runs its cancel handler.
            resumeIfSuspended(&feed)
            guard feed.ended == nil else { return [] }
            feed.ended = .readerGone
            return Self.takeCompletions(&feed)
        }
        dropped.forEach { $0(.readerGone) }
        source.cancel()
    }

    private func resumeIfSuspended(_ feed: inout FeedState) {
        guard feed.suspended else { return }
        feed.suspended = false
        source.resume()
    }

    private static func takeCompletions(_ feed: inout FeedState) -> [Completion] {
        defer { feed.chunks = [] }
        return feed.chunks.compactMap(\.completion)
    }

    /// Writes what the pipe takes now. Runs on the run's queue.
    private func writeAvailable() {
        typealias Step = (cancel: Bool, written: [Completion], dropped: [Completion], reason: ToolProcessInputStream.WriteError?)
        let step = state.withLock { feed -> Step in
            guard feed.ended == nil else { return (false, [], [], nil) }
            var written: [Completion] = []
            while let chunk = feed.chunks.first {
                switch Self.writeChunk(fd, chunk.data, from: chunk.offset) {
                case .written:
                    feed.chunks.removeFirst()
                    if let completion = chunk.completion {
                        written.append(completion)
                    }
                case .pipeFull(let offset):
                    feed.chunks[0].offset = offset
                    return (false, written, [], nil)
                case .failed(let reason):
                    feed.ended = reason
                    return (true, written, Self.takeCompletions(&feed), reason)
                }
            }
            if feed.finishRequested {
                feed.ended = .closed
                return (true, written, [], nil)
            }
            // Nothing waits, so the source rests until the next chunk.
            feed.suspended = true
            source.suspend()
            return (false, written, [], nil)
        }
        step.written.forEach { $0(nil) }
        if let reason = step.reason {
            step.dropped.forEach { $0(reason) }
        }
        if step.cancel {
            source.cancel()
        }
    }

    private static func writeChunk(_ fd: Int32, _ data: Data, from start: Int) -> WriteStep {
        data.withUnsafeBytes { raw -> WriteStep in
            guard let base = raw.baseAddress else { return .written }
            var position = start
            while position < raw.count {
                let count = Darwin.write(fd, base + position, min(raw.count - position, 64 * 1024))
                let code = errno
                if count > 0 {
                    position += count
                    continue
                }
                if count < 0 && code == EINTR {
                    continue
                }
                if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                    return .pipeFull(offset: position)
                }
                // EPIPE means the reader is gone. Any other error ends the feed too.
                return .failed(count < 0 && code != EPIPE ? .writeFailed(errno: code) : .readerGone)
            }
            return .written
        }
    }
}
