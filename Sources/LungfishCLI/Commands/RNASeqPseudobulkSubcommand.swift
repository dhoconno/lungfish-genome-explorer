// RNASeqPseudobulkSubcommand.swift - `lungfish-cli rnaseq pseudobulk` (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Sums the raw UMIs of a single-cell result by sample and by the analyst's label table into a new bulk result that
/// `rnaseq export` reads (`docs/formats/rnaseq-bundle.md`, Pseudobulk). Groups under 10 cells are left out and said.
/// The result is written through `RNASeqResultWriter`, so a refusal, an error or a SIGTERM leaves no folder.
struct RNASeqPseudobulkSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pseudobulk",
        abstract: "Sum a single-cell result's UMIs by sample and label",
        discussion: "Writes a new bulk RNA-seq result with one column for each sample and label of the table --labels names. "
            + "A group under 10 cells is left out and said, and so are the cells with no label."
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The pseudobulk was cancelled. No result was written."

    @Argument(help: "A single-cell .lungfishrnaseq result")
    var resultPath: String

    @Option(name: .customLong("labels"), help: "A tab-separated table with barcode and label columns, and sample for a result of two or more samples")
    var labelsPath: String

    @Option(name: .customLong("output"), help: "The new .lungfishrnaseq folder to write. It must not exist")
    var outputPath: String

    @OptionGroup var globalOptions: GlobalOptions

    var resultURL: URL { URL(fileURLWithPath: resultPath).standardizedFileURL }
    var labelsURL: URL { URL(fileURLWithPath: labelsPath).standardizedFileURL }
    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }

    /// The command the record names, in one fixed order with absolute paths. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        [CLICommandIdentity.executableName, "rnaseq", "pseudobulk", resultURL.path, "--labels", labelsURL.path, "--output", outputURL.path]
    }

    func run() async throws {
        let command = self
        let eventsOn = globalOptions.outputFormat == .json
        let quiet = globalOptions.quiet
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(message: "Summing single-cell UMIs by sample and label.")
        let outcome = await runCancellingOnSIGTERM { () throws -> String in
            try command.write { note in
                events.emitLog(.warning, note)
                if !quiet { printHumanLine(note, eventsOn: eventsOn) }
            }
        }
        switch outcome {
        case .success(let message):
            events.emitComplete(output: outputURL.path, message: message)
            if !quiet { printHumanLine(message, eventsOn: eventsOn) }
        case .failure(let error):
            let isCancel = error is CancellationError
            let words = isCancel ? Self.cancelledMessage : CLIFailureWords.describe(error)
            events.emitFailed(words)
            printHumanLine(words, eventsOn: eventsOn)
            if isCancel { throw CLIExitCode.cancelled.exitCode }
            let isInput = error is RNASeqPseudobulkRefusal || error is RNASeqResultError
            throw (isInput ? CLIExitCode.inputError : CLIExitCode.workflowError).exitCode
        }
    }

    /// Refuses, sums and writes. Each note is a group left out or the cells with no label.
    func write(notes: (String) -> Void) throws -> String {
        let startedAt = Date()
        try RNASeqPseudobulk.checkOutput(outputURL)
        let name = outputURL.deletingPathExtension().lastPathComponent
        let summed = try RNASeqPseudobulk.sum(result: resultURL, labels: labelsURL, name: name, createdAt: startedAt)
        summed.notes.forEach(notes)
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(), stageObserver: { stage, _ in
            if stage == .tablesWritten { try ViewerExportLeaf.checkpointAfterStaging() }
        })
        try writer.write(summed.request, to: outputURL, envelope: envelope(summed, startedAt: startedAt))
        try Task.checkCancellation()
        let cells = summed.kept.reduce(0) { $0 + $1.cells }
        return "Summed \(cells) cells into \(summed.kept.count) groups of \(name)"
    }

    func envelope(_ summed: RNASeqPseudobulk.Outcome, startedAt: Date) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope(
            createdAt: startedAt, workflowName: "RNA-seq pseudobulk", toolName: "lungfish rnaseq pseudobulk",
            toolVersion: LungfishCLI.configuration.version)
        let argv = canonicalArgv()
        envelope.argv = argv
        envelope.reproducibleCommand = argv.map(ImportCommand.RNASeqSubcommand.Plan.shellQuoted).joined(separator: " ")
        envelope.options = ProvenanceOptions(
            explicit: ["result": .file(resultURL), "labels": .file(labelsURL), "output": .file(outputURL)],
            defaults: [:], resolvedDefaults: summed.facts)
        envelope.files = [
            ProvenanceFileDescriptor(
                path: RNASeqResultBundle.manifestURL(in: resultURL).path, checksumSHA256: summed.resultManifestSHA256, role: .input),
            ProvenanceFileDescriptor(path: labelsURL.path, checksumSHA256: summed.labelTableSHA256, role: .input),
        ]
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity()
        envelope.wallTimeSeconds = Date().timeIntervalSince(startedAt)
        envelope.exitStatus = 0
        envelope.status = .completed
        return envelope
    }
}
