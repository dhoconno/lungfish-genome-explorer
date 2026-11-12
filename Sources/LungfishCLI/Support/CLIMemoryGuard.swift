// CLIMemoryGuard.swift - At its memory share lungfish-cli stops the work, says why and exits nonzero
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishWorkflow
import Synchronization

/// Reads `lungfish-cli`'s own footprint every ``ProcessMemoryShare/pollInterval``. When it reaches the share, half
/// of this Mac's memory, the guard writes why as an `Error:` line on stderr and as a `failed` event when
/// `--format json` is on, ends every tool tree the command started and exits with ``exitStatus``. A watchdog that
/// stops a run says why (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time).
final class CLIMemoryGuard: Sendable {
    /// Where the guard's words and acts go. Tests record them in place of the process's own.
    struct Sinks: Sendable {
        var stderr: @Sendable (String) -> Void
        var event: @Sendable (String) -> Void
        var stopTools: @Sendable () -> Void
        var exit: @Sendable (Int32) -> Void

        static let live = Sinks(
            stderr: { printStatusLine($0) },
            event: { printEventLine($0) },
            stopTools: { NativeProcessRegistry.shared.terminateAll(gracePeriod: CLITerminationSignals.toolGracePeriod) },
            exit: { Darwin.exit($0) }
        )
    }

    /// The status the CLI exits with when the guard stopped it.
    static let exitStatus: Int32 = CLIExitCode.failure.rawValue

    private static let installed = Mutex<CLIMemoryGuard?>(nil)

    let command: String
    let eventsOn: Bool
    private let watch: ProcessMemoryWatch
    private let sinks: Sinks

    init(
        command: String,
        eventsOn: Bool,
        share: ProcessMemoryShare = ProcessMemoryShare(),
        readFootprint: @escaping @Sendable () -> UInt64? = { ProcessMemoryShare.currentFootprint() },
        sinks: Sinks = .live
    ) {
        self.command = command
        self.eventsOn = eventsOn
        watch = ProcessMemoryWatch(share: share, readFootprint: readFootprint)
        self.sinks = sinks
    }

    /// Starts the guard for the command `arguments` name, once for the life of the process.
    static func install(arguments: [String]) {
        installed.withLock { current in
            guard current == nil else { return }
            let memoryGuard = CLIMemoryGuard(command: command(in: arguments), eventsOn: eventsOn(in: arguments))
            memoryGuard.start()
            current = memoryGuard
        }
    }

    /// Reads the footprint every poll on a utility queue.
    func start() {
        watch.start(queue: DispatchQueue.global(qos: .utility)) { [self] footprint in
            stopWork(footprint: footprint)
        }
    }

    /// Reads the footprint once, and stops the work when it reached the share.
    func check() {
        guard let footprint = watch.check() else { return }
        stopWork(footprint: footprint)
    }

    private func stopWork(footprint: UInt64) {
        let words = Self.words(command: command, footprint: footprint, share: watch.share)
        sinks.stderr("Error: \(words)")
        if eventsOn {
            CLIEventEmitter(enabled: true, emit: sinks.event).emitFailed(words)
        }
        sinks.stopTools()
        sinks.exit(Self.exitStatus)
    }

    /// The words of a stop, naming the command, the footprint and this Mac's memory.
    static func words(command: String, footprint: UInt64, share: ProcessMemoryShare) -> String {
        "lungfish-cli stopped \(command) because it was using \(MemoryWords.bytes(footprint)) of memory, "
            + "\(share.shareWords). It stops there so the Mac does not run out of memory. "
            + "Run the command on fewer or smaller files at a time, or on a Mac with more memory."
    }

    /// The command's name from its leading subcommand words, such as `import fastq`.
    static func command(in arguments: [String]) -> String {
        let words = arguments.prefix { word in
            !word.isEmpty && word.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } && !word.hasPrefix("-")
        }
        return words.isEmpty ? "the command" : words.prefix(3).joined(separator: " ")
    }

    /// True when the arguments turn the event stream on with `--format json`.
    static func eventsOn(in arguments: [String]) -> Bool {
        for (index, word) in arguments.enumerated() {
            if word == "--format=json" { return true }
            if word == "--format", index + 1 < arguments.count, arguments[index + 1] == "json" { return true }
        }
        return false
    }
}
