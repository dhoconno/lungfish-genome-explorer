// SIGTERMCancellationTests.swift - SIGTERM cancels the import task instead of ending the process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import Synchronization
import LungfishTestSupport
@testable import LungfishCLI

/// Review finding S4-S3: the window stops `lungfish-cli import fastq` with
/// SIGTERM. The CLI died at once and left its staging bundle and workspace.
/// It now turns SIGTERM into a cancel so the import's cleanup runs.
///
/// Re-review finding S6-1: a SIGTERM caught before the dispatch source was
/// registered was lost, so the import was never cancelled.
final class SIGTERMCancellationTests: XCTestCase {

    func testSIGTERMCancelsTheTaskAndTheProcessLivesOn() async throws {
        // A post that outlives `end()` must not end the unit process (review A54 fix 2).
        let earlier = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, earlier) }
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(cancelling: task)
        defer { termination.end() }

        // Sent to this test process. Without the handler it would end it.
        kill(getpid(), SIGTERM)

        let cancelled = await waitUntil(timeout: .seconds(30)) { task.isCancelled }
        XCTAssertTrue(cancelled, "SIGTERM cancels the task")
    }

    /// Re-review finding S7-S2: `import fastq` now listens before it starts
    /// the import task. A SIGTERM caught before the task exists still
    /// cancels it once the task is attached.
    func testASIGTERMBeforeTheTaskExistsCancelsItOnceAttached() async throws {
        let earlier = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, earlier) }
        let target = PendingTaskCancel<Bool>()
        let termination = SIGTERMCancellation(cancelling: target)
        defer { termination.end() }

        kill(getpid(), SIGTERM)
        let caught = await waitUntil(timeout: .seconds(30)) { target.cancelRequested }
        XCTAssertTrue(caught, "the SIGTERM is caught before the task exists")

        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        target.attach(task)
        XCTAssertTrue(task.isCancelled, "attaching the task cancels it at once")
    }

    /// The SIGTERM is sent after the handler is in place and before the
    /// dispatch source is listening. Whenever the handler then runs, its byte
    /// waits in the pipe, so the source still sees it once it listens.
    func testASIGTERMBeforeTheSourceListensStillCancels() async throws {
        let earlier = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, earlier) }
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(beforeListening: { kill(getpid(), SIGTERM) }) {
            task.cancel()
        }
        defer { termination.end() }

        let cancelled = await waitUntil(timeout: .seconds(30)) { task.isCancelled }
        XCTAssertTrue(cancelled, "a SIGTERM caught before the source listens still cancels")
    }

    /// Phase 2.10 FXS (SWIFT, review A54 Finding 2). The kernel notes a SIGTERM at the `kill`, and a thread
    /// takes it and runs the handler later. Under load a leaf can find its tool dead on the group's SIGTERM
    /// and read `signalCaught` between the two, so the flag must read a post the handler has not counted.
    /// SIGTERM is ignored again after the instance began, so no handler can run and the post is all there is
    /// to see. The test ignores SIGTERM first and puts the earlier action back last, so no case can end the
    /// unit process.
    func testAPostReadsAsCaughtBeforeItsHandlerRuns() {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let termination = SIGTERMCancellation { }
        defer { termination.end() }
        signal(SIGTERM, SIG_IGN) // the handler is out of reach from here on
        XCTAssertFalse(SIGTERMCancellation.signalCaught, "nothing was posted yet")

        XCTAssertEqual(kill(getpid(), SIGTERM), 0)

        XCTAssertTrue(SIGTERMCancellation.signalCaught, "the kernel noted the post, so it reads as caught though no handler counted it")
    }

    /// The kernel's signal filter clears an event when it reports it, so the flag keeps what a read saw. It
    /// stays true across reads and after `end()`, because a leaf reads it after the run ended the instance,
    /// and the next instance starts with none.
    func testAPostStaysCaughtAcrossReadsAndEndUntilTheNextInstanceBegins() {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let termination = SIGTERMCancellation { }
        signal(SIGTERM, SIG_IGN) // the handler is out of reach from here on
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        XCTAssertTrue(SIGTERMCancellation.signalCaught)
        XCTAssertTrue(SIGTERMCancellation.signalCaught, "a read did not clear the post")

        termination.end()
        XCTAssertTrue(SIGTERMCancellation.signalCaught, "a leaf reads the flag after the run has ended its instance")

        let next = SIGTERMCancellation { }
        defer { next.end() }
        XCTAssertFalse(SIGTERMCancellation.signalCaught, "a new instance starts with no post")
    }

    /// A post that is still pending when `end()` runs belongs to the instance that ended. It must not reach the
    /// action `end()` puts back, which in the CLI is the handler of `CLITerminationSignals`, and that ends the
    /// process by signal 15. SIGTERM is blocked on this thread and raised at this thread, so the post stays
    /// pending here whichever thread would otherwise take it, and a counting handler stands in for the CLI-wide
    /// one. The kernel drops a pending post when the action becomes SIG_IGN, which `end()` sets when it finds a
    /// post parked on its own thread. The kernel's note of a post does not cover this one, since a kqueue signal
    /// filter notes a signal sent to the process and not one raised at a thread (FXS2).
    func testEndDropsAPostThatIsStillPending() {
        sigtermsCountedForTest.store(0, ordering: .sequentiallyConsistent)
        let original = signal(SIGTERM, countSIGTERMForTest)
        defer { signal(SIGTERM, original) }
        let termination = SIGTERMCancellation { }
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        var unblocked = sigset_t()
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blocked, &unblocked), 0)
        XCTAssertEqual(raise(SIGTERM), 0)

        termination.end()

        XCTAssertEqual(pthread_sigmask(SIG_SETMASK, &unblocked, nil), 0) // a post that survived `end()` runs here
        XCTAssertEqual(
            sigtermsCountedForTest.load(ordering: .sequentiallyConsistent), 0,
            "a pending post reached the action `end()` put back"
        )
    }

    // MARK: - The writes `end()` makes (FXS2, Fix 3 of review FX47)

    /// The CLI's usual cancel, one post that the handler took long before the end. `end()` goes from the
    /// instance's handler to the earlier one and writes no SIG_IGN at all. A delivery that the kernel began under
    /// one action and finishes under SIG_IGN calls address 1 and ends the process by SIGBUS (FX47 (a2)). The
    /// earlier action is a handler, as in the CLI, so a write of SIG_IGN shows in the list.
    func testEndPutsTheActionBackWithNoIgnoreOnceEveryPostRanTheHandler() async {
        let original = signal(SIGTERM, recordSIGTERMForTest) // stands in for the CLI-wide handler
        defer { signal(SIGTERM, original) }
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(cancelling: task)
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        let cancelled = await waitUntil(timeout: .seconds(30)) { task.isCancelled }
        XCTAssertTrue(cancelled, "the handler took the post")

        let ended = ending(termination)

        XCTAssertEqual(ended.actions, [address(of: recordSIGTERMForTest)], "end() wrote an action other than the earlier one")
        XCTAssertEqual(ended.polls, 0, "the count was whole, so end() had nothing to wait for")
    }

    /// An instance that starts after `end()` starts clean, whatever the one before it met (Phase 2.13 lane 13.18 pin).
    /// The first instance ends on a post the kernel noted and no thread took. After that end the calling thread's
    /// signal mask is as it was, no SIGTERM waits on that thread, and the earlier action is back. The next instance
    /// reads no post, its handler takes a fresh one and cancels, and its own end writes only the earlier action.
    func testAnInstanceThatStartsAfterEndStartsClean() async {
        let original = signal(SIGTERM, recordSIGTERMForTest) // stands in for the CLI-wide handler
        defer { signal(SIGTERM, original) }
        let maskBefore = signalMaskOfThisThread()
        let first = SIGTERMCancellation { }
        signal(SIGTERM, SIG_IGN) // the handler is out of reach: the kernel drops the post and only its note remains
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        first.end()

        XCTAssertEqual(signalMaskOfThisThread(), maskBefore, "end() left the calling thread's signal mask as it found it")
        XCTAssertFalse(sigtermIsPendingOnThisThread(), "end() left no SIGTERM waiting on the calling thread")
        XCTAssertEqual(
            address(of: signal(SIGTERM, recordSIGTERMForTest)), address(of: recordSIGTERMForTest),
            "end() put the earlier action back"
        )

        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let next = SIGTERMCancellation(cancelling: task)
        XCTAssertFalse(SIGTERMCancellation.signalCaught, "the next instance starts with no post")
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        let cancelled = await waitUntil(timeout: .seconds(30)) { task.isCancelled }
        XCTAssertTrue(cancelled, "the next instance's handler took a fresh post")

        let ended = ending(next)

        XCTAssertEqual(ended.actions, [address(of: recordSIGTERMForTest)], "end() wrote an action other than the earlier one")
        XCTAssertEqual(ended.polls, 0, "the next instance's count was whole")
    }

    /// The geometry that crashed FX47's run: a post the kernel noted that no thread has run the handler for yet,
    /// while the instance ends. A real thread takes such a post within microseconds, which no test can hold still, so
    /// the test holds it still. The handler is out of reach when the post is sent, so the kernel notes it and drops
    /// it, and `end()` finds the count short. At its first poll the test puts the handler back in reach and raises a
    /// SIGTERM at the waiting thread, which runs the handler once, as a thread that took the post would. `end()`
    /// leaves its wait at once, writes no SIG_IGN, and the earlier action never sees a post.
    func testEndWaitsForAPostThatIsStillBeingTakenAndWritesNoIgnore() {
        sigtermsCountedForTest.store(0, ordering: .sequentiallyConsistent)
        let original = signal(SIGTERM, countSIGTERMForTest)
        defer { signal(SIGTERM, original) }
        let termination = SIGTERMCancellation { }
        let handler = signal(SIGTERM, SIG_IGN) // the instance's handler, out of reach while the post is sent
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)

        let ended = ending(termination) { poll in
            guard poll == 1 else { return }
            signal(SIGTERM, handler) // the handler is back in reach
            raise(SIGTERM) // and the waiting thread runs it
        }

        XCTAssertEqual(ended.actions, [address(of: countSIGTERMForTest)], "end() wrote an action other than the earlier one")
        XCTAssertGreaterThanOrEqual(ended.polls, 1, "end() waited for the handler to run")
        XCTAssertLessThan(ended.polls, 100, "end() left its wait once the handler had run")
        XCTAssertEqual(
            sigtermsCountedForTest.load(ordering: .sequentiallyConsistent), 0,
            "a post reached the action `end()` put back"
        )
    }

    /// A post the kernel noted and no thread takes, such as one sent while SIGTERM was ignored. `end()` waits for it up
    /// to its bound. Then it ignores SIGTERM for the moment between its two writes, to drop whatever may still be
    /// pending, since no thread is taking the post. The wait is bounded by time, not by a count of polls.
    func testEndWaitsAtMostItsBoundForAPostNoThreadTakes() {
        let original = signal(SIGTERM, recordSIGTERMForTest)
        defer { signal(SIGTERM, original) }
        let termination = SIGTERMCancellation { }
        signal(SIGTERM, SIG_IGN) // the handler is out of reach: the kernel drops the post and only its note remains
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)

        let started = ContinuousClock.now
        let ended = ending(termination)
        let waited = started.duration(to: .now)

        XCTAssertEqual(ended.actions, [address(of: SIG_IGN), address(of: recordSIGTERMForTest)])
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200), "end() gave the noted post time to run the handler")
        // The bound is 250 ms. The margin is wide because a sleep can run long when every core is busy.
        XCTAssertLessThan(waited, .seconds(5), "end() waits at most its bound")
    }

    /// The latch counts posts and does not only flag one. The handler took the first post. The second was sent with
    /// the handler out of reach, so the kernel noted two posts and the handler ran once, and `end()` finds the count
    /// short.
    func testEveryNotedPostCountsAgainstTheRunsOfTheHandler() async {
        let original = signal(SIGTERM, recordSIGTERMForTest)
        defer { signal(SIGTERM, original) }
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(cancelling: task)
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        let cancelled = await waitUntil(timeout: .seconds(30)) { task.isCancelled }
        XCTAssertTrue(cancelled, "the handler took the first post")
        signal(SIGTERM, SIG_IGN) // the handler is out of reach from here on
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)

        let started = ContinuousClock.now
        let ended = ending(termination)
        let waited = started.duration(to: .now)

        XCTAssertEqual(ended.actions, [address(of: SIG_IGN), address(of: recordSIGTERMForTest)], "two posts, one run of the handler")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200), "end() waited for the second post")
    }

    // MARK: - The leaves' read of the flag (`runCancellingOnSIGTERM`)

    /// Phase 2.10 lane A54 M3 (decision P2, SWIFT 3, S30 note 2), moved here from the class of the watch that
    /// `signalCaught` has replaced. The app signals a leaf's whole group at once, so a tool that got the same
    /// SIGTERM can end the work before the leaf has run its handler. With every core busy the kernel woke the
    /// handler's thread late, and `bam filter` answered its own SIGTERM with exit 64 and no cancelled record.
    func testAFailureThatFollowsAPostedSIGTERMEndsAsACancel() async {
        struct ToolDied: Error {}
        // The post below is aimed at the process, and the kernel hands it to a thread that can take it later than
        // the pool thread that sent it. SIGTERM is ignored around the run so that no case can end this process
        // (review A54 fix 2), and `end()` drops a post that is still pending. SIGTERM is ignored again inside
        // the work, so the kernel drops the post and only its note remains, since a post another thread is
        // still taking when end() switches the action can call the address of SIG_IGN (FX47 (a2)).
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let ran = await runCancellingOnSIGTERM { () async throws -> Int in
            // The group's SIGTERM reaches the leaf and its tool together, and the tool's death is the first
            // thing the leaf sees.
            signal(SIGTERM, SIG_IGN) // the handler is out of reach from here on
            XCTAssertEqual(kill(getpid(), SIGTERM), 0)
            throw ToolDied()
        }
        guard case .failure(let error) = ran else { return XCTFail("the work threw, so the run failed") }
        XCTAssertTrue(error is CancellationError, "a failure behind a SIGTERM is the cancel it answers: \(error)")
    }

    func testAFailureWithNoSIGTERMBehindItStaysAFailure() async {
        struct ToolDied: Error {}
        let ran = await runCancellingOnSIGTERM { () async throws -> Int in throw ToolDied() }
        guard case .failure(let error) = ran else { return XCTFail("the work threw, so the run failed") }
        XCTAssertTrue(error is ToolDied, "a failure no signal explains is not turned into a cancel: \(error)")
    }

    func testAToolTheCommandLaunchesStillStopsOnSIGTERM() async throws {
        let task = Task<Bool, Never> { false }
        let termination = SIGTERMCancellation(cancelling: task)
        defer { termination.end() }

        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/sleep")
        tool.arguments = ["30"]
        try tool.run()
        defer { if tool.isRunning { kill(tool.processIdentifier, SIGKILL) } }
        tool.terminate()

        let stopped = await waitUntil(timeout: .seconds(30)) { !tool.isRunning }
        XCTAssertTrue(stopped, "a caught SIGTERM goes back to its default action in a launched tool")
        XCTAssertEqual(tool.terminationReason, .uncaughtSignal)
    }

    /// Phase 2.2 lane 5B. The CLI installs a SIGTERM handler for its whole
    /// run that stops its tools. A command's cooperative cancel takes over
    /// SIGTERM while it runs and puts that handler back when it ends.
    func testEndPutsBackTheHandlerThatWasThereBefore() {
        let original = signal(SIGTERM, recordSIGTERMForTest)
        defer { signal(SIGTERM, original) }

        let termination = SIGTERMCancellation { }
        termination.end()

        let restored = signal(SIGTERM, original)
        XCTAssertEqual(
            restored.map { unsafeBitCast($0, to: UInt.self) },
            unsafeBitCast(recordSIGTERMForTest as sig_t, to: UInt.self)
        )
    }
}

