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
/// The filter reports how many times the signal was generated since its last read and clears that count when it
/// does (`EV_CLEAR`), so the latch adds each report to a count of its own (Phase 2.10 lane FXS2). The count holds
/// after ``finish()`` closed the queue, until the next ``begin()``, because a leaf reads the flag after the run
/// ended its instance. The kernel merges posts that wait for one thread into a single delivery, so the count can
/// stay above the number of times the handler ran. A queue that cannot be made leaves the handler's count as the
/// only source.
///
/// So ``SIGTERMCancellation/end()`` waits on the count for a bounded time only. A count still short after it, which
/// cannot tell a merged post from one a thread has yet to take, sends `end()` to take every post still pending with
/// ``SIGTERMPendingPosts``, which changes no action (Phase 2.13 lane 13.18, SW22). The SIGTERM that drain posts at its
/// own thread is not one the filter notes.
private final class SIGTERMPostLatch: Sendable {
    private struct State {
        var queue: Int32 = -1
        var posts = 0
    }

    private let state = Mutex(State())

    /// Clears the count and starts watching, in place of any queue an earlier instance left open.
    func begin() {
        state.withLock { state in
            if state.queue >= 0 { close(state.queue) }
            state.posts = 0
            state.queue = Self.makeQueue()
        }
    }

    /// How many SIGTERMs the kernel posted since ``begin()``. It reads the queue first, so a post is counted at once.
    var posts: Int {
        state.withLock { state in
            if state.queue >= 0 { state.posts += Self.reports(state.queue) }
            return state.posts
        }
    }

    /// Whether a SIGTERM was posted since ``begin()``.
    var occurred: Bool { posts > 0 }

