// PrimerDesignCommand+Events.swift - What the primers design leaves the app runs share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The run of a `primers design` leaf that the PCR Primer Design dialog launches (Phase 2.12 lane 12.17 M2, Q-A7,
/// the recipe of `docs/contracts/ADDING-AN-OPERATION.md`).
///
/// `primer3`, `primalscheme3` and `varvamp` write `CLIEvent` lines on standard output under `--format json` and their
/// human text on standard error. A start event repeats the row's first detail, each progress message of the pipeline
/// is a progress event with the words the in-process row showed, and each line a native tool writes, with the tool's
/// own command, is an info log event, as the in-process row logged them. SIGTERM, the app's Cancel, cancels the design
/// and exits 125, and a second SIGTERM ends the command at once. A design that fails ends with its failed event and
/// exits 64, or 126 when a tool is missing (`docs/contracts/ADDING-AN-OPERATION.md:184`). An existing `--output` is
/// refused with exit 3 before any folder exists, and `--project` writes the first free name in the project's Analyses
/// folder (lane 13.43). `olivar` keeps text only and the dialog keeps running it in process until its bundle replay
/// (2.13 row A67-OLIVAR).
extension PrimerDesignCommand {
    /// The first detail of the dialog's row, which the start event repeats so the row keeps its words.
    static let startMessage = "Preparing primer design…"
    /// The message of the complete event, the detail the row ends on.
    static let completeMessage = "Primer analysis saved."
    /// The message of the failed event of a cancelled design.
    static let cancelMessage = "Primer design cancelled. Nothing was saved."

    /// `argv` without the words `--format json`, so the design's record names the command the app's row records
    /// (`docs/contracts/CLI-EQUIVALENCE.md`, Same provenance). The app adds the two words to the run only.
    static func recordedArgv(_ argv: [String]) -> [String] {
        var words: [String] = []
        var index = argv.startIndex
        while index < argv.endIndex {
            if argv[index] == "--format", argv.index(after: index) < argv.endIndex, argv[argv.index(after: index)] == "json" {
                index = argv.index(index, offsetBy: 2)
                continue
            }
            if argv[index] != "--format=json" { words.append(argv[index]) }
            index = argv.index(after: index)
        }
        return words
    }

    /// Runs one design leaf. `design` gets the argv the run records and a progress sink, and returns the published
    /// bundle. `summary` gives the human lines that follow a saved design.
    static func runDesign(
        output: String?,
        project: String?,
        name: String?,
        globalOptions: TextAndJSONGlobalOptions,
        emit: @escaping (String) -> Void = printEventLine,
        design: @escaping @Sendable (
            _ argv: [String], _ destination: URL, _ progress: @escaping @Sendable (Double, String) -> Void
        ) async throws -> URL,
        summary: (URL) -> [String]
    ) async throws {
        let resolved = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        let eventsOn = resolved.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
        // Every transcript begins with its start event, a refusal's too, which still comes before any folder exists.
        events.emitStart(startMessage)
        var refusal: String?
        let destination: URL
        do {
            destination = try resolveDestination(output: output, project: project, name: name) { message in
                refusal = message
                printStatusLine(message)
            }
        } catch {
            if let refusal { events.emitFailed(refusal) }
            throw error
        }
        let argv = recordedArgv(CommandLine.arguments)
        let progress: @Sendable (Double, String) -> Void = { fraction, message in
            events.emitProgress(fraction, message: message)
        }
        let native: (@Sendable (NativeProcessEvent) -> Void)? = eventsOn ? nativeToolLog(events) : nil
        let result = await designCancellingOnSIGTERM {
            try await NativeProcessObservation.$onEvent.withValue(native) {
                try await design(argv, destination, progress)
            }
        }
        switch result {
        case .success(let output):
            if eventsOn || !resolved.quiet {
                summary(output).forEach { printHumanLine($0, eventsOn: eventsOn) }
            }
            events.emitComplete(outputs: [output.path], message: completeMessage)
        case .failure(let error) where error is CancellationError:
            events.emitFailed(cancelMessage)
            printStatusLine(cancelMessage)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            // ADDING-AN-OPERATION.md:184. A failure exits 64 and a missing tool 126. The refusal's exit 3 and a usage error pass through.
            if error is ExitCode || error is ValidationError { throw error }
            throw CLIError.wrapping(error)
        }
    }

    /// Logs the command line of each native tool the design starts and each line it writes as info log events, the
    /// lines the in-process row logged.
    static func nativeToolLog(_ events: CLIEventEmitter) -> @Sendable (NativeProcessEvent) -> Void {
        { event in
            switch event {
            case .started(let words):
                events.emitLog(.info, "Native command: " + words.map(shellEscape).joined(separator: " "))
            case .output(_, let line):
                events.emitLog(.info, line)
            }
        }
    }

    /// Runs `work` so that SIGTERM cancels it instead of ending the command. The command listens before the task
    /// starts, so a SIGTERM caught before then cancels the task as soon as it exists, and a second SIGTERM ends the
    /// command at once. The signal also stops the native tools the design started, since a tool run to its end would
    /// outlast the grace the app gives the command.
    static func designCancellingOnSIGTERM(
        _ work: @escaping @Sendable () async throws -> URL
    ) async -> Result<URL, any Error> {
        let pendingCancel = PendingTaskCancel<Result<URL, any Error>>()
        let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
            pendingCancel.cancel()
            NativeProcessRegistry.shared.terminateAll(gracePeriod: CLITerminationSignals.toolGracePeriod)
        }
        defer { termination.end() }
        let task = Task { () -> Result<URL, any Error> in
            do {
                return .success(try await work())
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled || SIGTERMCancellation.signalCaught ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        return await task.value
    }
}

/// A value of one of the eight Primer3 rules an assay preset sets, or `primer3-default`, which leaves the rule to
/// Primer3's own default as a blank field of the dialog does (UX ruling on lane 12.17, state 1). A missing option takes
/// the preset's value.
enum Primer3PresetRule<Value: LosslessStringConvertible & Sendable & Equatable>: ExpressibleByArgument, Sendable, Equatable {
    case value(Value)
    case primer3Default

    static var primer3DefaultWord: String { PrimerDesignCLIArguments.primer3DefaultWord }

    init?(argument: String) {
        if argument == Self.primer3DefaultWord {
            self = .primer3Default
        } else if let value = Value(argument) {
            self = .value(value)
        } else {
            return nil
        }
    }

    /// The rule's value for a run, the preset's value when the option is missing.
    static func resolve(_ rule: Self?, preset: Value?) -> Value? {
        switch rule {
        case nil: return preset
        case .primer3Default?: return nil
        case .value(let value)?: return value
        }
    }
}
