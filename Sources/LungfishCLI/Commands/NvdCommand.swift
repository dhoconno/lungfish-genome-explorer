// NvdCommand.swift - CLI command for importing NVD classification results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

/// Import and inspect NVD (Novel Virus Diagnostics) pipeline BLAST results.
///
/// The NVD Snakemake pipeline produces `*_blast_concatenated.csv(.gz)` as its primary
/// output, along with BAM alignment files and assembled FASTA sequences.
///
/// This command imports those results into Lungfish by parsing the BLAST CSV and
/// optionally copying alignment and assembly files into a project directory.
///
/// ## Examples
///
/// ```
/// # Show summary of NVD results
/// lungfish nvd /path/to/nvd-output/
///
/// # Import NVD results into a project
/// lungfish nvd import /path/to/nvd-output/ --output-dir ./project/Imports/
///
/// # Show summary of a specific CSV
/// lungfish nvd summary /path/to/100_blast_concatenated.csv.gz
/// ```
struct NvdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nvd",
        abstract: "Import and view NVD classification results",
        discussion: """
        Import results from the Novel Virus Diagnostics (NVD) Snakemake pipeline.
        Parses *_blast_concatenated.csv(.gz) files containing BLAST hit rankings and
        per-contig mapped read counts for wastewater viral surveillance.
        """,
        subcommands: [ImportSubcommand.self, SummarySubcommand.self],
        defaultSubcommand: SummarySubcommand.self
    )

    // MARK: - Import Subcommand

    struct ImportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import NVD results into a Lungfish project"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to NVD results directory (containing 05_labkey_bundling/)")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output directory for the imported bundle (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Override the bundle name (default: nvd-{experiment})"
        )
        var name: String?

        #if DEBUG
        var testingCreateProvenanceCollision = false
        #endif

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let fileManager = FileManager.default
            let inputURL = URL(fileURLWithPath: inputPath)

            guard fileManager.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input directory not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            if !globalOptions.quiet {
                print(formatter.header("NVD Import"))
                print("")
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            var provenanceCommand = [
                "lungfish",
                "nvd",
                "import",
                inputURL.path,
                "--output-dir",
                outputDirectory.path,
            ]
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                provenanceCommand += ["--name", name]
            }
            let provenanceCollisionHook: Bool
            #if DEBUG
            provenanceCollisionHook = testingCreateProvenanceCollision
            #else
            provenanceCollisionHook = false
            #endif

            do {
                let imported = try await MetagenomicsImportService.importNvd(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name,
                    allowUniqueSuffix: false,
                    samtoolsPath: nil,
                    provenanceCommand: provenanceCommand,
                    provenanceWorkflowName: "lungfish nvd import",
                    provenanceToolName: "lungfish nvd import",
                    provenanceCollisionTestHook: provenanceCollisionHook,
                    progress: { progress, message in
                        if !globalOptions.quiet, progress < 1.0 {
                            print(formatter.info(message))
                        }
                    }
                )

                if !globalOptions.quiet {
                    print(formatter.keyValueTable([
                        ("Total hits", String(imported.hitCount)),
                        ("Samples", String(imported.sampleCount)),
                        ("Contigs", String(imported.contigCount)),
                        ("Output", imported.resultDirectory.lastPathComponent),
                    ]))
                    print("")
                    print(formatter.success("NVD import complete: \(imported.resultDirectory.lastPathComponent)"))
                }
            } catch {
                print(formatter.error(error.localizedDescription))
                throw nvdImportExitCode(for: error).exitCode
            }
        }
    }

    // MARK: - Summary Subcommand

    struct SummarySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "summary",
            abstract: "Display summary of NVD results"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to NVD results directory or *_blast_concatenated.csv(.gz) file")
        var inputPath: String

        @Option(
            name: .customLong("top"),
            help: "Number of top contigs to display (default: 20)"
        )
        var topN: Int = 20

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Determine if input is a directory or CSV file
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir)

            let csvURL: URL
            if isDir.boolValue {
                let labkeyDir = inputURL.appendingPathComponent("05_labkey_bundling", isDirectory: true)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: labkeyDir,
                    includingPropertiesForKeys: nil
                )
                guard let found = contents.first(where: NvdResultParser.isBlastConcatenatedCSV) else {
                    print(formatter.error("No *_blast_concatenated.csv or *.csv.gz found in 05_labkey_bundling/"))
                    throw CLIExitCode.inputError.exitCode
                }
                csvURL = found
            } else {
                csvURL = inputURL
            }

            let parser = NvdResultParser()
            let result: NvdParseResult
            do {
                result = try await parser.parse(at: csvURL)
            } catch let error as NvdParserError {
                print(formatter.error(error.localizedDescription))
                throw nvdExitCode(for: error).exitCode
            }

            switch globalOptions.outputFormat {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let topHits = Array(result.hits.filter { $0.hitRank == 1 }.prefix(topN))
                let rows = topHits.map { hit in
                    NvdContigRow(
                        sampleId: hit.sampleId,
                        qseqid: hit.qseqid,
                        qlen: hit.qlen,
                        adjustedTaxidName: hit.adjustedTaxidName,
                        adjustedTaxidRank: hit.adjustedTaxidRank,
                        sseqid: hit.sseqid,
                        stitle: hit.stitle,
                        pident: hit.pident,
                        evalue: hit.evalue,
                        bitscore: hit.bitscore,
                        mappedReads: hit.mappedReads,
                        readsPerBillion: hit.readsPerBillion
                    )
                }
                if let json = String(data: try encoder.encode(rows), encoding: .utf8) {
                    print(json)
                }

            case .tsv:
                print("sample_id\tqseqid\tqlen\tadjusted_taxid_name\tsseqid\tpident\tevalue\tbitscore\tmapped_reads\trpb")
                for hit in result.hits.filter({ $0.hitRank == 1 }).prefix(topN) {
                    print([
                        hit.sampleId,
                        hit.qseqid,
                        String(hit.qlen),
                        hit.adjustedTaxidName,
                        hit.sseqid,
                        String(format: "%.1f", hit.pident),
                        String(hit.evalue),
                        String(format: "%.1f", hit.bitscore),
                        String(hit.mappedReads),
                        String(format: "%.2f", hit.readsPerBillion),
                    ].joined(separator: "\t"))
                }

            case .text:
                print(formatter.header("NVD Results Summary"))
                print("")
                print(formatter.keyValueTable([
                    ("Experiment", result.experiment.isEmpty ? "(none)" : result.experiment),
                    ("Source", csvURL.lastPathComponent),
                    ("Total BLAST hits", String(result.hits.count)),
                    ("Samples", String(result.sampleIds.count)),
                    ("Unique contigs", String(Set(result.hits.map { "\($0.sampleId)\u{1F}\($0.qseqid)" }).count)),
                ]))
                print("")
                nvdPrintTopContigs(result.hits.filter { $0.hitRank == 1 }.prefix(topN), formatter: formatter)
            }
        }
    }
}

