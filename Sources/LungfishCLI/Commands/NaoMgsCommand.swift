// NaoMgsCommand.swift - CLI command for importing NAO-MGS results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

/// Import and inspect NAO-MGS metagenomic surveillance workflow results.
///
/// The [nao-mgs-workflow](https://github.com/securebio/nao-mgs-workflow) is a
/// production-grade metagenomic surveillance pipeline from SecureBio. It runs
/// on cloud infrastructure (AWS, 128 GB+ RAM, 29 Docker containers) and produces
/// `virus_hits_final.tsv.gz` as its primary output.
///
/// This command imports those results into Lungfish by parsing the TSV and
/// optionally converting alignments to SAM format for viewport display.
///
/// ## Examples
///
/// ```
/// # Import results from a directory
/// lungfish nao-mgs import /path/to/nao-mgs-output/
///
/// # Import a specific file with a sample name
/// lungfish nao-mgs import virus_hits_final.tsv.gz --sample-name WW-2024-01
///
/// # View a quick summary
/// lungfish nao-mgs summary virus_hits_final.tsv.gz
///
/// # Import and convert to SAM
/// lungfish nao-mgs import virus_hits_final.tsv.gz --output-dir ./imported --sam
/// ```
struct NaoMgsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nao-mgs",
        abstract: "Import and view NAO-MGS metagenomic surveillance results",
        discussion: """
        Import results from the SecureBio NAO-MGS metagenomic surveillance
        pipeline. Parses virus_hits_final.tsv.gz and converts alignments to
        SAM format for display in the Lungfish genome viewer.
        """,
        subcommands: [ImportSubcommand.self, SummarySubcommand.self],
        defaultSubcommand: SummarySubcommand.self
    )

    // MARK: - Import Subcommand

    struct ImportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import NAO-MGS results and convert to SAM"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to NAO-MGS results directory or virus_hits_final.tsv(.gz)")
        var inputPath: String

        @Option(name: .customLong("sample-name"), help: "Override sample name")
        var sampleName: String?

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output directory for converted files (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("min-bitscore"),
            help: "Minimum bit score filter (default: 0)"
        )
        var minBitScore: Double = 0

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let parser = NaoMgsResultParser()

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw ExitCode.failure
            }

            // Determine if input is a directory or file
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir)

            let result: NaoMgsResult
            if isDir.boolValue {
                result = try await parser.loadResults(from: inputURL, sampleName: sampleName)
            } else {
                let hits = try await parser.parseVirusHits(at: inputURL)
                let resolvedName = sampleName ?? hits.first?.sample ?? inputURL
                    .deletingPathExtension().deletingPathExtension().lastPathComponent
                let summaries = parser.aggregateByTaxon(hits)
                result = NaoMgsResult(
                    virusHits: hits,
                    taxonSummaries: summaries,
                    totalHitReads: hits.count,
                    sampleName: resolvedName,
                    sourceDirectory: inputURL.deletingLastPathComponent(),
                    virusHitsFile: inputURL
                )
            }

            // Apply filters
            var filteredHits = result.virusHits
            if minBitScore > 0 {
                filteredHits = filteredHits.filter { $0.bitScore >= minBitScore }
            }

            // Print import summary
            print(formatter.header("NAO-MGS Import"))
            print("")
            print(formatter.keyValueTable([
                ("Sample", result.sampleName),
                ("Source", result.virusHitsFile.lastPathComponent),
                ("Total hits", String(result.totalHitReads)),
                ("After filters", String(filteredHits.count)),
                ("Distinct taxa", String(result.taxonSummaries.count)),
            ]))
            print("")

            // Print top taxa
            printTaxonSummary(result.taxonSummaries.prefix(15), formatter: formatter)

            // Resolve output directory
            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            // Create output directory if needed
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            // Write filtered hits as JSON for downstream use
            let jsonURL = outputDirectory.appendingPathComponent(
                "\(result.sampleName)_nao-mgs_summary.json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result.taxonSummaries)
            try jsonData.write(to: jsonURL, options: .atomic)
            print(formatter.success("Summary written to \(jsonURL.path)"))

            print("")
            print(formatter.success(
                "Imported \(filteredHits.count) virus hits from \(result.sampleName)"
            ))
        }
    }

    // MARK: - Summary Subcommand

    struct SummarySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "summary",
            abstract: "Display summary of NAO-MGS results"
        )

        @OptionGroup var globalOptions: GlobalOptions

        @Argument(help: "Path to virus_hits_final.tsv(.gz) or results directory")
        var inputPath: String

        @Option(
            name: .customLong("top"),
            help: "Number of top taxa to display (default: 20)"
        )
        var topN: Int = 20

        @Option(name: .customLong("format"), help: "Output format: text, json, tsv")
        var format: OutputFormat = .text

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let parser = NaoMgsResultParser()

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw ExitCode.failure
            }

            // Determine if input is a directory or file
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir)

            let result: NaoMgsResult
            if isDir.boolValue {
                result = try await parser.loadResults(from: inputURL)
            } else {
                let hits = try await parser.parseVirusHits(at: inputURL)
                let name = hits.first?.sample ?? inputURL
                    .deletingPathExtension().deletingPathExtension().lastPathComponent
                let summaries = parser.aggregateByTaxon(hits)
                result = NaoMgsResult(
                    virusHits: hits,
                    taxonSummaries: summaries,
                    totalHitReads: hits.count,
                    sampleName: name,
                    sourceDirectory: inputURL.deletingLastPathComponent(),
                    virusHitsFile: inputURL
                )
            }

            switch format {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(result.taxonSummaries)
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }

            case .tsv:
                print("taxid\tname\thit_count\tavg_identity\tavg_bitscore\taccessions")
                for summary in result.taxonSummaries.prefix(topN) {
                    let accStr = summary.accessions.joined(separator: ";")
                    print([
                        String(summary.taxId),
                        summary.name,
                        String(summary.hitCount),
                        String(format: "%.1f", summary.avgIdentity),
                        String(format: "%.1f", summary.avgBitScore),
                        accStr,
                    ].joined(separator: "\t"))
                }

            case .text:
                print(formatter.header("NAO-MGS Results Summary"))
                print("")
                print(formatter.keyValueTable([
                    ("Sample", result.sampleName),
                    ("Total virus hits", String(result.totalHitReads)),
                    ("Distinct taxa", String(result.taxonSummaries.count)),
                    ("Source", result.virusHitsFile.lastPathComponent),
                ]))
                print("")

                printTaxonSummary(result.taxonSummaries.prefix(topN), formatter: formatter)
            }
        }
    }
}

// MARK: - Shared Formatting

/// Prints a formatted taxon summary table.
///
/// Extracted as a free function to avoid `@MainActor`/`@Sendable` issues
/// with instance methods in `[weak self]` closures.
private func printTaxonSummary(
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
