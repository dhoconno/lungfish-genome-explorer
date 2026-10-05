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
        signal(SIGTERM, SIG_DFL)
        raise(SIGTERM)
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
        caughtSIGTERMs.store(0, ordering: .sequentiallyConsistent)
        secondSIGTERMEndsProcess.store(secondSignalEndsProcess, ordering: .sequentiallyConsistent)
        sigtermPipeWriteEnd.store(ends?.write ?? -1, ordering: .sequentiallyConsistent)
        signal(SIGTERM, handleSIGTERM)
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

    /// Gives SIGTERM its default action back.
    func end() {
        guard !ended else { return }
        ended = true
        signal(SIGTERM, SIG_DFL)
        secondSIGTERMEndsProcess.store(false, ordering: .sequentiallyConsistent)
        sigtermPipeWriteEnd.store(-1, ordering: .sequentiallyConsistent)
        source.cancel()
    }

    deinit {
        end()
    }
}
