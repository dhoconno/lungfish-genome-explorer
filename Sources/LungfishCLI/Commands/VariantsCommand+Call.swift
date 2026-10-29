// VariantsCommand+Call.swift - SIGTERM cancels `variants call` for every caller
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The option groups of `variants call` that live outside `VariantsCommand.swift`, which sits at its size
/// baseline. The GATK options come first and the global options last, so `--help` lists them as before.
struct VariantsCallOptions: ParsableArguments {
    @OptionGroup var gatk: VariantsCallGATKOptions
    @OptionGroup var timeLimit: TimeLimitOptions
    @OptionGroup var global: GlobalOptions
}

extension VariantsCommand.CallSubcommand {
    var globalOptions: GlobalOptions {
        get { callOptions.global }
        set { callOptions.global = newValue }
    }

    var gatkOptions: VariantsCallGATKOptions { callOptions.gatk }

    /// Runs the call so that SIGTERM cancels it instead of ending the command, whichever caller it runs
    /// (Phase 2.11 lane A50 M2, plan decisions C5 and P2 of Phase 2.10 and S7 of Phase 2.11). The app's
    /// Cancel sends SIGTERM and gives the command `CLIProcessLauncher.operationGrace`. The command cancels
    /// its task, which stops the tools of the run and removes the stage, records the run as cancelled,
    /// says so on standard error and exits 125. A cancelled run reports no `runFailed` event, since the
    /// app's transport reads a cancel from the exit status. A second SIGTERM ends the command at once.
    func runCall(emitEvent: @escaping @Sendable (VariantsCommand.VariantCallingEvent) -> Void) async throws {
        let startedAt = Date()
        let outcome = await runCancellingOnSIGTERM { [self] in
            try await dispatchCall { event in
                if event.event == "runFailed", Task.isCancelled { return }
                emitEvent(event)
            }
        }
        guard case .failure(let error) = outcome else { return }
        guard error is CancellationError else { throw error }
        writeCancelledRecord(startedAt: startedAt)
        FileHandle.standardError.write(Data("Variant calling cancelled. No variant track was attached.\n".utf8))
        throw CLIExitCode.cancelled.exitCode
    }

    private func dispatchCall(_ emit: @escaping (VariantsCommand.VariantCallingEvent) -> Void) async throws {
        if caller.lowercased() == "gatk" {
            _ = try await executeGATKLive(emitEvent: emit)
        } else {
            _ = try await execute(runtime: .live(), emitEvent: emit)
        }
    }

    /// The command this process was started with when it names `variants call`, as typed, else the
    /// command its parsed options name (a test runs the command inside another process).
    func recordedCommandLine(arguments: [String] = CommandLine.arguments) -> [String] {
        let words = arguments.dropFirst()
        let namesThisCommand = zip(words, words.dropFirst()).contains { $0 == "variants" && $1 == "call" }
        if namesThisCommand { return [CLICommandIdentity.executableName] + Array(words) }
        return [
            CLICommandIdentity.executableName, "variants", "call",
            "--bundle", bundlePath, "--alignment-track", alignmentTrackID, "--caller", caller,
        ] + callOptions.timeLimit.argumentWords
    }

    /// The record of a run that SIGTERM cancelled, in the bundle's `provenance/cancelled` folder where the
    /// alignment workflow leaves put theirs. It names the command and claims no output. A bundle that does
    /// not exist gets no folder.
    private func writeCancelledRecord(startedAt: Date) {
        let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return }
        let workflow = "lungfish variants call"
        let record = CancelledAlignmentWorkflowRecord(
            workflow: workflow,
            argv: recordedCommandLine(),
            explicit: AnalysisTimeLimit.recording([
                "bundlePath": .string(bundleURL.path),
                "alignmentTrackID": .string(alignmentTrackID),
                "caller": .string(caller.lowercased()),
            ]),
            note: "SIGTERM cancelled variant calling. No variant track was attached, and the bundle's tracks are as they were.",
            startedAt: startedAt,
            url: CancelledAlignmentWorkflowRecord.newURL(
                in: CancelledAlignmentWorkflowRecord.folder(in: bundleURL), workflow: workflow
            )
        )
        do {
            try record.write()
        } catch {
            FileHandle.standardError.write(Data("Warning: could not write the cancelled record: \(error.localizedDescription)\n".utf8))
        }
    }
}
