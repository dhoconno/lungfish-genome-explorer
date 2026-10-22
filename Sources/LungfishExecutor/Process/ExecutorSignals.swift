// ExecutorSignals.swift - SIGTERM, SIGINT and SIGHUP for the Linux executor, and SIGPIPE for the whole process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The executor's termination signals (SWIFT ruling, words for the K3 brief on signals, stdin and environment).
///
/// On Linux an ignored signal that is not blocked is discarded when it is sent, and libdispatch's signal source sees
/// only a blocked signal, so the first statement of `main` blocks SIGTERM, SIGINT and SIGHUP with `pthread_sigmask`
/// before any thread exists, and every later thread inherits the mask. Linux never sets them to `SIG_IGN`. The macOS
/// build keeps the `SIG_IGN` idiom, since a kqueue signal source sees an ignored signal. A SIGHUP inherited as `SIG_IGN`,
/// as under `nohup`, stays ignored and is not watched. SIGPIPE is ignored for the whole process in place of
/// `F_SETNOSIGPIPE`, and each child gets the default back through the spawn.
enum ExecutorSignals {
    /// The signals that end a run as `interrupted`.
    static let terminationSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// True when `signal` was ignored when the process started, read before anything changes it.
    static func isInheritedAsIgnored(_ signal: Int32) -> Bool {
        var current = sigaction()
        guard sigaction(signal, nil, &current) == 0 else { return false }
        // The handler union is the first member of struct sigaction in glibc, musl and Darwin, and SIG_IGN is 1 in all three.
        let handler = withUnsafeBytes(of: &current) { $0.load(as: UInt.self) }
        return handler == 1
    }

    private static func termination(mask: Int32) {
        #if os(Linux)
        var set = sigset_t()
        sigemptyset(&set)
        for signal in terminationSignals {
            sigaddset(&set, signal)
        }
        pthread_sigmask(mask, &set, nil)
        #endif
    }

    /// Blocks SIGTERM, SIGINT and SIGHUP on Linux. The first statement of `main`. Does nothing on macOS.
    static func blockAtStart() {
        termination(mask: SIG_BLOCK)
    }

    /// Unblocks them again, for the probe modes that exec another program or run no tool.
    static func unblock() {
        termination(mask: SIG_UNBLOCK)
    }

    /// The signals this run watches: SIGTERM and SIGINT always, SIGHUP unless it was inherited as ignored.
    static func watchedSignals() -> [Int32] {
        terminationSignals.filter { $0 != SIGHUP || !isInheritedAsIgnored(SIGHUP) }
    }

    /// Ignores SIGPIPE for the whole process.
    static func ignoreBrokenPipe() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Starts one dispatch signal source per watched signal and calls `handler` with the signal number. The caller keeps
    /// the returned sources for the life of the run.
    static func watch(queue: DispatchQueue, handler: @escaping @Sendable (Int32) -> Void) -> [any DispatchSourceSignal] {
        watchedSignals().map { number in
            #if !os(Linux)
            signal(number, SIG_IGN)
            #endif
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { handler(number) }
            source.resume()
            return source
        }
    }

    /// The name of a termination signal for messages, such as `SIGTERM`.
    static func name(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        case SIGKILL: return "SIGKILL"
        default: return "signal \(signal)"
        }
    }
}
