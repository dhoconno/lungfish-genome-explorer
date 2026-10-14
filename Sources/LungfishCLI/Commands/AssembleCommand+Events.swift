// AssembleCommand+Events.swift - What `assemble` reports for a machine reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

extension AssembleCommand {
    /// Whether this run prints events: `--format json`, or `--json-events`, the hidden alias that
    /// every row recorded before Phase 2.10 carries (decision C7).
    var eventsOn: Bool {
        jsonEvents || globalOptions.outputFormat == .json
    }
}

/// What one run of `assemble` reports, which moved from standard error to standard output in Phase
/// 2.10 (lane A46, decision C7, `docs/formats/cli-events.md`).
///
/// With events on, standard output holds version 2 events only: one `start` line, a `progress` line
/// for each stage, a `log` line for each line of the assembler, and one `complete` line, or one
/// `failed` line that carries the words of a refusal or a failure. Human text goes to standard error.
/// In text mode no event is printed and the text stays where it was.
struct AssembleRunReporter: Sendable {
    let eventsOn: Bool
    private let events: CLIEventEmitter
    private let useColors: Bool

    init(eventsOn: Bool, useColors: Bool) {
        self.eventsOn = eventsOn
        self.useColors = useColors
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
    }

    func start(_ message: String) {
        events.emitStart(message)
    }

    func progress(_ fraction: Double, _ message: String) {
        events.emitProgress(fraction, message: message)
    }

    func log(_ level: CLIEventLogLevel, _ message: String) {
        events.emitLog(level, message)
    }

    /// Text for a person, on standard output in text mode and on standard error with events on.
    func text(_ line: String) {
        printHumanLine(line, eventsOn: eventsOn)
    }

    func complete(outputs: [String], message: String) {
        events.emitComplete(outputs: outputs, message: message)
    }

    func failed(_ message: String) {
        events.emitFailed(message)
    }

    /// Prints `message` as an error for a person, ends the run with one `failed` line, and returns
    /// the exit status for the caller to throw.
    func refusal(_ message: String, exit: CLIExitCode) -> ExitCode {
        text(TerminalFormatter(useColors: useColors).error(message))
        failed(message)
        return exit.exitCode
    }
}
