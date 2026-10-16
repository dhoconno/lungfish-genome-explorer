// TreeCommandTransform.swift - Shared writer for tree reroot, extract-subtree and relabel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Fails, without truncating, when the output's last path component is longer than macOS allows.
func validateOutputNameLength(_ outputURL: URL) throws {
    let name = outputURL.lastPathComponent
    let bytes = name.utf8.count
    guard bytes <= FileNameBudget.maxComponentBytes else {
        throw ValidationError("Output name '\(name)' is \(bytes) bytes. macOS allows at most \(FileNameBudget.maxComponentBytes) bytes per file or folder name. Choose a shorter --output.")
    }
}

/// Loads the input bundle, runs `transform` and writes the new bundle. A cancel of the calling task ends
/// the run at the next step with a `CancellationError`, writes no `failed` line (the command's cancel
/// path ends the stream with one) and removes the bundle this run created.
func executeTreeTransform(
    bundlePath: String,
    outputPath: String,
    toolName: String,
    argv: [String],
    globalOptions: GlobalOptions,
    emit: @escaping (String) -> Void,
    transform: (PhylogeneticTreeBundle, URL, PhylogeneticTreeBundleTransformProvenance) throws -> PhylogeneticTreeBundle
) throws {
    let emitter = CLIEventEmitter(
        enabled: globalOptions.outputFormat == .json,
        emit: emit
    )
    let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    emitter.emitStart(message: "Starting tree transform.")
    // Only remove an output this run created. Refusing to overwrite must leave an existing bundle alone.
    var createdOutput = false
    do {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ValidationError("Input tree bundle not found: \(bundleURL.path)")
        }
        try validateOutputNameLength(outputURL)
        guard FileManager.default.fileExists(atPath: outputURL.path) == false else {
            throw ValidationError("Output bundle already exists: \(outputURL.path)")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        createdOutput = true
        emitter.emitProgress(0.25, message: "Loading tree bundle.")
        let bundle = try PhylogeneticTreeBundle.load(from: bundleURL)
        try Task.checkCancellation()
        emitter.emitProgress(0.65, message: "Writing transformed tree bundle.")
        _ = try transform(
            bundle,
            outputURL,
            PhylogeneticTreeBundleTransformProvenance(
                toolName: toolName,
                argv: argv,
                command: treeCLIShellCommand(argv)
            )
        )
        // A cancel that landed while the bundle was written ends the run here, and the catch removes it.
        try Task.checkCancellation()
        emitter.emitComplete(output: outputURL.path)
        if globalOptions.outputFormat != .json && !globalOptions.quiet {
            emit("Wrote tree bundle: \(outputURL.path)")
            emit("Provenance: \(outputURL.appendingPathComponent(".lungfish-provenance.json").path)")
        }
    } catch {
        if !Task.isCancelled, !(error is CancellationError) {
            emitter.emitFailed(treeCommandErrorDescription(error))
        }
        if createdOutput { try? FileManager.default.removeItem(at: outputURL) }
        throw error
    }
}

/// The three tree transforms, `reroot`, `extract-subtree` and `relabel`. They run no external tool, so
/// the cancel path is one shared function (Phase 2.11 lane S61, decisions P2 and C5).
protocol TreeTransformCommand: AsyncParsableCommand, Sendable {
    var outputPath: String { get }
    var globalOptions: GlobalOptions { get }
    func executeForTesting(emit: @escaping (String) -> Void) throws
}

extension TreeTransformCommand {
    /// Runs the transform so that SIGTERM cancels it instead of ending the command. The Tree row
    /// stops these commands with SIGTERM and gives them `operationGrace`. The writer ends at its next
    /// step, removes the bundle it started, and the run is recorded as cancelled beside the output
    /// path, the stream ends with one `failed` line, and the command exits 125.
    func run() async throws {
        try await runTransformCancellingOnSIGTERM(emit: { printEventLine($0) }) { [self] in
            try executeForTesting { printEventLine($0) }
        }
    }

    /// The cancel path of the three transforms. `body` runs the writer. A cancel it ends with, or a
    /// SIGTERM the command caught, writes `<output>.cancelled.lungfish-provenance.json`, ends the
    /// stream with one `failed` line through `emit`, and throws exit status 125.
    func runTransformCancellingOnSIGTERM(
        emit: @escaping @Sendable (String) -> Void,
        body: @escaping @Sendable () throws -> Void
    ) async throws {
        let startedAt = Date()
        let ran = await runCancellingOnSIGTERM { try body() }
        guard case .failure(let error) = ran else { return }
        guard error is CancellationError || SIGTERMCancellation.signalCaught else { throw error }
        let name = Self.configuration.commandName ?? "transform"
        let output = AlignmentWorkflowLeafOutput(
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            emit: emit
        )
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        throw output.cancelled(
            "Tree \(name) cancelled. No tree bundle was written.",
            record: CancelledAlignmentWorkflowRecord(
                workflow: "lungfish tree \(name)",
                argv: [CLICommandIdentity.executableName] + CommandLine.arguments.dropFirst(),
                explicit: [:],
                note: "Cancelled before the tree bundle was written. No bundle remains at the output path.",
                startedAt: startedAt,
                url: URL(fileURLWithPath: outputURL.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
            )
        )
    }
}