    /// Counts what the queue noted and closes it. The count stays until the next ``begin()``.
    func finish() {
        state.withLock { state in
            guard state.queue >= 0 else { return }
            state.posts += Self.reports(state.queue)
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

    /// How many posts the queue holds, which reading it clears. An event stands for at least one post.
    private static func reports(_ queue: Int32) -> Int {
        var event = kevent()
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        guard kevent(queue, nil, 0, &event, 1, &immediately) > 0 else { return 0 }
        return max(1, Int(event.data))
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

/// Takes every SIGTERM still pending on a thread of this process and changes no action, for
/// ``SIGTERMCancellation/end()`` (Phase 2.13 lane 13.18, SW22). Writing SIG_IGN drops them too, but a thread that
/// found a post pending just before reads the action a moment later and calls address 1 (FX47 (a2)).
///
/// The kernel keeps each pending signal on one thread, and `sigwait` takes one off whichever thread holds it. It takes
/// it under the lock that a delivering thread holds from the moment it finds the signal pending until it has read the
/// action. So each post is taken here before any thread found it, or its thread has already read the action in place,
/// which is still the ending instance's handler, and that handler only counts it.
///
/// `sigwait` waits while nothing is pending, so the drain first posts one SIGTERM at its own thread and stops once that
/// one is gone. The kernel's `sigwait` looks at the threads in the order they were made and takes the first post it
/// finds. The drain runs on a thread made for it, the newest, so it takes every post that waits on an older thread
/// before its own, and every thread that can hold a post sent before `end()` is older. A post sent while the drain runs
/// is a fresh one, and it may reach the action put back. `sigpending` shows only the calling thread's own posts, which
/// is how the drain sees that its own is gone. The drain asks that no other code writes SIGTERM's action while `end()`
/// runs, as the one-instance rule of ``SIGTERMCancellation`` already does, since an ignore written between its check
/// and its `sigwait` would drop its own post and leave it waiting.
///
/// Known limits. The drain rests on kernel behaviour measured on macOS 26 (Darwin 25.6.0) and on no older release.
/// First, `sigwait` takes a post off the oldest thread that holds one. `testEndDropsAPostThatIsStillPending` pins that
/// for a post parked on the calling thread, and no test pins it for another thread, because a test may not hold a post
/// on another thread. If it failed, a post would reach the action put back. Second, an ignored SIGTERM drops the
/// drain's own post, so the drain stops before its first `sigwait`. The tests that end an instance under an ignore run
/// through it, and a kernel that kept the post would only make the drain take it at once. Third, the kqueue filter
/// does not note a signal raised at one thread, which `testEndDropsAPostThatIsStillPending` pins through
/// ``SIGTERMCancellation/signalCaught``.
private enum SIGTERMPendingPosts {
    /// Takes them on a thread made for the drain. Should no thread be made, it takes the posts parked on the calling
    /// thread, which `sigwait` returns at once.
    static func takeAll() {
        var thread: pthread_t?
        let made = pthread_create(&thread, nil, { _ in
            SIGTERMPendingPosts.takeFromTheNewestThread()
            return nil
        }, nil)
        guard made == 0, let thread else {
            takeThosePendingOnThisThread()
            return
        }
        pthread_join(thread, nil)
    }

    /// Runs on the drain's own thread. It blocks SIGTERM here, posts one at this thread and takes posts until that one
    /// is gone, at most 256 times so that a flood of fresh SIGTERMs cannot hold `end()`. It calls `sigwait` only while
    /// its own post waits, so the call returns at once. While SIGTERM is ignored the kernel drops that post as it drops
    /// every other, and nothing can be pending anywhere, so the drain stops before its first `sigwait`.
    private static func takeFromTheNewestThread() {
        var sigterm = sigtermOnly()
        pthread_sigmask(SIG_BLOCK, &sigterm, nil)
        guard pthread_kill(pthread_self(), SIGTERM) == 0,
              SIGTERMCancellation.sigtermIsPendingOnThisThread() else { return }
        for _ in 0..<256 {
            var taken: Int32 = 0
            _ = sigwait(&sigterm, &taken)
            if !SIGTERMCancellation.sigtermIsPendingOnThisThread() { return }
        }
    }

    /// Takes the posts parked on the calling thread, at most 256 times. A post waits there only while the thread
    /// blocks SIGTERM, and `sigwait` asks for that, so a thread that does not block it is left alone.
    private static func takeThosePendingOnThisThread() {
        var sigterm = sigtermOnly()
        var mask = sigset_t()
        pthread_sigmask(SIG_SETMASK, nil, &mask)
        guard sigismember(&mask, SIGTERM) == 1 else { return }
        var takes = 0
        while takes < 256, SIGTERMCancellation.sigtermIsPendingOnThisThread() {
            var taken: Int32 = 0
            _ = sigwait(&sigterm, &taken)
            takes += 1
        }
    }

    private static func sigtermOnly() -> sigset_t {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGTERM)
        return set
    }
}

#if DEBUG
/// A test seam, compiled into debug builds only. While a task binds these, ``SIGTERMCancellation/end()`` reports what
/// it does. They read nothing from the signal and change nothing, so a test can see which writes `end()` makes, and
/// hold its wait open, without a kernel race to catch them.
enum SIGTERMEndTrace {
    /// Called with the address of each action `end()` gives SIGTERM, just before it writes it (0 is SIG_DFL and 1
    /// is SIG_IGN).
    @TaskLocal static var action: (@Sendable (UInt) -> Void)?

    /// Called at each poll of the wait for the handler to run, before `end()` sleeps. A test runs the handler here.
    @TaskLocal static var wait: (@Sendable () -> Void)?
}
#endif

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
    /// The kernel delivers a signal in two steps. A thread finds the signal pending, and a moment later it reads
    /// the action to call. An action changed in between is the one called, and SIG_IGN read there is a call to
    /// address 1, which ends the process by SIGBUS (FX47 (a2)). So `end()` writes no SIG_IGN to drop a post
    /// (Phase 2.13 lane 13.18, SW22). The one action it writes is the one it puts back. In the CLI that is a handler,
    /// since `CLITerminationSignals` sets one before any command runs, and a delivery that reads it calls that. A
    /// process that ignored SIGTERM before the instance began, as the unit tests do around their runs, gets SIG_IGN
    /// back, so a test of that kind waits for the handler to run before it ends the instance.
    ///
    /// A post that is still pending when the instance ends must not reach the action put back either. In the CLI
    /// that action is the one of `CLITerminationSignals`, which ends the process by signal 15, so the command
    /// would die on a SIGTERM it had already answered. So `end()` first lets every post the kernel noted run this
    /// handler, polling each millisecond for at most 250 ms. A handler that has run proves that its delivery is
    /// over. The usual cancel, one post that the handler took long before the end, finds the count whole and puts
    /// the earlier action back at once. When a noted post went untaken for the whole bound, or one is parked on the
    /// calling thread, `end()` first takes every SIGTERM still pending in the process off its thread with
    /// ``SIGTERMPendingPosts``, which changes no action, and this handler stays in place until it is done. An
    /// untaken post is one the kernel merged with another, one sent while SIGTERM was ignored, one blocked on a
    /// thread, or one whose thread did not run for the whole bound on a busy machine. The kernel's note does not
    /// cover a post parked on the calling thread, since it was raised at a thread, so `end()` asks the thread. A post
    /// the kernel noted is kept by ``signalCaught``.
    func end() {
        guard !ended else { return }
        ended = true
        // A handler that runs from here on only counts. It writes no byte, and a second SIGTERM no longer ends
        // the process.
        sigtermPipeWriteEnd.store(-1, ordering: .sequentiallyConsistent)
        secondSIGTERMEndsProcess.store(false, ordering: .sequentiallyConsistent)
        let everyPostRanTheHandler = Self.waitForEveryPostToRunTheHandler()
        if !everyPostRanTheHandler || Self.sigtermIsPendingOnThisThread() {
            SIGTERMPendingPosts.takeAll()
        }
        Self.setAction(previousHandler ?? SIG_DFL)
        sigtermPosts.finish()
        source.cancel()
    }

    /// Waits until the handler has run once for each SIGTERM the kernel noted, polling each millisecond for at
    /// most 250 ms. Returns whether it has. The bound is a time, not a count of polls, because a sleep can run
    /// long on a busy machine.
    private static func waitForEveryPostToRunTheHandler() -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while caughtSIGTERMs.load(ordering: .sequentiallyConsistent) < sigtermPosts.posts {
            guard ContinuousClock.now < deadline else { return false }
            #if DEBUG
            SIGTERMEndTrace.wait?()
            #endif
            usleep(1_000)
        }
        return true
    }

    /// Whether a SIGTERM is pending on this thread, which can only be one that is blocked here.
    fileprivate static func sigtermIsPendingOnThisThread() -> Bool {
        var pending = sigset_t()
        sigemptyset(&pending)
        guard sigpending(&pending) == 0 else { return false }
        return sigismember(&pending, SIGTERM) == 1
    }

    /// Gives SIGTERM `action`. A debug build first tells ``SIGTERMEndTrace`` what it is about to write.
    private static func setAction(_ action: sig_t?) {
        #if DEBUG
        SIGTERMEndTrace.action?(unsafeBitCast(action, to: UInt.self))
        #endif
        signal(SIGTERM, action)
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
