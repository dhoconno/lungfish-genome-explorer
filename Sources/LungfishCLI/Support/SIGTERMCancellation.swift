// SIGTERMCancellation.swift - Turns SIGTERM into a cancel so a command's cleanup runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization

/// The SIGTERMs caught since the current `SIGTERMCancellation` started.
/// A signal handler can only reach global state, and an atomic is safe to
/// change from inside one.
private let caughtSIGTERMs = Atomic<Int>(0)

/// Whether a second SIGTERM ends the process at once.
private let secondSIGTERMEndsProcess = Atomic<Bool>(false)

/// The write end of `SIGTERMPipe`, or -1 while no instance is listening.
private let sigtermPipeWriteEnd = Atomic<Int32>(-1)

/// The SIGTERMs the kernel posted to this process since the current `SIGTERMCancellation` began.
private let sigtermPosts = SIGTERMPostLatch()

/// Notes every SIGTERM the kernel posts to this process, at the moment it posts it and whether or not a handler
/// has run (Phase 2.10 lane FXS, SWIFT Finding 2 of review A54). The kernel notes a post at the `kill`, and a
/// thread takes it and runs the handler later, so a read of the handler's count between the two sees no signal.
/// A kqueue signal filter coexists with the handler and records a signal even when its action is to ignore it.
/// It notes a signal sent to the process, as `kill` and `killpg` send it, and not one sent to a single thread.
///
/// The filter clears an event when it reports one (`EV_CLEAR`), so a read that saw a post latches it. The latch
/// holds after ``finish()`` closed the queue, until the next ``begin()``, because a leaf reads the flag after the
/// run ended its instance. A queue that cannot be made leaves the handler's count as the only source.
private final class SIGTERMPostLatch: Sendable {
    private struct State {
        var queue: Int32 = -1
        var seen = false
    }

    private let state = Mutex(State())

    /// Clears the latch and starts watching, in place of any queue an earlier instance left open.
    func begin() {
        state.withLock { state in
            if state.queue >= 0 { close(state.queue) }
            state.seen = false
            state.queue = Self.makeQueue()
        }
    }

    /// Whether a SIGTERM was posted since ``begin()``.
    var occurred: Bool {
        state.withLock { state in
            if !state.seen, state.queue >= 0, Self.reports(state.queue) { state.seen = true }
            return state.seen
        }
    }

    /// Latches what the queue noted and closes it. The latch keeps the answer.
    func finish() {
        state.withLock { state in
            guard state.queue >= 0 else { return }
            if Self.reports(state.queue) { state.seen = true }
            close(state.queue)
            state.queue = -1
        }
    }

    private static func makeQueue() -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else { return -1 }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC) // tools the command launches do not inherit it
        var change = kevent(
            ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) >= 0 else {
            close(queue)
            return -1
        }
        return queue
    }

    /// Whether the queue holds a post, which reading it clears.
    private static func reports(_ queue: Int32) -> Bool {
        var event = kevent()
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        return kevent(queue, nil, 0, &event, 1, &immediately) > 0
    }
}

/// Counts the SIGTERM and writes one byte to the pipe. Only
/// async-signal-safe calls are made here.
private func handleSIGTERM(_ signalNumber: Int32) {
    let savedErrno = errno
    let (_, count) = caughtSIGTERMs.add(1, ordering: .sequentiallyConsistent)
    let writeEnd = sigtermPipeWriteEnd.load(ordering: .sequentiallyConsistent)
    if writeEnd >= 0 {
        var byte: UInt8 = 1
        // The write end does not block. A full pipe already holds a wake-up.
        _ = write(writeEnd, &byte, 1)
    }
    if count >= 2, secondSIGTERMEndsProcess.load(ordering: .sequentiallyConsistent) {
        // The default action ends the process once this handler returns.
        // The signal goes to the process, because raise() is pthread_kill on
        // this thread and fails with ENOTSUP on a dispatch worker thread.
        signal(SIGTERM, SIG_DFL)
        kill(getpid(), SIGTERM)
    }
    errno = savedErrno
}

/// The pipe the handler writes to. A byte written before the read source is
/// registered stays in the pipe, so the source still sees it. A signal
/// source would miss a SIGTERM posted before it was registered.
///
/// It is made once and never closed, so a handler that is still running
/// while an instance ends can never write to a reused descriptor.
private enum SIGTERMPipe {
    static let ends: (read: Int32, write: Int32)? = {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // tools the command launches do not inherit it
        }
        return (fds[0], fds[1])
    }()

    /// Reads every byte waiting in the pipe.
    static func drain(_ readEnd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(readEnd, &buffer, buffer.count) > 0 {}
    }
}

/// While it is active, SIGTERM cancels one task instead of ending the
/// process, so the task's own cleanup (its `defer` blocks) runs before the
/// command exits.
///
/// The window's Operations panel stops `lungfish-cli import fastq` with
/// SIGTERM and kills it only after a grace period. Without this the CLI died
/// at once and left its hidden `.building-` bundle and its workspace behind.
///
/// The signal is caught with a handler, not ignored. A caught signal goes
/// back to its default action in the tools the command launches, so they
/// still stop on SIGTERM. An ignored one would stay ignored in them.
///
/// Signal handling is process-wide, so only one instance may be active at a
/// time.
final class SIGTERMCancellation {
    private let source: DispatchSourceProtocol
    /// The SIGTERM handler in place before this one, such as the CLI-wide
    /// one of `CLITerminationSignals`, put back by ``end()``.
    private let previousHandler: sig_t?
    private var ended = false