private func nvdImportExitCode(for error: Error) -> CLIExitCode {
    if let importError = error as? MetagenomicsImportError {
        switch importError {
        case .inputNotFound:
            return .inputError
        case .parseFailed:
            return .formatError
        case .outputDirectoryCreationFailed, .copyFailed, .outputAlreadyExists:
            return .outputError
        case .toolUnavailable:
            return .dependency
        case .importAborted:
            return .outputError
        }
    }
    if error is CancellationError {
        return .cancelled
    }
    return .workflowError
}

private func nvdExitCode(for error: NvdParserError) -> CLIExitCode {
    switch error {
    case .fileNotFound:
        return .inputError
    case .invalidHeader, .malformedRow:
        return .formatError
    }
}

// MARK: - Shared Formatting

/// Prints a formatted top-contigs table.
///
/// Free function to avoid @MainActor isolation issues with instance methods.
private func nvdPrintTopContigs(
    _ hits: some Collection<NvdBlastHit>,
    formatter: TerminalFormatter
) {
    guard !hits.isEmpty else { return }

    print(formatter.header("Top Contigs (Best BLAST Hits)"))
    print("")

    let rows: [[String]] = hits.map { hit in
        [
            hit.sampleId,
            String(hit.qseqid.prefix(30)),
            String(hit.qlen),
            String(hit.adjustedTaxidName.prefix(40)),
            String(format: "%.1f%%", hit.pident),
            String(format: "%.1f", hit.bitscore),
            String(hit.mappedReads),
        ]
    }

    print(formatter.table(
        headers: ["Sample", "Contig", "Len", "Organism", "%ID", "Score", "Reads"],
        rows: rows
    ))
    print("")
}
