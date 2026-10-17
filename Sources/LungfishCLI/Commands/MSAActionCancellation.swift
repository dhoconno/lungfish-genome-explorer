// MSAActionCancellation.swift - The cancel path the MSA actions share (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The annotate, export, consensus, extract, mask, trim and distance actions of `lungfish-cli msa` are
// synchronous and run no external tool. The app's Cancel sends SIGTERM and gives the command
// `operationGrace`. Each action that writes a result reads the alignment through `parseAlignedFASTA`,
// which is the cancel point, before it writes anything. A cancel there ends the action through its own
// failure handler, which restores what it had published and writes the one `failed` line. This path
// then records the run as cancelled and exits 125. An action that had finished its writes when the
// SIGTERM came completes as it always did and says in one log line that the cancel came too late. The
// app still reads its row as Cancelled, with the result on disk.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The error the cancel point throws. Its text is the message of the action's `failed` line.
struct MSAActionCancelled: Error, LocalizedError {
    var errorDescription: String? { "The MSA action was cancelled." }
}

/// The cancel point of an MSA action. It returns `value`, so a call wraps the read it follows.
func msaActionCheckpoint<Value>(_ value: Value) throws -> Value {
    if Task.isCancelled { throw MSAActionCancelled() }
    return value
}

/// An action as a value the cancel scope's task can hold. It runs the action and emits the action's
/// event lines through the closure it is given.
typealias MSAActionExecutor = @Sendable (_ emit: @escaping (String) -> Void) throws -> Void

/// An `msa` action the app launches through `CLIMSAActionRunner`.
protocol MSAActionCommand: AsyncParsableCommand {
    var bundlePath: String { get }
    var globalOptions: GlobalOptions { get }
    /// The file or bundle the action writes, or nil for an action that edits `bundlePath` in place.
    var msaOutputPath: String? { get }
    func executeForTesting(emit: @escaping (String) -> Void) throws
    var msaExecutor: MSAActionExecutor { get }
    /// The words after `lungfish` that name the action, such as `msa mask columns`. The cancelled
    /// record names its workflow with them.
    static var msaCommandName: String { get }
}

extension MSAActionCommand where Self: Sendable {
    var msaExecutor: MSAActionExecutor { { [self] emit in try executeForTesting(emit: emit) } }
}

extension MSACommand.AddSubcommand: MSAActionCommand {
    var msaOutputPath: String? { nil }
    static var msaCommandName: String { "msa annotate add" }
}
extension MSACommand.EditSubcommand: MSAActionCommand {
    var msaOutputPath: String? { nil }
    static var msaCommandName: String { "msa annotate edit" }
}
extension MSACommand.DeleteSubcommand: MSAActionCommand {
    var msaOutputPath: String? { nil }
    static var msaCommandName: String { "msa annotate delete" }
}
extension MSACommand.ProjectSubcommand: MSAActionCommand {
    var msaOutputPath: String? { nil }
    static var msaCommandName: String { "msa annotate project" }
}
extension MSACommand.ExportSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa export" }
}
extension MSACommand.ConsensusSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa consensus" }
}
extension MSACommand.ExtractSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa extract" }
}
extension MSACommand.MaskColumnsSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa mask columns" }
}
extension MSACommand.TrimColumnsSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa trim columns" }
}
extension MSACommand.DistanceSubcommand: MSAActionCommand {
    var msaOutputPath: String? { outputPath }
    static var msaCommandName: String { "msa distance" }
}

extension MSAActionCommand {
    /// Runs the action so that SIGTERM cancels it instead of ending the command (decisions P2 and C5).
    func run() async throws {
        try await runActionCancellingOnSIGTERM(emit: { printEventLine($0) }, execute: msaExecutor)
    }

    /// The cancel path of the actions. `execute` runs the action. A cancel it ends with, or a SIGTERM
    /// the command caught, writes the cancelled record, which sits beside the output
    /// (`<output>.cancelled.lungfish-provenance.json`) or, for an action that edits the bundle in place,
    /// under `<bundle>/provenance/cancelled`. The action's own handler wrote the `failed` line, so none
    /// follows. The command throws exit status 125.
    func runActionCancellingOnSIGTERM(
        emit: @escaping @Sendable (String) -> Void,
        execute: @escaping MSAActionExecutor
    ) async throws {
        let startedAt = Date()
        let ran = await runCancellingOnSIGTERM { try execute(emit) }
        guard case .failure(let error) = ran else {
            if SIGTERMCancellation.signalCaught {
                let note = "The cancel arrived after the action had written its result. The result was kept."
                let output = AlignmentWorkflowLeafOutput(
                    eventsOn: globalOptions.outputFormat == .json, quiet: globalOptions.quiet, emit: emit
                )
                output.events.emitLog(.info, note)
                output.say(note)
            }
            return
        }
        guard error is CancellationError || error is MSAActionCancelled || SIGTERMCancellation.signalCaught else {
            throw error
        }
        let workflow = "lungfish " + Self.msaCommandName
        let recordURL: URL
        if let msaOutputPath {
            let outputURL = URL(fileURLWithPath: msaOutputPath).standardizedFileURL
            recordURL = URL(fileURLWithPath: outputURL.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
        } else {
            let folder = CancelledAlignmentWorkflowRecord.folder(in: URL(fileURLWithPath: bundlePath).standardizedFileURL)
            recordURL = CancelledAlignmentWorkflowRecord.newURL(in: folder, workflow: workflow)
        }
        let record = CancelledAlignmentWorkflowRecord(
            workflow: workflow,
            argv: [CLICommandIdentity.executableName] + CommandLine.arguments.dropFirst(),
            explicit: [:],
            note: "Cancelled before the action wrote its result. The input bundle was not changed.",
            startedAt: startedAt,
            url: recordURL
        )
        do {
            try record.write()
        } catch {
            CLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
                .emitLog(.warning, "Could not write the cancelled record: \(error.localizedDescription)")
        }
        throw CLIExitCode.cancelled.exitCode
    }
}
