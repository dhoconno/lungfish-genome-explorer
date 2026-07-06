// NaoMgsCommand.swift - CLI command for importing NAO-MGS results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Import and inspect NAO-MGS metagenomic surveillance workflow results.
///
/// The [nao-mgs-workflow](https://github.com/securebio/nao-mgs-workflow) is a
/// production-grade metagenomic surveillance pipeline from SecureBio. It runs
/// on cloud infrastructure (AWS, 128 GB+ RAM, 29 Docker containers) and produces
/// `virus_hits_final.tsv.gz` as its primary output.
///
/// This command parses those results and writes a standalone JSON summary.
/// Use `lungfish import nao-mgs` when you need a canonical project bundle for
/// the app viewport.
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
/// # Write a filtered standalone summary
/// lungfish nao-mgs import virus_hits_final.tsv.gz --output-dir ./summaries --min-bitscore 80
/// ```
struct NaoMgsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nao-mgs",
        abstract: "Import and view NAO-MGS metagenomic surveillance results",
        discussion: """
        Import results from the SecureBio NAO-MGS metagenomic surveillance
        pipeline. Parses virus_hits_final.tsv.gz and writes a standalone JSON
        summary. Use `lungfish import nao-mgs` for a project bundle.
        """,
        subcommands: [ImportSubcommand.self, SummarySubcommand.self],
        defaultSubcommand: SummarySubcommand.self
    )

    // MARK: - Import Subcommand

    struct ImportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import NAO-MGS results as a standalone JSON summary"
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
            let startedAt = Date()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let parser = NaoMgsResultParser()

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Determine if input is a directory or file
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir)

            let result: NaoMgsResult
            do {
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
            } catch let error as NaoMgsError {
                print(formatter.error(error.localizedDescription))
                throw naoMgsExitCode(for: error).exitCode
            }

            // Apply filters
            var filteredHits = result.virusHits
            if minBitScore > 0 {
                filteredHits = filteredHits.filter { $0.bitScore >= minBitScore }
            }
            let filteredSummaries = minBitScore > 0
                ? parser.aggregateByTaxon(filteredHits)
                : result.taxonSummaries

            // Print import summary
            print(formatter.header("NAO-MGS Import"))
            print("")
            print(formatter.keyValueTable([
                ("Sample", result.sampleName),
                ("Source", result.virusHitsFile.lastPathComponent),
                ("Total hits", String(result.totalHitReads)),
                ("After filters", String(filteredHits.count)),
                ("Distinct taxa", String(filteredSummaries.count)),
            ]))
            print("")

            // Print top taxa
            printTaxonSummary(filteredSummaries.prefix(15), formatter: formatter)

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
            let jsonData = try encoder.encode(filteredSummaries)
            try jsonData.write(to: jsonURL, options: .atomic)
            do {
                try await recordStandaloneImportProvenance(
                    inputURL: inputURL,
                    parsedVirusHitsURL: result.virusHitsFile,
                    outputDirectory: outputDirectory,
                    outputURL: jsonURL,
                    result: result,
                    filteredHitCount: filteredHits.count,
                    filteredTaxonCount: filteredSummaries.count,
                    startedAt: startedAt
                )
            } catch {
                try? FileManager.default.removeItem(at: jsonURL)
                try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: jsonURL))
                try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
                throw error
            }
            print(formatter.success("Summary written to \(jsonURL.path)"))

            print("")
            print(formatter.success(
                "Imported \(filteredHits.count) virus hits from \(result.sampleName)"
            ))
        }

        private func recordStandaloneImportProvenance(
            inputURL: URL,
            parsedVirusHitsURL: URL,
            outputDirectory: URL,
            outputURL: URL,
            result: NaoMgsResult,
            filteredHitCount: Int,
            filteredTaxonCount: Int,
            startedAt: Date
        ) async throws {
            let completedAt = Date()
            let wallTime = max(0, completedAt.timeIntervalSince(startedAt))
            let command = standaloneImportReplayArgv(outputDirectory: outputDirectory)
            let inputs = standaloneImportInputRecords(
                inputURL: inputURL,
                parsedVirusHitsURL: parsedVirusHitsURL
            )
            let outputs = [
                ProvenanceRecorder.fileRecord(url: outputURL.standardizedFileURL, format: .json, role: .output),
            ]

            try await CLIProvenanceSupport.recordSingleStepRun(
                name: "lungfish nao-mgs import",
                parameters: standaloneImportExplicitOptions(inputURL: inputURL),
                defaults: standaloneImportDefaultOptions(),
                resolved: standaloneImportResolvedOptions(
                    outputDirectory: outputDirectory,
                    outputURL: outputURL,
                    result: result,
                    filteredHitCount: filteredHitCount,
                    filteredTaxonCount: filteredTaxonCount
                ),
                toolName: "lungfish nao-mgs import",
                toolVersion: WorkflowRun.currentAppVersion,
                command: command,
                inputs: inputs,
                outputs: outputs,
                exitCode: 0,
                wallTime: wallTime,
                stderr: nil,
                status: .completed,
                outputDirectory: outputDirectory
            )
        }

        private func standaloneImportInputRecords(
            inputURL: URL,
            parsedVirusHitsURL: URL
        ) -> [FileRecord] {
            let input = inputURL.standardizedFileURL
            let parsed = parsedVirusHitsURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return [ProvenanceRecorder.fileRecord(url: parsed, format: .text, role: .input)]
            }
            if input == parsed {
                return [ProvenanceRecorder.fileRecord(url: parsed, format: .text, role: .input)]
            }
            return [
                ProvenanceRecorder.fileRecord(url: input, format: .unknown, role: .input),
                ProvenanceRecorder.fileRecord(url: parsed, format: .text, role: .input),
            ]
        }

        private func standaloneImportReplayArgv(outputDirectory: URL) -> [String] {
            var argv = [CLICommandIdentity.executableName, "nao-mgs", "import", inputPath]
            if let sampleName {
                argv += ["--sample-name", sampleName]
            }
            argv += ["--output-dir", outputDirectory.path]
            argv += ["--min-bitscore", String(minBitScore)]
            appendGlobalReplayOptions(to: &argv)
            return argv
        }

        private func appendGlobalReplayOptions(to argv: inout [String]) {
            if globalOptions.outputFormat != .text {
                argv += ["--format", globalOptions.outputFormat.rawValue]
            }
            if globalOptions.verbosity > 0 {
                argv += Array(repeating: "--verbose", count: globalOptions.verbosity)
            }
            if globalOptions.quiet { argv.append("--quiet") }
            if globalOptions.showProgress { argv.append("--progress") }
            if globalOptions.noProgress { argv.append("--no-progress") }
            if globalOptions.debug { argv.append("--debug") }
            if let logFile = globalOptions.logFile { argv += ["--log-file", logFile] }
            if globalOptions.noColor { argv.append("--no-color") }
            if let threads = globalOptions.threads { argv += ["--threads", String(threads)] }
        }

        private func standaloneImportExplicitOptions(inputURL: URL) -> [String: ParameterValue] {
            var options: [String: ParameterValue] = [
                "inputPath": .file(inputURL),
            ]
            if let sampleName {
                options["sampleName"] = .string(sampleName)
            }
            if let outputDir {
                options["outputDir"] = .file(URL(fileURLWithPath: outputDir))
            }
            if minBitScore != 0 {
                options["minBitScore"] = .number(minBitScore)
            }
            if globalOptions.outputFormat != .text { options["consoleFormat"] = .string(globalOptions.outputFormat.rawValue) }
            if globalOptions.verbosity > 0 { options["verbosity"] = .integer(globalOptions.verbosity) }
            if globalOptions.quiet { options["quiet"] = .boolean(true) }
            if globalOptions.showProgress { options["showProgress"] = .boolean(true) }
            if globalOptions.noProgress { options["noProgress"] = .boolean(true) }
            if globalOptions.debug { options["debug"] = .boolean(true) }
            if let logFile = globalOptions.logFile { options["logFile"] = .file(URL(fileURLWithPath: logFile)) }
            if globalOptions.noColor { options["noColor"] = .boolean(true) }
            if let threads = globalOptions.threads { options["threads"] = .integer(threads) }
            return options
        }

        private func standaloneImportDefaultOptions() -> [String: ParameterValue] {
            [
                "sampleName": .null,
                "outputDir": .file(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
                "minBitScore": .number(0),
                "consoleFormat": .string(OutputFormat.text.rawValue),
                "summaryFormat": .string("json"),
                "verbosity": .integer(0),
                "quiet": .boolean(false),
                "showProgress": .boolean(false),
                "noProgress": .boolean(false),
                "debug": .boolean(false),
                "logFile": .null,
                "noColor": .boolean(false),
                "threads": .null,
            ]
        }

        private func standaloneImportResolvedOptions(
            outputDirectory: URL,
            outputURL: URL,
            result: NaoMgsResult,
            filteredHitCount: Int,
            filteredTaxonCount: Int
        ) -> [String: ParameterValue] {
            [
                "sampleName": .string(result.sampleName),
                "outputDir": .file(outputDirectory),
                "outputPath": .file(outputURL),
                "sourceVirusHitsFile": .file(result.virusHitsFile),
                "minBitScore": .number(minBitScore),
                "originalHitCount": .integer(result.totalHitReads),
                "filteredHitCount": .integer(filteredHitCount),
                "originalTaxonCount": .integer(result.taxonSummaries.count),
                "filteredTaxonCount": .integer(filteredTaxonCount),
                "consoleFormat": .string(globalOptions.outputFormat.rawValue),
                "summaryFormat": .string("json"),
                "quiet": .boolean(globalOptions.quiet),
                "verbosity": .integer(globalOptions.verbosity),
                "showProgress": .boolean(globalOptions.showProgress),
                "noProgress": .boolean(globalOptions.noProgress),
                "debug": .boolean(globalOptions.debug),
                "noColor": .boolean(globalOptions.noColor),
                "effectiveThreads": .integer(globalOptions.effectiveThreads),
            ]
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

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let parser = NaoMgsResultParser()

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Determine if input is a directory or file
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir)

            let result: NaoMgsResult
            do {
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
            } catch let error as NaoMgsError {
                print(formatter.error(error.localizedDescription))
                throw naoMgsExitCode(for: error).exitCode
            }

            switch globalOptions.outputFormat {
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

private func naoMgsExitCode(for error: NaoMgsError) -> CLIExitCode {
    switch error {
    case .fileNotFound, .missingResultFiles:
        return .inputError
    case .invalidHeader, .malformedRow:
        return .formatError
    case .samConversionFailed:
        return .workflowError
    }
}
