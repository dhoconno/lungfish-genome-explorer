// MapCommand+Events.swift - What `map` reports for a machine reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// What one run of `map` reports, which replaced its one JSON report under `--format json` in
/// Phase 2.10 (lane A46, ruling 1 of its M1 review, `docs/formats/cli-events.md`).
///
/// With `--format json` standard output holds version 2 events only: one `start` line, a `progress`
/// line for each step with the words and fractions of ``MappingRunProgress``, which the Map Reads
/// window shows, one `log` line that names the read layout, and one `complete` line, or one
/// `failed` line. Human
/// text goes to standard error. In text mode no event is printed and the text stays where it was.
struct MapRunReporter: Sendable {
    let eventsOn: Bool
    private let events: CLIEventEmitter

    init(globalOptions: GlobalOptions) {
        eventsOn = globalOptions.outputFormat == .json
        events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
    }

    /// The first line of a run, whose message is the Map Reads row's first detail.
    func start(_ message: String) {
        events.emitStart(message)
    }

    /// One step of the run, as a `progress` line.
    func step(_ step: MappingRunProgress.Step) {
        events.emitProgress(step.fraction, message: step.message)
    }

    /// One line for the operation log, at info.
    func info(_ message: String) {
        events.emitLog(.info, message)
    }

    /// Text for a person, on standard output in text mode and on standard error with events on.
    func text(_ line: String) {
        printHumanLine(line, eventsOn: eventsOn)
    }

    /// The last line of a run that published its result. `outputs` names the result folder.
    func complete(outputDirectory: URL, result: MappingResult) {
        events.emitComplete(
            outputs: [outputDirectory.path],
            message: MappingRunProgress.completionDetail(mappedReads: result.mappedReads, totalReads: result.totalReads)
        )
    }

    /// The last line of a run that failed or was cancelled.
    func failed(_ message: String) {
        events.emitFailed(message)
    }

    /// The words of the `failed` line for `error`. A pipeline's failure keeps its own words, as the
    /// Map Reads window shows them, without the prefix of the wrapping `CLIError`.
    static func failureMessage(for error: any Error) -> String {
        if let failure = error as? MapRunFailure {
            return failure.message
        }
        if let cliError = error as? CLIError {
            switch cliError {
            case .workflowFailed(let reason), .missingTool(let reason):
                return reason
            default:
                return cliError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// A run that `map` refuses with its own words and exit status, such as a preset the mapper does
/// not take. ``MapCommand/run()`` prints the words and ends the run with one `failed` line.
struct MapRunFailure: Error {
    let message: String
    let exitCode: ExitCode

    static func input(_ message: String) -> MapRunFailure {
        MapRunFailure(message: message, exitCode: CLIExitCode.inputError.exitCode)
    }
}
