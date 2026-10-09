// CLITerminationSignals.swift - SIGINT, SIGTERM and SIGHUP stop the CLI's tools before the CLI ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import Synchronization

/// The first termination signal caught, or 0. A signal handler can only reach
/// global state, and an atomic is safe to change from inside one.
private let caughtTerminationSignal = Atomic<Int32>(0)

/// Set once every registered tool has been stopped.
private let toolsStopped = Atomic<Bool>(false)

/// The write end of the wake-up pipe, or -1 before ``CLITerminationSignals/install()``.
private let terminationPipeWriteEnd = Atomic<Int32>(-1)

/// Records the first signal and wakes the stopping queue. A second signal
/// ends the CLI at once. Only async-signal-safe calls are made here.
private func handleTerminationSignal(_ signalNumber: Int32) {
    let savedErrno = errno
    let first = caughtTerminationSignal.compareExchange(
        expected: 0,
        desired: signalNumber,
        ordering: .sequentiallyConsistent
    ).exchanged
    if first {
        let writeEnd = terminationPipeWriteEnd.load(ordering: .sequentiallyConsistent)
        if writeEnd >= 0 {
            var byte: UInt8 = 1
            _ = write(writeEnd, &byte, 1)
        }
    } else {
        // Ctrl-C twice, or kill twice, while the tools stop: the default
        // action ends the process once this handler returns. The signal goes
        // to the process, because raise() fails on a dispatch worker thread.
        signal(signalNumber, SIG_DFL)
        kill(getpid(), signalNumber)
    }
    errno = savedErrno
}

/// Makes SIGINT, SIGTERM and SIGHUP stop every tool the CLI started before
/// the CLI ends.
///
/// Every tool runs in a process group of its own, so Ctrl-C in a terminal
/// reaches only `lungfish-cli`, and a CLI that died at once left its tools
/// running. With this installed, the first of those signals terminates every
/// process tree in ``NativeProcessRegistry``, then gives the signal its
/// default action back and sends it again, so the CLI still ends by that
/// signal and a shell sees why. A second signal ends the CLI at once.
///
/// A command that turns SIGTERM into a cooperative cancel (`import fastq`,
/// `workflow run`) installs its own SIGTERM handler through
/// `SIGTERMCancellation`, which takes precedence while it runs and puts this
/// one back when it ends.
enum CLITerminationSignals {
    /// The signals that end the CLI after its tools are stopped.
    static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    /// How long each tool tree has between SIGTERM and SIGKILL.
    static let toolGracePeriod: TimeInterval = 2

    private static let installed = Mutex(false)

    /// Installs the handlers once for the life of the process.
    static func install() {
        let first = installed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return } // without a pipe, the default actions stay
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // tools the CLI launches do not inherit it
        }
        let readEnd = fds[0]
        // Touch every atomic before a handler can run. A global is set up
        // lazily on first use, which is not async-signal-safe.
        caughtTerminationSignal.store(0, ordering: .sequentiallyConsistent)
        toolsStopped.store(false, ordering: .sequentiallyConsistent)
        terminationPipeWriteEnd.store(fds[1], ordering: .sequentiallyConsistent)

        let source = DispatchSource.makeReadSource(
            fileDescriptor: readEnd,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16)
            while read(readEnd, &buffer, buffer.count) > 0 {}
            let signalNumber = caughtTerminationSignal.load(ordering: .sequentiallyConsistent)
            guard signalNumber != 0 else { return }
            source.cancel()
            NativeProcessRegistry.shared.terminateAll(gracePeriod: toolGracePeriod)
            toolsStopped.store(true, ordering: .sequentiallyConsistent)
            end(by: signalNumber)
        }
        source.resume()

        // A command that fails because its tool was stopped calls exit()
        // while the tools are still stopping. The CLI must end by the signal,
        // not by that exit status, so exit waits here and sends it again.
        atexit {
            let signalNumber = caughtTerminationSignal.load(ordering: .sequentiallyConsistent)
            guard signalNumber != 0 else { return }
            let deadline = DispatchTime.now() + .seconds(30)
            while !toolsStopped.load(ordering: .sequentiallyConsistent), DispatchTime.now() < deadline {
                usleep(10_000)
            }
            CLITerminationSignals.end(by: signalNumber)
        }

        for signalNumber in signals {
            signal(signalNumber, handleTerminationSignal)
        }
    }

    /// Ends the process by `signalNumber` with its default action.
    private static func end(by signalNumber: Int32) -> Never {
        signal(signalNumber, SIG_DFL)
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, signalNumber)
        pthread_sigmask(SIG_UNBLOCK, &set, nil)
        // To the process, not raise(), which is pthread_kill on this thread
        // and fails with ENOTSUP on a dispatch worker thread.
        kill(getpid(), signalNumber)
        // Delivery to any thread ends the process. Should every thread block
        // the signal, exit with the shell's status for it after a second.
        for _ in 0..<100 {
            usleep(10_000)
        }
        _exit(128 + signalNumber)
    }
}
