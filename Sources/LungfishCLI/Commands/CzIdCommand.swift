// CzIdCommand.swift - CLI command for importing CZ-ID classification results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// Import and inspect CZ-ID hosted metagenomics taxon reports.
struct CzIdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cz-id",
        abstract: "Import and view CZ-ID classification results",
        discussion: """
        Import CZ-ID hosted metagenomics taxon report TSV exports into Lungfish's
        classification result schema. This command imports existing CZ-ID outputs;
        it does not run or submit data to CZ-ID.
        """,
        subcommands: [ImportSubcommand.self, SummarySubcommand.self],
        defaultSubcommand: SummarySubcommand.self
    )

    struct ImportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import a CZ-ID taxon report TSV into a Lungfish result directory"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output directory for the imported result (default: ./cz-id-{sample})"
        )
        var outputDir: String?

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let importResult = try await CzIdImportPreview.withResolvedReport(from: inputURL) { resolved in
                let parsed = try CzIdDataConverter.parseTaxonReport(at: resolved.reportURL)
                let sample = parsed.metadata.sampleName ?? resolved.reportURL.deletingPathExtension().lastPathComponent
                let destination = outputDir.map(URL.init(fileURLWithPath:))
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("cz-id-\(sample)", isDirectory: true)

                let command = ["lungfish", "cz-id", "import", inputURL.path, "--output-dir", destination.path]
                let sourceInput = resolved.selectedSourceURL.standardizedFileURL == resolved.reportURL.standardizedFileURL
                    ? nil
                    : resolved.selectedSourceURL
                let converted = try CzIdDataConverter.convertTaxonReport(
                    at: resolved.reportURL,
                    outputDirectory: destination,
                    command: command,
                    sourceInputURL: sourceInput
                )
                return (converted: converted, destination: destination, sample: sample)
            }

            if !globalOptions.quiet {
                print(formatter.header("CZ-ID Import"))
                print("")
                print(formatter.keyValueTable([
                    ("Sample", importResult.converted.manifest?.sampleName ?? importResult.sample),
                    ("Rows", String(importResult.converted.parsed.rows.count)),
                    ("Pipeline", importResult.converted.parsed.metadata.pipelineVersion ?? "unknown"),
                    ("NT database", importResult.converted.parsed.metadata.ntDatabaseVersion ?? "unknown"),
                    ("NR database", importResult.converted.parsed.metadata.nrDatabaseVersion ?? "unknown"),
                    ("Output", importResult.destination.path),
                ]))
                print("")
            }

            print(formatter.success("Imported CZ-ID taxon report into \(importResult.destination.path)"))
        }
    }

    struct SummarySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "summary",
            abstract: "Display a summary of a CZ-ID taxon report TSV"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to a CZ-ID taxon report TSV")
        var inputPath: String

        @Option(name: .customLong("top"), help: "Number of top taxa to display (default: 20)")
        var topN: Int = 20

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let parsed = try CzIdDataConverter.parseTaxonReport(at: inputURL)
            let topRows = parsed.rows
                .filter { $0.taxId != 1 }
                .sorted { $0.ntReadCount > $1.ntReadCount }
                .prefix(topN)

            switch globalOptions.outputFormat {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let json = String(data: try encoder.encode(Array(topRows)), encoding: .utf8) {
                    print(json)
                }
            case .tsv:
                print("tax_id\tname\trank\tnt_reads\tnt_rpm\tnr_reads")
                for row in topRows {
                    print([
                        String(row.taxId),
                        row.name,
                        row.rank,
                        String(row.ntReadCount),
                        String(format: "%.3f", row.ntRpm),
                        row.nrReadCount.map(String.init) ?? "",
                    ].joined(separator: "\t"))
                }
            case .text:
                print(formatter.header("CZ-ID Results Summary"))
                print("")
                print(formatter.keyValueTable([
                    ("Sample", parsed.metadata.sampleName ?? inputURL.deletingPathExtension().lastPathComponent),
                    ("Rows", String(parsed.rows.count)),
                    ("Pipeline", parsed.metadata.pipelineVersion ?? "unknown"),
                    ("NT database", parsed.metadata.ntDatabaseVersion ?? "unknown"),
                    ("NR database", parsed.metadata.nrDatabaseVersion ?? "unknown"),
                ]))
                print("")
                let rows = topRows.map {
                    [
                        String($0.taxId),
                        String($0.name.prefix(50)),
                        $0.rank,
                        String($0.ntReadCount),
                        String(format: "%.1f", $0.ntRpm),
                    ]
                }
                print(formatter.table(headers: ["TaxID", "Organism", "Rank", "NT Reads", "NT RPM"], rows: rows))
            }
        }
    }
}
