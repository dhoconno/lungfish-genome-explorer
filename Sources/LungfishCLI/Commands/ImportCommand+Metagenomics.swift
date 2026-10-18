// ImportCommand+Metagenomics.swift - The kraken2, esviritu, taxtriage, nao-mgs and nvd import leaves with their helpers, moved out of ImportCommand.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Kraken2 Import

extension ImportCommand {

    /// Import Kraken2 classification results into a Lungfish project.
    ///
    /// Copies the kreport (and optionally the per-read output file) into a
    /// `classification-kraken2` subdirectory and prints a species summary.
    struct Kraken2Subcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kraken2",
            abstract: "Import Kraken2 classification results"
        )

        @Argument(help: "Path to the Kraken2 kreport file")
        var kreportFile: String

        @Option(
            name: .customLong("output"),
            help: "Path to the Kraken2 per-read output file"
        )
        var outputFile: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// With `--format json` the run prints the events the Import Center's row shows, and SIGTERM cancels it
        /// with exit 125 (`ClassifierResultImportRun`, Phase 2.12 lane 12.04).
        func run() async throws {
            let importRun = ClassifierResultImportRun(kind: .kraken2, globalOptions: globalOptions)
            let formatter = importRun.formatter
            let kreportURL = URL(fileURLWithPath: kreportFile)

            guard FileManager.default.fileExists(atPath: kreportURL.path) else {
                importRun.refuse("Kreport file not found: \(kreportFile)")
                throw CLIExitCode.inputError.exitCode
            }

            if let outputPath = outputFile {
                guard FileManager.default.fileExists(atPath: outputPath) else {
                    importRun.refuse("Output file not found: \(outputPath)")
                    throw CLIExitCode.inputError.exitCode
                }
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            importRun.say(formatter.header("Kraken2 Import"))
            importRun.say("")

            let kreportData: Data
            do {
                kreportData = try Data(contentsOf: kreportURL)
            } catch {
                importRun.refuse("Failed to parse kreport: \(error.localizedDescription)")
                throw CLIExitCode.formatError.exitCode
            }
            guard let kreportContent = String(data: kreportData, encoding: .utf8) else {
                importRun.refuse("Cannot read kreport file as text")
                throw CLIExitCode.formatError.exitCode
            }
            let parsed = parseKreport(kreportContent)

            let imported: Kraken2ImportResult
            do {
                let outputFileURL = outputFile.map { URL(fileURLWithPath: $0) }
                let preferredName = name
                let provenanceCommand = [
                    CLICommandIdentity.executableName,
                    "import",
                    "kraken2",
                    kreportURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ] + (outputFileURL.map { ["--output", $0.path] } ?? []) + (name.map { ["--name", $0] } ?? [])
                imported = try await importRun.perform(input: kreportURL, outputDirectory: outputDirectory) { progress in
                    try MetagenomicsImportService.importKraken2(
                        kreportURL: kreportURL,
                        outputDirectory: outputDirectory,
                        outputFileURL: outputFileURL,
                        preferredName: preferredName,
                        provenanceCommand: provenanceCommand,
                        progress: progress
                    )
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                throw metagenomicsImportExitCode(for: error).exitCode
            }
            importRun.complete(imported.resultDirectory, message: ClassifierResultImportWords.kraken2(imported))

            importRun.say(formatter.keyValueTable([
                ("Kreport", kreportURL.lastPathComponent),
                ("Output", imported.resultDirectory.lastPathComponent),
                ("Total reads", formatNumber(Int64(imported.totalReads))),
                ("Classified", formatNumber(Int64(parsed.classifiedReads))),
                ("Unclassified", formatNumber(Int64(parsed.unclassifiedReads))),
                ("Species", String(imported.speciesCount)),
            ]))
            importRun.say("")

            if !parsed.speciesEntries.isEmpty {
                importRun.say(formatter.header("Top Species"))
                importRun.say("")

                let topSpecies = parsed.speciesEntries
                    .sorted { $0.reads > $1.reads }
                    .prefix(15)

                let rows: [[String]] = topSpecies.map { entry in
                    [
                        entry.name,
                        formatNumber(Int64(entry.reads)),
                        String(format: "%.2f%%", entry.percentage),
                    ]
                }

                importRun.say(formatter.table(
                    headers: ["Species", "Reads", "Fraction"],
                    rows: Array(rows)
                ))
                importRun.say("")
            }

            importRun.say(formatter.success("Kraken2 import complete: \(imported.resultDirectory.lastPathComponent)"))
        }
    }
}

// MARK: - EsViritu Import

extension ImportCommand {

