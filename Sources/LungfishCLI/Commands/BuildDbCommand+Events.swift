// BuildDbCommand+Events.swift - What the build-db leaves report while they work
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Where a `build-db` run reports its work. `progress` takes a fraction from 0 to 1 and the message of a
/// step, as the database writers report them. `text` takes one line of human text, such as the rows a run
/// parsed, and `warning` one line that says what went wrong without stopping the run. `textWarning` takes
/// such a warning that text mode prints with the human text. The commands print all four through
/// ``BuildDbCLIEvents``, and a caller in process maps them onto its own progress and log, with both kinds
/// of warning as warnings of its run.
struct BuildDbEventSink: Sendable {
    let progress: @Sendable (Double, String) -> Void
    let text: @Sendable (String) -> Void
    /// A warning that text mode prints with the human text, on standard output, where the read count pass
    /// has always printed its warnings, such as a failed `samtools markdup`.
    let textWarning: @Sendable (String) -> Void
    let warning: @Sendable (String) -> Void

    /// Reports nothing.
    static let silent = BuildDbEventSink(
        progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { _ in }
    )
}

/// The one emitter of `build-db kraken2`, `esviritu` and `taxtriage`, which replaced their private
/// progress shape S14 in Phase 2.7 (`docs/formats/cli-events.md`).
///
/// With `--format json` standard output holds version 2 events only. A run is one `start` line, a
/// `progress` line for each step a database writer reports, with the writer's fraction and message, and
/// then one `complete` line whose `outputs` names the database file, or one `failed` line. The human text
/// goes to standard error. In text mode, the mode the app runs these leaves in, they print the same human
/// text on standard output as before and no event. The warnings of the read count pass travel with the human
/// text, the other warnings go to standard error in both modes, and `--quiet` drops the human text and every
/// warning.
struct BuildDbCLIEvents: Sendable {
    let sink: BuildDbEventSink
    private let events: CLIEventEmitter

    init(globalOptions: GlobalOptions) {
        let eventsOn = globalOptions.outputFormat == .json
        let quiet = globalOptions.quiet
        let events = CLIEventEmitter(enabled: eventsOn) { printEventLine($0) }
        self.events = events
        sink = BuildDbEventSink(
            progress: { fraction, message in events.emitProgress(fraction, message: message) },
            text: { line in
                if !quiet { printHumanLine(line, eventsOn: eventsOn) }
            },
            textWarning: { line in
                if !quiet { printHumanLine(line, eventsOn: eventsOn) }
            },
            warning: { line in
                if !quiet { printStatusLine(line) }
            }
        )
    }

    /// Runs one leaf between its `start` line and its terminal line. `body` builds the database file
    /// `database`, and the `complete` line names it with the run's summary.
    func report(database: URL, _ body: (BuildDbEventSink) async throws -> BuildDbRunResult) async throws {
        events.emitStart("Building \(database.lastPathComponent) in \(database.deletingLastPathComponent().path)")
        do {
            let result = try await body(sink)
            events.emitComplete(outputs: [result.databaseURL.path], message: result.summary)
        } catch {
            events.emitFailed(Self.failureMessage(error))
            throw error
        }
    }

    /// The message a `failed` line carries. A validation error has no localized description of its
    /// own, and the system's generic one changes with the language, so its own text is used.
    static func failureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        let described = String(describing: error)
        return described.isEmpty ? error.localizedDescription : described
    }
}
