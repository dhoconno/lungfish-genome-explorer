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
        subcommands: [RNASeqCellMapImportSubcommand.self, RNASeqCellMapSelectSubcommand.self, RNASeqCellMapComputeSubcommand.self]
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
            try command.write(stage: { fraction, words in events.emitProgress(fraction, message: words) }) { note in
                events.emitLog(note == Self.otherCountsNote ? .warning : .info, note)
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

    /// The one note that stays a warning on the event stream. The person stated that the embedding came from other counts, and the
    /// view and the record repeat it. The other notes are counts of what the person asked to leave out, and read at information level.
    static let otherCountsNote = "The embeddings were computed on other counts than the result's."

    /// Checks, then writes through the one writer. Each note is a count the person should see: barcodes left out and
    /// cells with no coordinates.
    func write(notes: (String) -> Void) throws -> String {
        try write(stage: { _, _ in }, notes: notes)
    }

    /// The same, and `stage` hears the three stages of the work as they begin, with a fraction for the bar: `Reading <file>` for
    /// each given file, `Checking barcodes against <result>` and `Writing <output>`. The app's row shows them (lane CM-IMPORT-APP).
    func write(stage: (Double, String) -> Void, notes: (String) -> Void) throws -> String {
        let startedAt = Date()
        for path in coordinates + clusters { stage(0.1, "Reading \(URL(fileURLWithPath: absolute(path)).lastPathComponent)") }
        stage(0.3, "Checking barcodes against \(resultURL.lastPathComponent)")
        let checked = try RNASeqCellMapImport.check(options, output: outputURL, createdAt: startedAt)
        stage(0.6, "Writing \(outputURL.lastPathComponent)")
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(), stageObserver: { stage, _ in
            if stage == .tablesWritten { try ViewerExportLeaf.checkpointAfterStaging() }
        })
        let summary = try RNASeqCellMapImport.write(checked, to: outputURL, writer: writer) { summary in
            envelope(checked, summary: summary, startedAt: startedAt)
        }
        try Task.checkCancellation()
        for file in checked.files where file.notHeld.reduce(0, +) > 0 {
            notes(Self.notHeldNote(file.notHeld.reduce(0, +), of: file.rows, file: URL(fileURLWithPath: file.path).lastPathComponent))
        }
        for embedding in summary.embeddings {
            for (sample, leftOut) in zip(summary.samples, embedding.leftOut) where leftOut > 0 {
                notes(Self.leftOutNote(leftOut, of: sample.cells, sample: sample.name, embedding: embedding.name))
            }
        }
        if checked.choices.counts == "computed on other counts" { notes(Self.otherCountsNote) }
        let name = outputURL.deletingPathExtension().lastPathComponent
        func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
        let drawn = summary.embeddings.map { "\($0.name) draws \(count($0.drawn.reduce(0, +), "cell"))" }.joined(separator: ", ")
        return "Wrote the cell map \(name), where \(drawn), with \(count(summary.labelSets.count, "label set"))"
    }

    /// "<k> of the <n> barcodes of <file> are not held by the result and were left out." The counts carry their thousands marks as
    /// the refusals write them, and the verbs agree with <k>: "1 of the 1,222 barcodes of projection.csv is not held ... was left out."
    static func notHeldNote(_ notHeld: Int, of rows: Int, file: String) -> String {
        let one = notHeld == 1
        return "\(RNASeqCellMapImportRefusal.number(notHeld)) of the \(RNASeqCellMapImportRefusal.count(rows, "barcode")) of \(file) "
            + "\(one ? "is" : "are") not held by the result and \(one ? "was" : "were") left out."
    }

    /// "<k> of the <n> cells of <sample> have no coordinates in <embedding> and are not drawn." The page's words for k above 1, with
    /// the counts marked as the refusals mark them, and "has" and "is" for k of 1.
    static func leftOutNote(_ leftOut: Int, of cells: Int, sample: String, embedding: String) -> String {
        let one = leftOut == 1
        return "\(RNASeqCellMapImportRefusal.number(leftOut)) of the \(RNASeqCellMapImportRefusal.count(cells, "cell")) of \(sample) "
            + "\(one ? "has" : "have") no coordinates in \(embedding) and \(one ? "is" : "are") not drawn."
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

/// Writes the label table of a selection of one embedding of a cell map, `selected` and `rest`, by a polygon of Float32
/// vertices or by labels of one set, with its record beside it (`docs/formats/rnaseq-cell-map.md`, cell-map select). The
/// app's Pseudobulk Selected Cells… and Save Selection as Labels Table… run this leaf, so their bytes equal the CLI's.
/// Every check runs before anything is written, and a refusal, an error or a SIGTERM leaves no table.
struct RNASeqCellMapSelectSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Write a label table of the cells a polygon or labels select in one embedding of a cell map",
        discussion: "Each cell drawn in the embedding gets one line, selected or rest, and a cell the embedding leaves out gets none, "
            + "so rnaseq pseudobulk counts it with the cells with no label. The table is written outside every result, with its record beside it."
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The selection was cancelled. No table was written."

    @Argument(help: "A cell map .lungfishrnaseq result")
    var cellMapPath: String

    // Each value is taken as given even when it starts with -, as a polygon whose first x is negative does, so the
    // recorded command parses back to the run's vertices and names.
    @Option(name: .customLong("embedding"), parsing: .unconditional, help: "The embedding whose drawn cells are selected or in the rest")
    var embedding: String

    @Option(name: .customLong("polygon"), parsing: .unconditional,
            help: "At least 3 and at most 1,000 vertices split by one space, each x,y, such as '0,0 10,0 10,10'")
    var polygon: String?

    @Option(name: .customLong("label-set"), parsing: .unconditional, help: "The label set whose labels select the cells")
    var labelSet: String?

    @Option(name: .customLong("label"), parsing: .unconditionalSingleValue, help: "A label of the set. Repeat for more")
    var labels: [String] = []

    @Option(name: .customLong("output"), help: "The new table to write, outside every .lungfishrnaseq folder. It must not exist")
    var outputPath: String

    @OptionGroup var globalOptions: GlobalOptions

    var cellMapURL: URL { URL(fileURLWithPath: cellMapPath).standardizedFileURL }
    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }

    /// The command the record names, in one fixed order with absolute paths and the polygon in Float32 shortest
    /// round-trip form. Parsing it gives equal options and the same vertices.
    func canonicalArgv(form: RNASeqCellMapSelect.Form) -> [String] {
        var argv = [CLICommandIdentity.executableName, "rnaseq", "cell-map", "select", cellMapURL.path, "--embedding", embedding]
        switch form {
        case .polygon(let vertices): argv += ["--polygon", RNASeqCellMapSelect.polygonText(vertices)]
        case .labels(let set, let labels): argv += ["--label-set", set] + labels.flatMap { ["--label", $0] }
        }
        return argv + ["--output", outputURL.path]
    }

    func run() async throws {
        let command = self
        let eventsOn = globalOptions.outputFormat == .json
        let quiet = globalOptions.quiet
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(message: "Selecting cells of a cell map.")
        let outcome = await runCancellingOnSIGTERM { () throws -> String in try command.write() }
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
            let isInput = error is RNASeqCellMapSelectRefusal || error is RNASeqPseudobulkRefusal || error is RNASeqResultError
            throw (isInput ? CLIExitCode.inputError : CLIExitCode.workflowError).exitCode
        }
    }

    /// Checks, selects, then writes the table and its record in one publication.
    func write() throws -> String {
        let runClock = ProvenanceRunClock()
        let form = try RNASeqCellMapSelect.form(polygon: polygon, labelSet: labelSet, labels: labels)
        try RNASeqCellMapSelect.checkOutput(outputURL)
        let selected = try RNASeqCellMapSelect.select(cellMap: cellMapURL, embedding: embedding, form: form)
        try Task.checkCancellation()
        var explicit: [String: ParameterValue] = ["cellMap": .file(cellMapURL), "embedding": .string(embedding), "output": .file(outputURL)]
        switch form {
        case .polygon(let vertices): explicit["polygon"] = .string(RNASeqCellMapSelect.polygonText(vertices))
        case .labels(let set, let labels):
            explicit["labelSet"] = .string(set)
            explicit["labels"] = .array(labels.map { .string($0) })
        }
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: "RNA-seq cell map selection",
            sourceURLs: [RNASeqResultBundle.manifestURL(in: cellMapURL)],
            outputURL: outputURL,
            outputFormat: .text,
            argv: canonicalArgv(form: form),
            explicitOptions: explicit,
            resolved: selected.facts,
            runClock: runClock
        )) { stagedURL in
            try selected.table.write(to: stagedURL)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        func count(_ n: Int, _ noun: String) -> String { "\(RNASeqCellMapImportRefusal.number(n)) \(noun)\(n == 1 ? "" : "s")" }
        let chosen = selected.samples.reduce(0) { $0 + $1.selected }
        let rest = selected.samples.reduce(0) { $0 + $1.rest }
        let leftOut = selected.samples.reduce(0) { $0 + $1.leftOut }
        func verb(_ n: Int) -> String { n == 1 ? "is" : "are" }
        var message = "Wrote \(outputURL.lastPathComponent), where \(count(chosen, "cell")) of \(embedding) \(verb(chosen)) selected "
            + "and \(count(rest, "cell")) \(verb(rest)) the rest"
        if leftOut > 0 {
            message += ", and \(count(leftOut, "cell")) of the map \(leftOut == 1 ? "has" : "have") no coordinates in \(embedding), "
                + "so the table has no line for \(leftOut == 1 ? "it" : "them")"
        }
        return message
    }
}
