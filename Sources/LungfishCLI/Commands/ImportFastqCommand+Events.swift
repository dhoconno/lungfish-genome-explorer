// ImportFastqCommand+Events.swift - What `import fastq` reports while it works
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// Everything one run of `import fastq` prints, which replaced its private stream S1 in Phase 2.7
/// (lane Q4, `docs/formats/cli-events.md`).
///
/// With `--format json` standard output holds version 2 events only. A run is one `start` line, the
/// events ``FASTQImportEventStream`` makes from each log event of the importer, and one `complete`
/// line that names each bundle the run made, or one `failed` line. The human text goes to standard
/// error. In text mode the human text stays on standard output as before and no event is printed. The
/// notices and skipped samples that only the S1 lines reported there go to standard error as warning
/// lines, apart from a `--platform` notice, which text mode has always printed with the human text.
/// `--quiet` drops those warnings, as it dropped the S1 lines.
final class ImportFastqReporter: @unchecked Sendable {
    let eventsOn: Bool
    private let quiet: Bool
    private let formatter: TerminalFormatter
    private let events: CLIEventEmitter
    private let lock = NSLock()
    private var stream: FASTQImportEventStream

    init(globalOptions: GlobalOptions, formatter: TerminalFormatter, projectDirectory: URL) {
        eventsOn = globalOptions.outputFormat == .json
        quiet = globalOptions.quiet
        self.formatter = formatter
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
        stream = FASTQImportEventStream(projectDirectory: projectDirectory)
    }

    /// One line of human text, on standard output in text mode and on standard error with events on.
    func text(_ line: String) {
        printHumanLine(line, eventsOn: eventsOn)
    }

    /// The first line of a run with events on.
    func start() {
        events.emitStart("Starting FASTQ import")
    }

    /// A warning of pair detection or of the third-file check, which the run reports before it imports.
    func pairingNotice(sample: String, message: String) {
        if eventsOn {
            log(.notice(sample: sample, message: message))
        } else {
            print(formatter.warning("\(sample): \(message)"))
        }
    }

    /// One log event of the importer. With events on, the events it becomes. In text mode, the lines
    /// text mode prints for it.
    func log(_ event: ImportLogEvent) {
        if eventsOn {
            lock.withLock {
                for line in stream.events(for: event) {
                    events.emit(line)
                }
            }
            return
        }
        switch event {
        case let .platformResolved(sample, platform, source, _, _, _, message) where !quiet:
            let line = "\(sample): \(message)"
            print(platform == "unknown" && source == "inferred" ? formatter.warning(line) : formatter.info(line))
        case let .notice(sample, message) where message.hasPrefix("--platform "):
            print(formatter.warning("\(sample): \(message)"))
        case let .notice(sample, message) where !quiet:
            printStatusLine(formatter.warning("\(sample): \(message)"))
        case let .sampleSkip(sample, reason) where !quiet:
            printStatusLine(formatter.warning("\(sample) skipped: \(reason)"))
        default:
            break
        }
    }

    /// Ends a run that failed: the error as human text, a `failed` line with events on, and the exit
    /// code to throw.
    func fail(_ message: String, detail: String? = nil, exitCode: CLIExitCode) -> ExitCode {
        text(formatter.error(message))
        events.emitFailed(message, detail: detail)
        return exitCode.exitCode
    }

    /// A `failed` line with events on, for a failure whose human text was already printed.
    func failedEvent(_ message: String) {
        events.emitFailed(message)
    }

    /// Ends a run whose samples failed with one `failed` line. Its message is the last failure, as the
    /// app's row showed it, and its detail lists every failure when there are more than one.
    func failSamples(_ errors: [(sample: String, error: String)]) -> ExitCode {
        let failures = lock.withLock { stream.failures }
        let all = failures.isEmpty ? errors.map { "\($0.sample): \($0.error)" } : failures
        events.emitFailed(all.last ?? "The import failed", detail: all.count > 1 ? all.joined(separator: "\n") : nil)
        return CLIExitCode.workflowError.exitCode
    }

    /// Ends a run that finished with one `complete` line naming each bundle it made. A run that made
    /// none, because it skipped every sample or was a dry run, names no path.
    func complete(message: String) {
        let (bundles, artifacts) = lock.withLock { (stream.bundles, stream.bundleArtifacts()) }
        events.emitComplete(outputs: bundles, artifacts: artifacts, message: message)
    }
}
