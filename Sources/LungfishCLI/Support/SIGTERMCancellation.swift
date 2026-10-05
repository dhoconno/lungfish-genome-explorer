// SIGTERMCancellation.swift - Turns SIGTERM into a cancel so a command's cleanup runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

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
final class SIGTERMCancellation {
    private let source: DispatchSourceSignal
    private var ended = false

    /// Starts turning SIGTERM into `cancel()` calls.
    init(cancel: @escaping @Sendable () -> Void) {
        // The handler does nothing. It only keeps SIGTERM from ending the
        // process, so the dispatch source below can act on it.
        signal(SIGTERM, { _ in })
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler(handler: cancel)
        source.resume()
    }

    /// Starts turning SIGTERM into a cancel of `task`.
    convenience init<Success: Sendable>(cancelling task: Task<Success, Never>) {
        self.init { task.cancel() }
    }

    /// Gives SIGTERM its default action back.
    func end() {
        guard !ended else { return }
        ended = true
        source.cancel()
        signal(SIGTERM, SIG_DFL)
    }

    deinit {
        end()
    }
}
