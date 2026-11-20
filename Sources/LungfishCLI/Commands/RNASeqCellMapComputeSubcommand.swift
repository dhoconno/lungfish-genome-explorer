// RNASeqCellMapComputeSubcommand.swift - The `lungfish-cli rnaseq cell-map compute` leaf (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Runs the pinned Scanpy route on a single-cell result and writes its UMAP and Leiden clusters as a new cell map. The
/// checks run before the launch, the route runs in the Single-Cell Analysis pack's environment, and the one writer
/// writes the cell map, so a refusal, an error or a SIGTERM leaves no folder.
struct RNASeqCellMapComputeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compute",
        abstract: "Compute a UMAP and Leiden clusters of a single-cell result as a cell map",
        discussion: "Runs LGE's pinned Scanpy route on the result's matrices with exact nearest neighbours, then checks its table and "
            + "writes a new cell map beside the result. A run predicted to need more than 40% of this Mac's memory is refused before it starts."
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The cell-map compute was cancelled. No cell map was written."

    @Argument(help: "A single-cell .lungfishrnaseq result")
    var resultPath: String

    @Option(name: .customLong("seed"), help: "The seed of the PCA, the neighbours, Leiden and UMAP. Only 0 is offered")
    var seed: Int = 0

    @Option(name: .customLong("threads"), help: "The threads the route may use")
    var threads: Int = 1

    @Option(name: .customLong("output"), help: "The new .lungfishrnaseq folder to write. It must not exist")
    var outputPath: String

    @OptionGroup var globalOptions: GlobalOptions

    var resultURL: URL { URL(fileURLWithPath: resultPath).standardizedFileURL }
    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }

    /// The command the record names, every option written even at its default (`docs/contracts/CLI-EQUIVALENCE.md:17`).
    func canonicalArgv() -> [String] {
        [CLICommandIdentity.executableName, "rnaseq", "cell-map", "compute", resultURL.path,
         "--seed", String(seed), "--threads", String(threads), "--output", outputURL.path]
    }

    func run() async throws {
        let command = self
        let eventsOn = globalOptions.outputFormat == .json
        let quiet = globalOptions.quiet
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(message: "Computing a cell map of a single-cell result.")
        let outcome = await runCancellingOnSIGTERM { () async throws -> String in
            try await command.compute(launch: RNASeqCellMapCompute.condaLaunch()) { line in
                events.emitLog(.info, line)
                if !quiet { printHumanLine(line, eventsOn: eventsOn) }
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
            let isInput = error is RNASeqCellMapComputeRefusal || error is RNASeqCellMapImportRefusal || error is RNASeqPseudobulkRefusal
                || error is RNASeqResultError || error is RNASeqCellMapError || error is RNASeqResultWriterError
            throw (isInput ? CLIExitCode.inputError : CLIExitCode.workflowError).exitCode
        }
    }

    /// Runs the route through `launch` and writes the cell map. `step` gets LGE's own lines.
    func compute(launch: @escaping RNASeqCellMapCompute.Launch, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                 step: (String) -> Void) async throws -> String {
        let startedAt = Date()
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(), stageObserver: { stage, _ in
            if stage == .tablesWritten { try ViewerExportLeaf.checkpointAfterStaging() }
        })
        let (_, summary) = try await RNASeqCellMapCompute.compute(
            .init(parent: resultURL, threads: threads, seed: seed), output: outputURL, physicalMemory: physicalMemory,
            launch: launch, writer: writer, step: step
        ) { run, summary in
            envelope(run, summary: summary, startedAt: startedAt)
        }
        try Task.checkCancellation()
        let name = outputURL.deletingPathExtension().lastPathComponent
        let drawn = summary.embeddings.first.map { $0.drawn.reduce(0, +) } ?? 0
        let clusters = summary.labelSets.first?.labels.count ?? 0
        return "Wrote the cell map \(name), where umap draws \(RNASeqCellMapImportRefusal.count(drawn, "cell")) "
            + "in \(RNASeqCellMapImportRefusal.count(clusters, "Leiden cluster"))"
    }

    func envelope(_ run: RNASeqCellMapCompute.Run, summary: RNASeqResultWriter.CellMapSummary, startedAt: Date) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope(
            createdAt: startedAt, workflowName: "RNA-seq cell map compute", toolName: "lungfish rnaseq cell-map compute",
            toolVersion: LungfishCLI.configuration.version)
        let argv = canonicalArgv()
        envelope.argv = argv
        envelope.reproducibleCommand = argv.map(ImportCommand.RNASeqSubcommand.Plan.shellQuoted).joined(separator: " ")
        let explicit: [String: ParameterValue] = [
            "result": .file(resultURL), "output": .file(outputURL), "seed": .integer(seed), "threads": .integer(threads),
        ]
        envelope.options = ProvenanceOptions(explicit: explicit, defaults: [:], resolvedDefaults: RNASeqCellMapCompute.facts(run, summary: summary))
        envelope.files = RNASeqCellMapCompute.files(run, summary: summary, output: outputURL)
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity()
        envelope.wallTimeSeconds = Date().timeIntervalSince(startedAt)
        envelope.exitStatus = 0
        envelope.status = .completed
        return envelope
    }
}
