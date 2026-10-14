// RunSubcommand+Output.swift - What workflow run prints, as human text or as CLIEvent lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// What `workflow run` prints on both of its routes, a local workflow's and nf-core's (Phase 2.10 lane A30 M3, ARCH's
/// ruling on M3).
///
/// Text mode prints as the command always has. Under `--format json` standard output holds only `CLIEvent` lines
/// (`docs/formats/cli-events.md`). The first is `start`, each line text mode prints on standard output becomes an
/// info `log` event, the Docker wait's two lines become `progress` events at 0.01 and 0.02, the run's outcome lines
/// become `log` events at `warning`, and the run ends with `complete`, naming the run bundle and the results folder,
/// or `failed`. Standard error keeps the lines text mode prints there but the outcome lines, so the tail of a failure
/// reads the same and a reader never takes an outcome twice.
struct WorkflowRunOutput: Sendable {
    let formatter: TerminalFormatter
    let quiet: Bool
    /// The event lines under `--format json`, nil in text mode.
    let events: CLIEventEmitter?

    init(
        formatter: TerminalFormatter,
        quiet: Bool,
        eventsOn: Bool,
        emit: @escaping @Sendable (String) -> Void = { printEventLine($0) }
    ) {
        self.formatter = formatter
        self.quiet = quiet
        events = eventsOn ? CLIEventEmitter(enabled: true, emit: emit) : nil
    }

    /// A line text mode prints on standard output in the info form, unless quiet.
    func info(_ message: String) {
        if let events {
            events.emitLog(.info, message)
        } else if !quiet {
            print(formatter.info(message))
        }
    }

    /// A line text mode prints on standard output as it is, unless quiet.
    func plain(_ message: String) {
        if let events {
            events.emitLog(.info, message)
        } else if !quiet {
            print(message)
        }
    }

    /// A fact about the input before the launch, such as the missing annotation, which text mode prints in the
    /// warning form. It is not the run's outcome, so it is an info event (BIO's and UX's view in the ruling).
    func notice(_ message: String) {
        if let events {
            events.emitLog(.info, message)
        } else if !quiet {
            print(formatter.warning(message))
        }
    }

    /// A step of the Docker wait, in the engine's words (rule 2), which text mode prints in the info form.
    func progress(_ fraction: Double, _ message: String) {
        if let events {
            events.emitProgress(fraction, message: message)
        } else if !quiet {
            print(formatter.info(message))
        }
    }

    /// One of the run's outcome lines, which text mode prints on standard error in the warning form even under
    /// `--quiet` (rule 5 of the contract's section 5).
    func outcome(_ message: String) {
        if let events {
            events.emitLog(.warning, message)
        } else {
            printStatusLine(formatter.warning(message))
        }
    }

    /// The end of a run that wrote `outputs`. Text mode prints the first, the run bundle, as its last line.
    func complete(_ outputs: [URL]) {
        if let events {
            events.emitComplete(outputs: outputs.map(\.path))
        } else if let bundle = outputs.first {
            print(bundle.path)
        }
    }

    /// The end of a run that threw `error`, under `--format json` only. Text mode leaves the error to the command's
    /// own message on standard error.
    func failed(_ error: Error) {
        events?.emitFailed(Self.message(for: error))
    }

    /// The words of a failure, `Workflow cancelled` for the cancel's exit code 125 as standard error says it.
    static func message(for error: Error) -> String {
        if let exit = error as? ExitCode {
            return exit.rawValue == CLIExitCode.cancelled.rawValue ? "Workflow cancelled" : "Workflow failed with exit code \(exit.rawValue)"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
