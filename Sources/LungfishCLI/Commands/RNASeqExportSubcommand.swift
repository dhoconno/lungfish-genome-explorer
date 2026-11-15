// RNASeqExportSubcommand.swift - `lungfish-cli rnaseq export` (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Writes the counts of one or more RNA-seq results into a new folder that DESeq2, edgeR, limma voom and dream read, with
/// `alpha` set to the padj cutoff the person picks. The folder is written through one staged rename, never over an existing
/// folder. A table whose columns come from more than one route or reference set is refused in words, and no flag overrides it.
struct RNASeqExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export RNA-seq counts for DESeq2, edgeR and limma",
        discussion: "Writes counts.tsv, genes.tsv, samples.tsv, deseq2.R, edger-limma-dream.R (edgeR, limma voom and dream) and a record "
            + "into the new folder --output names. "
            + "The results must come from one route and one reference set. A route is the tool, its version and every setting that changes counts."
    )

    @Argument(help: "One or more .lungfishrnaseq result folders")
    var resultPaths: [String]

    @Option(name: .customLong("output"), help: "The new folder to write. It must not exist")
    var outputPath: String

    @Option(name: .customLong("sample-sheet"), help: "A tab-separated sheet with a sample column. Its other columns join samples.tsv")
    var sheetPath: String?

    @Option(name: .customLong("design"), help: "A column of samples.tsv that enters the model. Repeat it, and the last one is the tested factor")
    var design: [String] = []

    @Option(name: .customLong("contrast"), help: "FACTOR:NUMERATOR:DENOMINATOR, such as group:TB:HIV. Repeat it for more contrasts")
    var contrastWords: [String] = []

    @Option(name: .customLong("padj-cutoff"), help: "The adjusted p-value cutoff, which is also alpha in DESeq2's results()")
    var padjCutoff: Double = 0.05

    @Option(name: .customLong("lfc-bar"), help: "A bar on the absolute log2 fold change. None by default")
    var lfcBar: Double?

    @Option(name: .customLong("batch"), help: "The column of samples.tsv that names each sample's batch, for --batch-correction")
    var batch: String?

    @Option(name: .customLong("batch-correction"), help: "none, combat-seq or sva")
    var batchCorrection: String = "none"

    @OptionGroup var globalOptions: GlobalOptions

    var resultURLs: [URL] { resultPaths.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }
    var sheetURL: URL? { sheetPath.map { URL(fileURLWithPath: $0).standardizedFileURL } }

    mutating func validate() throws {
        guard padjCutoff > 0, padjCutoff <= 1 else { throw ValidationError("--padj-cutoff is a fraction above 0 and at most 1, such as 0.05.") }
        if let lfcBar, !(lfcBar >= 0 && lfcBar.isFinite) { throw ValidationError("--lfc-bar is a log2 fold change of 0 or more, such as 1.") }
        guard RNASeqExportSettings.BatchCorrection(rawValue: batchCorrection) != nil else {
            throw ValidationError("--batch-correction is none, combat-seq or sva.")
        }
        for words in contrastWords where words.split(separator: ":", omittingEmptySubsequences: false).filter({ !$0.isEmpty }).count != 3 {
            throw ValidationError("--contrast \(words) is not FACTOR:NUMERATOR:DENOMINATOR, such as group:TB:HIV.")
        }
    }

    func settings() -> RNASeqExportSettings {
        RNASeqExportSettings(
            design: design,
            contrasts: contrastWords.map { words in
                let parts = words.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                return .init(factor: parts[0], numerator: parts[1], denominator: parts[2])
            },
            padjCutoff: padjCutoff, lfcBar: lfcBar, batch: batch,
            batchCorrection: RNASeqExportSettings.BatchCorrection(rawValue: batchCorrection) ?? .none)
    }

    /// The command the record names, in one fixed order with absolute paths. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        var argv = [CLICommandIdentity.executableName, "rnaseq", "export"] + resultURLs.map(\.path) + ["--output", outputURL.path]
        if let sheetURL { argv += ["--sample-sheet", sheetURL.path] }
        for term in design { argv += ["--design", term] }
        for words in contrastWords { argv += ["--contrast", words] }
        argv += ["--padj-cutoff", "\(padjCutoff)"]
        if let lfcBar { argv += ["--lfc-bar", "\(lfcBar)"] }
        if let batch { argv += ["--batch", batch] }
        if batchCorrection != "none" { argv += ["--batch-correction", batchCorrection] }
        return argv
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(globalOptions: globalOptions, startMessage: "Exporting RNA-seq counts.") { _ in
            try command.export()
        }
    }

    /// The export, which refuses before it writes and publishes the folder and its record in one rename.
    func export() throws -> ViewerExportLeafOutcome {
        do {
            let folder = try RNASeqExport.run(
                results: resultURLs, sheet: sheetURL, settings: settings(), output: outputURL, argv: canonicalArgv(),
                checkpoint: { try ViewerExportLeaf.checkpointAfterStaging() })
            return ViewerExportLeafOutcome(outputURL: folder, message: "Exported \(resultURLs.count) RNA-seq result(s) to \(folder.lastPathComponent)")
        } catch let refusal as RNASeqExportRefusal {
            throw ViewerExportRefusal(refusal.message)
        }
    }
}
