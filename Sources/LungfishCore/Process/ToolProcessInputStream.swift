// ToolProcessInputStream.swift - The caller's writer of a streamed ToolProcess stdin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Standard input of a run whose spec sets ``ToolProcessInput/stream``,
/// written by the caller while the process runs.
///
/// Each write hands its bytes to the run's own stdin writer, the one that
/// feeds ``ToolProcessInput/data(_:)``. It writes nonblocking on the run's
/// queue with SIGPIPE off for the pipe, so a process that stops reading ends
/// the write with ``WriteError/readerGone`` and never kills the app. A write
/// returns once the pipe took its last byte, so the process holds the caller
/// back whenever it reads slower than the caller writes, and a stream of
/// gigabytes needs only the caller's own chunk. ``writeBlocking(_:)`` waits on
/// the calling thread and ``write(_:)`` suspends without holding a thread of
/// the cooperative pool. ``close()`` gives the process end of file. When the
/// spec does not stream stdin, the writer is closed from the start.
///
/// Write from one thread or task at a time, then close, then wait for the
/// run with ``ToolProcessRun/waitBlocking()`` or ``ToolProcessRun/result()``.
/// A process that reads to end of file never ends while the writer stays
/// open, so close it or cancel the run before waiting. Cancelling the run, or
/// a limit, terminates the process tree, and a write still waiting then
/// returns ``WriteError/readerGone``. Cancelling the task of a waiting
/// ``write(_:)`` does not end the write, so cancel the run. Once the last
/// reference to this writer (and so to its ``ToolProcessRun``) is gone, the
/// writer closes, so a process reading to end of file is never left waiting.
public final class ToolProcessInputStream: Sendable {
    /// Why a write did not hand all of its bytes to the process.
    public enum WriteError: Error, Sendable, Equatable {
        /// Nothing reads the pipe any more, because the process closed its
        /// stdin, exited, never launched or was stopped. The bytes the pipe
        /// had not taken are dropped, and the run's result says how the
        /// process ended.
        case readerGone
        /// The writer was closed before this write, or the spec does not
        /// stream stdin, so nothing was written.
        case closed
        /// A write failed with this error number, which is not EPIPE, EAGAIN
        /// or EINTR, and the stream ended.
        case writeFailed(errno: Int32)
    }

    let channel: ToolProcessInputChannel

    init(_ channel: ToolProcessInputChannel) {
        self.channel = channel
    }

    deinit {
        channel.close()
    }

    /// Writes all of `data`, blocking the calling thread until the pipe took
    /// the last byte. Never call it on the main thread.
    ///
    /// - Throws: ``WriteError``. The process is not stopped by it.
    public func writeBlocking(_ data: Data) throws(WriteError) {
        ToolProcessMainThreadGuard.check("writeBlocking")
        let waiter = ToolProcessWriteWaiter()
        channel.write(data) { waiter.finish($0) }
        if let error = waiter.wait() {
            throw error
        }
    }

    /// Writes all of `data`, suspending until the pipe took the last byte.
    /// No thread waits meanwhile.
    ///
    /// - Throws: ``WriteError``. The process is not stopped by it.
    public func write(_ data: Data) async throws(WriteError) {
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<WriteError?, Never>) in
            channel.write(data) { continuation.resume(returning: $0) }
        }
        if let error {
            throw error
        }
    }

    /// Closes the writer once the bytes already written reach the pipe,
    /// which gives the process end of file. Safe to call more than once.
    public func close() {
        channel.close()
    }
}

/// The writer side behind a streamed stdin. The run attaches its stdin
/// feeder once the first stage is spawned, and the caller's
/// ``ToolProcessInputStream`` writes through it and closes it. A write
/// before a feeder is attached finds no process to read it, because the run
/// spawns before it hands out the writer.
final class ToolProcessInputChannel: Sendable {
    private struct State {
        var feeder: ToolProcessInputFeeder?
        var closed: Bool
    }

    private let state: Mutex<State>

    /// A channel for a spec that does not stream stdin is closed from the start.
    init(streams: Bool) {
        state = Mutex(State(feeder: nil, closed: !streams))
    }

    /// Takes the run's feeder once the process is spawned. A writer closed
    /// before then gives the process end of file now.
    func attach(_ feeder: ToolProcessInputFeeder) {
        let closed = state.withLock { state -> Bool in
            state.feeder = feeder
            return state.closed
        }
        if closed {
            feeder.finishInput()
        }
    }

    func write(_ data: Data, completion: @escaping ToolProcessInputFeeder.Completion) {
        let target = state.withLock { state -> Result<ToolProcessInputFeeder, ToolProcessInputStream.WriteError> in
            if state.closed { return .failure(.closed) }
            guard let feeder = state.feeder else { return .failure(.readerGone) }
            return .success(feeder)
        }
        switch target {
        case .success(let feeder):
            feeder.enqueue(data, completion: completion)
        case .failure(let refusal):
            completion(refusal)
        }
    }

    /// Closes the writer. Safe to call more than once.
    func close() {
        let feeder = state.withLock { state -> ToolProcessInputFeeder? in
            guard !state.closed else { return nil }
            state.closed = true
            return state.feeder
        }
        feeder?.finishInput()
    }
}

/// One blocking write's wait for its completion.
private final class ToolProcessWriteWaiter: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let outcome = Mutex<ToolProcessInputStream.WriteError?>(nil)

    func finish(_ error: ToolProcessInputStream.WriteError?) {
        outcome.withLock { $0 = error }
        done.signal()
    }

    func wait() -> ToolProcessInputStream.WriteError? {
        done.wait()
        return outcome.withLock { $0 }
    }
}