/// Stands in for the CLI-wide SIGTERM handler. It is never called.
private func recordSIGTERMForTest(_ signalNumber: Int32) {}

/// The SIGTERMs `countSIGTERMForTest` has seen. An atomic is safe to change inside a signal handler.
private let sigtermsCountedForTest = Atomic<Int>(0)

/// Stands in for the CLI-wide SIGTERM handler where a test needs to know whether a post reached it.
private func countSIGTERMForTest(_ signalNumber: Int32) {
    sigtermsCountedForTest.add(1, ordering: .sequentiallyConsistent)
}

/// The address a SIGTERM action is reported by (0 is SIG_DFL and 1 is SIG_IGN).
private func address(of action: sig_t?) -> UInt {
    unsafeBitCast(action, to: UInt.self)
}

/// The signals the calling thread blocks.
private func signalMaskOfThisThread() -> sigset_t {
    var mask = sigset_t()
    pthread_sigmask(SIG_SETMASK, nil, &mask)
    return mask
}

/// Whether a SIGTERM waits on the calling thread, which can only be one blocked there.
private func sigtermIsPendingOnThisThread() -> Bool {
    var pending = sigset_t()
    sigemptyset(&pending)
    sigpending(&pending)
    return sigismember(&pending, SIGTERM) == 1
}

