// RNASeqCellMapSubcommand.swift - The `lungfish-cli rnaseq cell-map` group and its import leaf (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The cell-map commands (`docs/formats/rnaseq-cell-map.md`). CM-IMPORT adds the group and `import`, and later lanes add
/// their leaves.
struct RNASeqCellMapSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cell-map",
        abstract: "Make cell maps of a single-cell result",
        subcommands: [RNASeqCellMapImportSubcommand.self]
    )
}

/// `--barcode-suffix` as the command line gives it.
enum CellMapBarcodeSuffix: String, ExpressibleByArgument, CaseIterable {
    case drop, add
    var value: RNASeqCellMapImport.BarcodeSuffix { self == .drop ? .drop : .add }
}

/// Reads the coordinates and labels that the person's own tool made into a new cell map of a single-cell result. Every
/// check runs before anything is written, and the one writer writes the cell map, so a refusal, an error or a SIGTERM
/// leaves no folder.
struct RNASeqCellMapImportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a single-cell result's embeddings and cell labels as a cell map",
        discussion: "Reads LGE's table or 10x's projection.csv and clusters.csv, matches each barcode to a cell of the result as given, "
            + "and writes a new cell map beside the result. Cells with no coordinates are counted, and the given files are kept."
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The cell-map import was cancelled. No cell map was written."

    @Argument(help: "A single-cell .lungfishrnaseq result")
    var resultPath: String

    @Option(name: .customLong("coordinates"), help: "LGE's table or one of 10x's projection.csv files. Repeat for more")
    var coordinates: [String] = []

    @Option(name: .customLong("clusters"), help: "One of 10x's clusters.csv files. Repeat for more")
    var clusters: [String] = []

    @Option(name: .customLong("label-column"), help: "A column of LGE's table that holds labels. Repeat for more")
    var labelColumns: [String] = []

    @Option(name: .customLong("method"), help: "The method of one embedding, as <embedding>=<name>, such as umap=UMAP. Repeat for more")
    var methods: [String] = []

    @Option(name: .customLong("barcode-suffix"), help: "Drop -1 from each given barcode that ends in it, or add -1 to each, before matching")
    var barcodeSuffix: CellMapBarcodeSuffix?

    @Flag(name: .customLong("skip-barcodes-not-held"), help: "Leave out the given barcodes that the result does not hold, and count them")
    var skipBarcodesNotHeld = false

    @Flag(name: .customLong("other-counts"), help: "The embedding was computed on counts other than the result's")
    var otherCounts = false

    @Option(name: .customLong("tool"), help: "The tool that made the files, as you state it")
    var tool: String?

    @Option(name: .customLong("tool-version"), help: "The version of that tool, as you state it")
    var toolVersion: String?

    @Option(name: .customLong("output"), help: "The new .lungfishrnaseq folder to write. It must not exist")
    var outputPath: String

    @OptionGroup var globalOptions: GlobalOptions

    var resultURL: URL { URL(fileURLWithPath: resultPath).standardizedFileURL }
    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }
    func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    var options: RNASeqCellMapImport.Options {
        RNASeqCellMapImport.Options(
            parent: resultURL, coordinates: coordinates.map { URL(fileURLWithPath: absolute($0)) }, clusters: clusters.map { URL(fileURLWithPath: absolute($0)) },
            labelColumns: labelColumns, methods: methods, barcodeSuffix: barcodeSuffix?.value, skipBarcodesNotHeld: skipBarcodesNotHeld,
            otherCounts: otherCounts, tool: tool, toolVersion: toolVersion)
    }

    /// The command the record names, in one fixed order with absolute paths. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        var argv = [CLICommandIdentity.executableName, "rnaseq", "cell-map", "import", resultURL.path]
        argv += coordinates.flatMap { ["--coordinates", absolute($0)] } + clusters.flatMap { ["--clusters", absolute($0)] }
        argv += labelColumns.flatMap { ["--label-column", $0] } + methods.flatMap { ["--method", $0] }
        if let barcodeSuffix { argv += ["--barcode-suffix", barcodeSuffix.rawValue] }
        if skipBarcodesNotHeld { argv.append("--skip-barcodes-not-held") }
        if otherCounts { argv.append("--other-counts") }
        if let tool { argv += ["--tool", tool] }
        if let toolVersion { argv += ["--tool-version", toolVersion] }
        return argv + ["--output", outputURL.path]
    }

    func run() async throws {
        let command = self
        let eventsOn = globalOptions.outputFormat == .json
        let quiet = globalOptions.quiet
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(message: "Importing a cell map of a single-cell result.")
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
            let isInput = error is RNASeqCellMapImportRefusal || error is RNASeqPseudobulkRefusal || error is RNASeqResultError
                || error is RNASeqCellMapError || error is RNASeqResultWriterError
            throw (isInput ? CLIExitCode.inputError : CLIExitCode.workflowError).exitCode
        }
    }

    /// Checks, then writes through the one writer. Each note is a count the person should see: barcodes left out and
    /// cells with no coordinates.
    func write(notes: (String) -> Void) throws -> String {
        let startedAt = Date()
        let checked = try RNASeqCellMapImport.check(options, output: outputURL, createdAt: startedAt)
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(), stageObserver: { stage, _ in
            if stage == .tablesWritten { try ViewerExportLeaf.checkpointAfterStaging() }
        })
        let summary = try RNASeqCellMapImport.write(checked, to: outputURL, writer: writer) { summary in
            envelope(checked, summary: summary, startedAt: startedAt)
        }
        try Task.checkCancellation()
        for file in checked.files where file.notHeld.reduce(0, +) > 0 {
            notes("\(file.notHeld.reduce(0, +)) of the \(file.rows) barcodes of \(URL(fileURLWithPath: file.path).lastPathComponent) are not held by the result and were left out.")
        }
        for embedding in summary.embeddings {
            for (sample, leftOut) in zip(summary.samples, embedding.leftOut) where leftOut > 0 {
                notes("\(leftOut) of the \(sample.cells) cells of \(sample.name) have no coordinates in \(embedding.name) and are not drawn.")
            }
        }
        if checked.choices.counts == "computed on other counts" { notes("The embeddings were computed on other counts than the result's.") }
        let name = outputURL.deletingPathExtension().lastPathComponent
        let drawn = summary.embeddings.map { "\($0.name) draws \($0.drawn.reduce(0, +)) cells" }.joined(separator: ", ")
        return "Wrote the cell map \(name), where \(drawn), with \(summary.labelSets.count) label sets"
    }

    func envelope(_ checked: RNASeqCellMapImport.Checked, summary: RNASeqResultWriter.CellMapSummary, startedAt: Date) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope(
            createdAt: startedAt, workflowName: "RNA-seq cell map import", toolName: "lungfish rnaseq cell-map import",
            toolVersion: LungfishCLI.configuration.version)
        let argv = canonicalArgv()
        envelope.argv = argv
        envelope.reproducibleCommand = argv.map(ImportCommand.RNASeqSubcommand.Plan.shellQuoted).joined(separator: " ")
        var explicit: [String: ParameterValue] = ["result": .file(resultURL), "output": .file(outputURL)]
        explicit["coordinates"] = .array(coordinates.map { .file(URL(fileURLWithPath: absolute($0))) })
        if !clusters.isEmpty { explicit["clusters"] = .array(clusters.map { .file(URL(fileURLWithPath: absolute($0))) }) }
        if !labelColumns.isEmpty { explicit["labelColumns"] = .array(labelColumns.map { .string($0) }) }
        if !methods.isEmpty { explicit["methods"] = .array(methods.map { .string($0) }) }
        if let barcodeSuffix { explicit["barcodeSuffix"] = .string(barcodeSuffix.rawValue) }
        if skipBarcodesNotHeld { explicit["skipBarcodesNotHeld"] = .boolean(true) }
        if otherCounts { explicit["otherCounts"] = .boolean(true) }
        if let tool { explicit["tool"] = .string(tool) }
        if let toolVersion { explicit["toolVersion"] = .string(toolVersion) }
        envelope.options = ProvenanceOptions(explicit: explicit, defaults: [:], resolvedDefaults: RNASeqCellMapImport.facts(checked, summary: summary))
        envelope.files = RNASeqCellMapImport.files(checked, summary: summary, output: outputURL)
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity()
        envelope.wallTimeSeconds = Date().timeIntervalSince(startedAt)
        envelope.exitStatus = 0
        envelope.status = .completed
        return envelope
    }
}