    /// Import EsViritu viral detection results into a Lungfish project.
    ///
    /// Copies the results directory and prints a detection summary.
    struct EsVirituSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "esviritu",
            abstract: "Import EsViritu viral detection results"
        )

        @Argument(help: "Path to the EsViritu results directory")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// With `--format json` the run prints the events the Import Center's row shows, and SIGTERM cancels it
        /// with exit 125 (`ClassifierResultImportRun`, Phase 2.12 lane 12.04).
        func run() async throws {
            let importRun = ClassifierResultImportRun(kind: .esviritu, globalOptions: globalOptions)
            let formatter = importRun.formatter
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                importRun.refuse("Input path not found: \(inputPath)")
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            importRun.say(formatter.header("EsViritu Import"))
            importRun.say("")

            let imported: EsVirituImportResult
            do {
                let preferredName = name
                let provenanceCommand = [
                    CLICommandIdentity.executableName,
                    "import",
                    "esviritu",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ] + (name.map { ["--name", $0] } ?? [])
                imported = try await importRun.perform(input: inputURL, outputDirectory: outputDirectory) { progress in
                    try MetagenomicsImportService.importEsViritu(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        preferredName: preferredName,
                        provenanceCommand: provenanceCommand,
                        progress: progress
                    )
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                throw metagenomicsImportExitCode(for: error).exitCode
            }
            importRun.complete(imported.resultDirectory, message: ClassifierResultImportWords.esViritu(imported))

            importRun.say(formatter.keyValueTable([
                ("Source", inputURL.lastPathComponent),
                ("Files imported", String(imported.importedFileCount)),
                ("Detections", String(imported.virusCount)),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            importRun.say("")

            importRun.say(formatter.success("EsViritu import complete: \(imported.importedFileCount) file(s)"))
        }
    }
}

// MARK: - TaxTriage Import

extension ImportCommand {

    /// Import TaxTriage classification results into a Lungfish project.
    ///
    /// Copies the results directory and prints a triage summary.
    struct TaxTriageSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "taxtriage",
            abstract: "Import TaxTriage classification results"
        )

        @Argument(help: "Path to the TaxTriage results directory")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// With `--format json` the run prints the events the Import Center's row shows, and SIGTERM cancels it
        /// with exit 125 (`ClassifierResultImportRun`, Phase 2.12 lane 12.04).
        func run() async throws {
            let importRun = ClassifierResultImportRun(kind: .taxtriage, globalOptions: globalOptions)
            let formatter = importRun.formatter
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                importRun.refuse("Input path not found: \(inputPath)")
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            importRun.say(formatter.header("TaxTriage Import"))
            importRun.say("")

            let imported: TaxTriageImportResult
            do {
                let preferredName = name
                let provenanceCommand = [
                    CLICommandIdentity.executableName,
                    "import",
                    "taxtriage",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ] + (name.map { ["--name", $0] } ?? [])
                imported = try await importRun.perform(input: inputURL, outputDirectory: outputDirectory) { progress in
                    try MetagenomicsImportService.importTaxTriage(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        preferredName: preferredName,
                        provenanceCommand: provenanceCommand,
                        progress: progress
                    )
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                throw metagenomicsImportExitCode(for: error).exitCode
            }
            importRun.complete(imported.resultDirectory, message: ClassifierResultImportWords.taxTriage(imported))

            importRun.say(formatter.keyValueTable([
                ("Source", inputURL.lastPathComponent),
                ("Files imported", String(imported.importedFileCount)),
                ("Report entries", imported.reportEntryCount > 0 ? String(imported.reportEntryCount) : "N/A"),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            importRun.say("")

            // List imported files.
            let importedFiles = scanRegularFilesRecursively(in: imported.resultDirectory)
            if !globalOptions.quiet && !importedFiles.isEmpty {
                importRun.say(formatter.header("Imported Files"))
                for file in importedFiles.prefix(20) {
                    importRun.say("  \(formatter.path(file.lastPathComponent))")
                }
                if importedFiles.count > 20 {
                    importRun.say("  (+\(importedFiles.count - 20) more)")
                }
                importRun.say("")
            }

            importRun.say(formatter.success("TaxTriage import complete: \(imported.importedFileCount) file(s)"))
        }
    }
}

// MARK: - NAO-MGS Import

extension ImportCommand {

    /// Import NAO-MGS metagenomic surveillance results into a Lungfish project.
    ///
    /// Creates a canonical `naomgs-*` bundle containing manifest, cached hits,
    /// optional BAM alignment files, and downloaded references.
    struct NaoMgsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "nao-mgs",
            abstract: "Import NAO-MGS metagenomic surveillance results"
        )

        @Argument(help: "Path to NAO-MGS results directory or virus_hits_final.tsv(.gz)")
        var inputPath: String

        @Option(name: .customLong("sample-name"), help: "Override sample name")
        var sampleName: String?

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project/import directory (default: current directory)"
        )
        var outputDir: String?

        @Flag(
            name: .customLong("fetch-references"),
            inversion: .prefixedNo,
            help: "Fetch NCBI reference FASTA files into references/"
        )
        var fetchReferences: Bool = true

        @OptionGroup var globalOptions: GlobalOptions

        /// With `--format json` the run prints the events the Import Center's row shows, and SIGTERM cancels it
        /// with exit 125 (`ClassifierResultImportRun.performAsync`, Phase 2.12 lane 12.05).
        func run() async throws {
            let importRun = ClassifierResultImportRun(kind: .naomgs, globalOptions: globalOptions)
            let formatter = importRun.formatter

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                importRun.refuse("Input not found: \(inputPath)")
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            let imported: NaoMgsImportResult
            do {
                var command = [
                    CLICommandIdentity.executableName,
                    "import",
                    "nao-mgs",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ]
                if let sampleName {
                    command += ["--sample-name", sampleName]
                }
                if !fetchReferences {
                    command.append("--no-fetch-references")
                }
                let provenanceCommand = command
                let sampleName = sampleName
                let fetchReferences = fetchReferences
                let textProgress = !importRun.eventsOn && !globalOptions.quiet
                imported = try await importRun.performAsync(input: inputURL, outputDirectory: outputDirectory) { progress in
                    try await MetagenomicsImportService.importNaoMgs(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        sampleName: sampleName,
                        fetchReferences: fetchReferences,
                        preferredName: sampleName,
                        provenanceCommand: provenanceCommand
                    ) { fraction, message in
                        progress(fraction, message)
                        if textProgress {
                            print(String(format: "[%3.0f%%] %@", fraction * 100, message))
                        }
                    }
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                throw metagenomicsImportExitCode(for: error).exitCode
            }
            importRun.complete(imported.resultDirectory, message: NaoMgsNvdImportWords.naoMgs(imported))

            importRun.say(formatter.header("NAO-MGS Import"))
            importRun.say("")
            importRun.say(formatter.keyValueTable([
                ("Sample", imported.sampleName),
                ("Total hits", formatNumber(Int64(imported.totalHitReads))),
                ("Distinct taxa", String(imported.taxonCount)),
                ("References fetched", String(imported.fetchedReferenceCount)),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            importRun.say("")
            importRun.say(formatter.success("NAO-MGS import complete: \(imported.resultDirectory.lastPathComponent)"))
        }
    }

    // MARK: - NVD Import

    /// Import NVD (Novel Virus Diagnostics) BLAST results into a Lungfish project.
    ///
    /// Parses `*_blast_concatenated.csv(.gz)` and writes an app-viewable
    /// `nvd-{experiment}` bundle with `manifest.json`, `hits.sqlite`, copied
    /// sample assets when present, and canonical provenance.
    struct NvdSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "nvd",
            abstract: "Import NVD BLAST results"
        )

        @Argument(help: "Path to NVD results directory (containing 05_labkey_bundling/)")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project/import directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Override the bundle name (default: nvd-{experiment})"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// With `--format json` the run prints the events the Import Center's row shows, and SIGTERM cancels it
        /// with exit 125 (`ClassifierResultImportRun.performAsync`, Phase 2.12 lane 12.05).
        func run() async throws {
            let importRun = ClassifierResultImportRun(kind: .nvd, globalOptions: globalOptions)
            let formatter = importRun.formatter
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                importRun.refuse("Input directory not found: \(inputPath)")
                throw CLIExitCode.inputError.exitCode
            }

            if !globalOptions.quiet {
                importRun.say(formatter.header("NVD Import"))
                importRun.say("")
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            var command = [
                CLICommandIdentity.executableName,
                "import",
                "nvd",
                inputURL.path,
                "--output-dir",
                outputDirectory.path,
            ]
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                command += ["--name", name]
            }

            let imported: NvdImportResult
            do {
                let provenanceCommand = command
                let preferredName = name
                let samtoolsPath = MetagenomicsImportService.managedSamtoolsPath()
                let useColors = globalOptions.useColors
                let textProgress = !importRun.eventsOn && !globalOptions.quiet
                imported = try await importRun.performAsync(input: inputURL, outputDirectory: outputDirectory) { progress in
                    try await MetagenomicsImportService.importNvd(
                        inputURL: inputURL,
                        outputDirectory: outputDirectory,
                        preferredName: preferredName,
                        samtoolsPath: samtoolsPath,
                        provenanceCommand: provenanceCommand
                    ) { fraction, message in
                        progress(fraction, message)
                        if textProgress, fraction < 1.0 {
                            print(TerminalFormatter(useColors: useColors).info(message))
                        }
                    }
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                throw metagenomicsImportExitCode(for: error).exitCode
            }
            importRun.complete(imported.resultDirectory, message: NaoMgsNvdImportWords.nvd(imported))

            if !globalOptions.quiet {
                importRun.say(formatter.keyValueTable([
                    ("Total hits", String(imported.hitCount)),
                    ("Samples", String(imported.sampleCount)),
                    ("Contigs", String(imported.contigCount)),
                    ("Output", imported.resultDirectory.lastPathComponent),
                ]))
                importRun.say("")
                importRun.say(formatter.success("NVD import complete: \(imported.resultDirectory.lastPathComponent)"))
            }
        }
    }
}

// MARK: - Metagenomics Import Error Mapping

private func metagenomicsImportExitCode(for error: Error) -> CLIExitCode {
    if let importError = error as? MetagenomicsImportError {
        return metagenomicsImportExitCode(for: importError)
    }
    if error is CancellationError {
        return .cancelled
    }
    return .workflowError
}

private func metagenomicsImportExitCode(for error: MetagenomicsImportError) -> CLIExitCode {
    switch error {
    case .inputNotFound:
        return .inputError
    case .parseFailed:
        return .formatError
    case .outputAlreadyExists:
        return .outputError
    case .outputDirectoryCreationFailed, .copyFailed:
        return .outputError
    case .toolUnavailable:
        return .dependency
    case .importAborted(_, let underlying):
        return metagenomicsImportExitCode(for: underlying)
    }
}

// MARK: - Kreport Parsing

/// Parsed entry from a Kraken2 kreport file.
private struct KreportEntry {
    let percentage: Double
    let reads: Int
    let name: String
    let rank: String
}

/// Parsed summary from a Kraken2 kreport file.
private struct KreportSummary {
    let totalReads: Int
    let classifiedReads: Int
    let unclassifiedReads: Int
    let speciesEntries: [KreportEntry]
}

/// Parses a Kraken2 kreport file.
///
/// kreport format columns:
/// 1. % of reads at or below this node
/// 2. Number of reads at or below this node
/// 3. Number of reads assigned directly to this node
/// 4. Rank code (U, R, D, P, C, O, F, G, S, etc.)
/// 5. NCBI taxonomy ID
/// 6. Scientific name (indented)
private func parseKreport(_ content: String) -> KreportSummary {
    var totalReads = 0
    var unclassifiedReads = 0
    var classifiedReads = 0
    var speciesEntries: [KreportEntry] = []

    let lines = content.split(separator: "\n")
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let cols = trimmed.split(separator: "\t")
        guard cols.count >= 6 else { continue }

        let percentage = Double(cols[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let cumulativeReads = Int(cols[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let rank = String(cols[3].trimmingCharacters(in: .whitespaces))
        let name = String(cols[5].trimmingCharacters(in: .whitespaces))

        if rank == "U" {
            unclassifiedReads = cumulativeReads
        } else if rank == "R" {
            // Root-level entry gives us total classified.
            totalReads = cumulativeReads + unclassifiedReads
            classifiedReads = cumulativeReads
        }

        if rank == "S" {
            speciesEntries.append(KreportEntry(
                percentage: percentage,
                reads: cumulativeReads,
                name: name,
                rank: rank
            ))
        }
    }

    // If we never saw root, estimate from unclassified percentage.
    if totalReads == 0 && unclassifiedReads > 0 {
        totalReads = unclassifiedReads
        classifiedReads = 0
    }

    return KreportSummary(
        totalReads: totalReads,
        classifiedReads: classifiedReads,
        unclassifiedReads: unclassifiedReads,
        speciesEntries: speciesEntries
    )
}

// MARK: - NAO-MGS Taxon Summary Printer

/// Prints a formatted NAO-MGS taxon summary table.
///
/// Extracted as a free function to avoid `@MainActor`/`@Sendable` issues.
private func printNaoMgsTaxonSummary(
    _ summaries: some Collection<NaoMgsTaxonSummary>,
    formatter: TerminalFormatter
) {
    guard !summaries.isEmpty else { return }

    print(formatter.header("Top Viral Taxa"))
    print("")

    let rows: [[String]] = summaries.map { summary in
        [
            String(summary.taxId),
            String(summary.name.prefix(50)),
            String(summary.hitCount),
            String(format: "%.1f%%", summary.avgIdentity),
            String(format: "%.1f", summary.avgBitScore),
            String(summary.accessions.count),
        ]
    }

    print(formatter.table(
        headers: ["TaxID", "Organism", "Hits", "Avg %ID", "Avg Score", "Refs"],
        rows: rows
    ))
    print("")
}