/// What `SIGTERMCancellation.end()` did, as the seam reports it.
private struct SIGTERMEndRecord {
    /// The actions it gave SIGTERM, in order, as addresses (0 is SIG_DFL and 1 is SIG_IGN).
    var actions: [UInt] = []
    /// How many times it polled for the handler to run.
    var polls = 0
}

private final class SIGTERMEndLog: Sendable {
    private let record = Mutex(SIGTERMEndRecord())

    func note(action: UInt) { record.withLock { $0.actions.append(action) } }

    /// Counts a poll and returns its number, from 1.
    func notePoll() -> Int { record.withLock { state in state.polls += 1; return state.polls } }

    var value: SIGTERMEndRecord { record.withLock { $0 } }
}

/// Ends `termination` and returns what it did. `onPoll` runs at each poll of the wait, with the poll's number, on
/// the thread that waits, and may change the signal state the wait is watching.
private func ending(
    _ termination: SIGTERMCancellation,
    onPoll: @escaping @Sendable (Int) -> Void = { _ in }
) -> SIGTERMEndRecord {
    let log = SIGTERMEndLog()
    SIGTERMEndTrace.$action.withValue({ log.note(action: $0) }) {
        SIGTERMEndTrace.$wait.withValue({ onPoll(log.notePoll()) }) {
            termination.end()
        }
    }
    return log.value
}
