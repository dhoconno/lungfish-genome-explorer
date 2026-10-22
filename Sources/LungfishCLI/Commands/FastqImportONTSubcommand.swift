// FastqImportONTSubcommand.swift - Import ONT output directory into per-barcode bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Import ONT

struct FastqImportONTSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-ont",
        abstract: "Import ONT output directory into per-barcode bundles",
        discussion: """
            Imports Oxford Nanopore sequencing output directories into per-barcode
            .lungfishfastq bundles. Concatenates chunked FASTQ files within each
            barcode directory and generates a demultiplex manifest.

            Accepts either a fastq_pass/ parent directory or a single barcode
            directory (e.g., fastq_pass/barcode01/).

            Examples:
              lungfish-cli fastq import-ont fastq_pass/ -o imported/
              lungfish-cli fastq import-ont fastq_pass/barcode13/ -o imported/
              lungfish-cli fastq import-ont fastq_pass/ -o imported/ --include-unclassified
            """
    )

    @Argument(help: "ONT output directory (fastq_pass/ or single barcode directory)")
    var input: String

    @Option(name: [.customLong("output"), .customShort("o")],
            help: "Output directory for .lungfishfastq bundles")
    var output: String

    @Flag(name: .customLong("include-unclassified"),
          help: "Include unclassified reads (default: skip)")
    var includeUnclassified: Bool = false

    @Option(name: .customLong("concurrency"),
            help: "Max concurrent barcode imports")
    var concurrency: Int = 4

    @Option(name: .customLong("storage-mode"),
            help: "How to store ONT chunks inside each bundle")
    var storageMode: ONTImportStorageMode = .chunked

    @Flag(name: .customLong("optimize-storage"),
          help: "Run clumpify on flattened per-barcode FASTQ payloads to improve compression")
    var optimizeStorage: Bool = false

    @Option(name: .customLong("quality-binning"),
            help: "Quality binning for --optimize-storage: illumina4 (7 quality levels, the default), eightLevel (~21 quality levels) or none. Binning is lossy. Pass none to keep every score.")
    var qualityBinning: QualityBinningScheme = QualityBinningScheme.importDefault

    @OptionGroup var globalOptions: GlobalOptions

    /// The import itself. `run()` and `execute(emit:cancelRequested:)` in
    /// FastqImportONTSubcommand+Events.swift put SIGTERM and the event
    /// stream around it, so a failure here ends the stream in one `failed` event.
    func importONT(events: CLIEventEmitter) async throws {
        guard concurrency >= 1 else {
            throw ValidationError("Concurrency must be at least 1 (got \(concurrency))")
        }
        if optimizeStorage && storageMode != .flattened {
            throw ValidationError("--optimize-storage requires --storage-mode flattened")
        }

        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        let cliArguments = cliArguments(inputURL: inputURL, outputURL: outputURL)
        let argv = [CLICommandIdentity.executableName, "fastq"] + cliArguments
        if FASTQBundle.isBundleURL(inputURL) {
            let destinationBundleURL = FASTQBundleCopyImportWorkflow.resolvedDestinationBundleURL(
                outputURL: outputURL,
                sourceBundleURL: inputURL
            )
            FileHandle.standardError.write(Data("Detected existing FASTQ bundle; copying atomically\n".utf8))
            let workflow = FASTQBundleCopyImportWorkflow()
            let result = try workflow.importBundle(
                sourceBundleURL: inputURL,
                outputURL: outputURL,
                context: FASTQBundleCopyImportWorkflow.CommandContext(
                    workflowName: "lungfish fastq import-ont",
                    workflowVersion: LungfishAppVersion.short,
                    toolName: "lungfish fastq import-ont",
                    toolVersion: LungfishAppVersion.short,
                    argv: argv,
                    durableReplayArgv: argv,
                    reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                    explicitOptions: [
                        "input": .file(inputURL),
                        "output": .file(outputURL),
                        "includeUnclassified": .boolean(includeUnclassified),
                        "concurrency": .integer(concurrency),
                        "storageMode": .string(storageMode.rawValue),
                        "optimizeStorage": .boolean(optimizeStorage),
                        "qualityBinning": .string(qualityBinning.rawValue)
                    ],
                    defaultOptions: [
                        "includeUnclassified": .boolean(false),
                        "concurrency": .integer(4),
                        "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                        "optimizeStorage": .boolean(false),
                        "qualityBinning": .string(QualityBinningScheme.importDefault.rawValue),
                        "sourceKind": .string("raw-ont-directory")
                    ],
                    resolvedOptions: [
                        "input": .file(inputURL),
                        "output": .file(outputURL),
                        "destinationBundle": .file(destinationBundleURL),
                        "includeUnclassified": .boolean(includeUnclassified),
                        "concurrency": .integer(concurrency),
                        "storageMode": .string(storageMode.rawValue),
                        "optimizeStorage": .boolean(optimizeStorage),
                        "qualityBinning": .string(qualityBinning.rawValue),
                        "sourceKind": .string("existing-fastq-bundle"),
                        "copyMode": .string("atomic-bundle-copy"),
                        "caller": .string("cli")
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: LungfishAppVersion.short)
                )
            )

            FileHandle.standardError.write(Data("\n--- ONT Import Summary ---\n".utf8))
            FileHandle.standardError.write(Data("Source: existing FASTQ bundle\n".utf8))
            FileHandle.standardError.write(Data("Bundle: \(result.bundleURL.lastPathComponent)\n".utf8))
            FileHandle.standardError.write(Data("Files copied: \(result.copiedFileCount)\n".utf8))
            FileHandle.standardError.write(Data("Bytes copied: \(result.totalCopiedBytes)\n".utf8))
            FileHandle.standardError.write(Data("Output: \(result.bundleURL.path)\n".utf8))
            FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))
            events.emitComplete(
                outputs: [result.bundleURL.path],
                message: "Copied \(result.bundleURL.lastPathComponent)"
            )
            return
        }

        let importer = ONTDirectoryImporter()

        // Detect layout first
        let layout = try importer.detectLayout(at: inputURL)
        FileHandle.standardError.write(Data("Detected \(layout.barcodeDirectories.count) barcode directories, \(layout.totalChunkCount) chunks\n".utf8))

        let config = ONTImportConfig(
            sourceDirectory: inputURL,
            outputDirectory: outputURL,
            maxConcurrentBarcodes: concurrency,
            includeUnclassified: includeUnclassified,
            storageMode: storageMode
        )

        let workflow = ONTImportWorkflow()
        // The stage words are the workflow's own. With events on, each one is a progress line, and the
        // percentage line on standard error stays out, since the window's log would hold it twice.
        let eventsOn = globalOptions.outputFormat == .json
        let workflowResult = try await workflow.importDirectory(
            config: config,
            context: ONTImportWorkflow.CommandContext(
                caller: .cli,
                workflowName: "lungfish fastq import-ont",
                workflowVersion: LungfishAppVersion.short,
                toolName: "lungfish fastq import-ont",
                toolVersion: LungfishAppVersion.short,
                argv: argv,
                durableReplayArgv: argv,
                reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                explicitOptions: [
                    "input": .file(inputURL),
                    "output": .file(outputURL),
                    "includeUnclassified": .boolean(includeUnclassified),
                    "concurrency": .integer(concurrency),
                    "storageMode": .string(storageMode.rawValue),
                    "optimizeStorage": .boolean(optimizeStorage),
                    "qualityBinning": .string(qualityBinning.rawValue)
                ],
                defaultOptions: [
                    "includeUnclassified": .boolean(false),
                    "concurrency": .integer(4),
                    "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                    "optimizeStorage": .boolean(false),
                    "qualityBinning": .string(QualityBinningScheme.importDefault.rawValue),
                    "useVirtualConcatenation": .boolean(true)
                ],
                resolvedOptions: [
                    "input": .file(inputURL),
                    "output": .file(outputURL),
                    "includeUnclassified": .boolean(includeUnclassified),
                    "concurrency": .integer(concurrency),
                    "storageMode": .string(storageMode.rawValue),
                    "optimizeStorage": .boolean(optimizeStorage),
                    "qualityBinning": .string(qualityBinning.rawValue),
                    "useVirtualConcatenation": .boolean(storageMode.usesVirtualConcatenation),
                    "caller": .string("cli"),
                    "barcodeDirectoryCount": .integer(layout.barcodeDirectories.count),
                    "chunkCount": .integer(layout.totalChunkCount)
                ],
                runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: LungfishAppVersion.short)
            ),
            optimization: ONTImportWorkflow.OptimizationConfig(
                optimizeStorage: optimizeStorage,
                qualityBinning: qualityBinning,
                threads: concurrency
            )
        ) { fraction, message in
            events.emitProgress(fraction, message: message)
            if !eventsOn {
                FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
            }
        }
        let result = workflowResult.importResult

        // Summary output
        FileHandle.standardError.write(Data("\n--- ONT Import Summary ---\n".utf8))
        if let flowCell = result.flowCellID {
            FileHandle.standardError.write(Data("Flow Cell: \(flowCell)\n".utf8))
        }
        if let sample = result.sampleID {
            FileHandle.standardError.write(Data("Sample: \(sample)\n".utf8))
        }
        if let model = result.basecallModel {
            FileHandle.standardError.write(Data("Basecall Model: \(model)\n".utf8))
        }
        FileHandle.standardError.write(Data("Barcodes: \(result.bundleURLs.count)\n".utf8))
        FileHandle.standardError.write(Data("Total reads: \(result.totalReadCount)\n".utf8))
        FileHandle.standardError.write(Data("Output: \(output)\n".utf8))
        FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))

        for barcode in result.manifest.barcodes {
            FileHandle.standardError.write(Data("  \(barcode.barcodeID): \(barcode.readCount) reads\n".utf8))
        }
        // The bundles in barcode order, so the window opens the first, with the words the row ended on.
        events.emitComplete(
            outputs: result.bundleURLs.map(\.path),
            message: "\(result.bundleURLs.count) barcode bundles, \(result.totalReadCount) reads"
        )
    }

    private func cliArguments(inputURL: URL, outputURL: URL) -> [String] {
        var cliArguments = ["import-ont", inputURL.path, "--output", outputURL.path]
        if includeUnclassified {
            cliArguments.append("--include-unclassified")
        }
        if concurrency != 4 {
            cliArguments += ["--concurrency", String(concurrency)]
        }
        if storageMode != .chunked {
            cliArguments += ["--storage-mode", storageMode.rawValue]
        }
        if optimizeStorage {
            cliArguments.append("--optimize-storage")
        }
        // The binning is always named, so the record replays the same whatever the default is (lane C2-BINNING).
        cliArguments += ["--quality-binning", qualityBinning.rawValue]
        // The window launches the leaf with this option and its row records the argv it ran, so the record
        // names the same command (CLI-EQUIVALENCE, same provenance).
        if globalOptions.outputFormat == .json {
            cliArguments += ["--format", "json"]
        }
        return cliArguments
    }
}