    /// Starts turning SIGTERM into `cancel()` calls.
    ///
    /// - Parameters:
    ///   - secondSignalEndsProcess: When true, a second SIGTERM gets the
    ///     default action back and ends the process at once, so `kill` twice
    ///     or a timeout tool still stops a command whose cleanup hangs.
    ///   - beforeListening: Runs after the handler is in place and before the
    ///     dispatch source exists. Tests send a SIGTERM here.
    ///   - cancel: Called on a background queue for a SIGTERM. It may be
    ///     called more than once.
    init(
        secondSignalEndsProcess: Bool = false,
        beforeListening: () -> Void = {},
        cancel: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue.global(qos: .userInitiated)
        let ends = SIGTERMPipe.ends
        if let ends { SIGTERMPipe.drain(ends.read) } // nothing from an earlier instance
        // Watch for posts before the handler goes in, so no SIGTERM sent from here on goes unseen.
        sigtermPosts.begin()
        // Touch all three atomics before signal() installs the handler. A
        // global is set up lazily on its first use, and that set-up is not
        // async-signal-safe, so it must never first happen inside the handler.
        caughtSIGTERMs.store(0, ordering: .sequentiallyConsistent)
        secondSIGTERMEndsProcess.store(secondSignalEndsProcess, ordering: .sequentiallyConsistent)
        sigtermPipeWriteEnd.store(ends?.write ?? -1, ordering: .sequentiallyConsistent)
        // signal() fails only for an invalid signal number, never for SIGTERM.
        previousHandler = signal(SIGTERM, handleSIGTERM)
        beforeListening()
        if let ends {
            let readSource = DispatchSource.makeReadSource(fileDescriptor: ends.read, queue: queue)
            readSource.setEventHandler {
                SIGTERMPipe.drain(ends.read)
                cancel()
            }
            source = readSource
        } else {
            // Without a pipe (no descriptors left) a signal source is the best
            // there is. It misses only a SIGTERM posted before it listens.
            let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            signalSource.setEventHandler(handler: cancel)
            source = signalSource
        }
        source.resume()
    }

    /// Starts turning SIGTERM into a cancel of `task`.
    convenience init<Success: Sendable>(
        cancelling task: Task<Success, Never>,
        secondSignalEndsProcess: Bool = false
    ) {
        self.init(secondSignalEndsProcess: secondSignalEndsProcess) { task.cancel() }
    }

    /// Starts turning SIGTERM into a cancel of a task that may not exist yet.
    convenience init<Success: Sendable>(
        cancelling target: PendingTaskCancel<Success>,
        secondSignalEndsProcess: Bool = false
    ) {
        self.init(secondSignalEndsProcess: secondSignalEndsProcess) { target.cancel() }
    }

    /// Whether a SIGTERM was caught or posted since the current instance started. The handler counts
    /// it before anything else runs, and the kernel notes a post at the `kill`, so this is true before
    /// the cancel reaches the task and also before any thread has run the handler. A tool child that
    /// got the same signal can end first, and the command still reads its own SIGTERM as the cancel it
    /// answers. It stays true after ``end()`` until the next instance starts.
    static var signalCaught: Bool {
        caughtSIGTERMs.load(ordering: .sequentiallyConsistent) > 0 || sigtermPosts.occurred
    }

    /// Gives SIGTERM back the handler it had before, or its default action.
    ///
    /// SIGTERM is ignored for a moment first. A post that is still pending was sent while this instance
    /// listened, and the thread that takes it can run after the earlier action is back. In the CLI that
    /// action is the one of `CLITerminationSignals`, which ends the process by signal 15, so the command
    /// would die on a SIGTERM it had already answered. Ignoring a signal drops a pending one. A post the
    /// kernel noted is kept by ``signalCaught``.
    func end() {
        guard !ended else { return }
        ended = true
        signal(SIGTERM, SIG_IGN)
        signal(SIGTERM, previousHandler ?? SIG_DFL)
        sigtermPosts.finish()
        secondSIGTERMEndsProcess.store(false, ordering: .sequentiallyConsistent)
        sigtermPipeWriteEnd.store(-1, ordering: .sequentiallyConsistent)
        source.cancel()
    }

    deinit {
        end()
    }
}

/// The task a SIGTERM cancels, for a command that listens before it starts
/// the task. A SIGTERM caught before `attach(_:)` is kept, and attaching
/// then cancels the task at once, so no SIGTERM is lost in between.
final class PendingTaskCancel<Success: Sendable>: Sendable {
    private struct State {
        var task: Task<Success, Never>?
        var requested = false
    }

    private let state = Mutex(State())

    /// Whether a cancel has been asked for.
    var cancelRequested: Bool { state.withLock { $0.requested } }

    /// Cancels the task, or the task attached later.
    func cancel() {
        state.withLock { state in
            state.requested = true
            state.task?.cancel()
        }
    }

    /// Sets the task, and cancels it at once if a cancel was asked for.
    func attach(_ task: Task<Success, Never>) {
        state.withLock { state in
            state.task = task
            if state.requested { task.cancel() }
        }
    }
}
