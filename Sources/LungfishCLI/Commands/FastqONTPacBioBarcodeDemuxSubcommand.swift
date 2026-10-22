// FastqONTPacBioBarcodeDemuxSubcommand.swift - Demultiplex full-length MHC ONT amplicons with PacBio barcode pairs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - ONT PacBio Barcode Pair Demultiplexing

struct FastqONTPacBioBarcodeDemuxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ont-pacbio-barcode-demux",
        abstract: "Demultiplex full-length MHC ONT amplicons with PacBio barcode pairs",
        discussion: """
            Validates a PacBio barcode-pair sample sheet, resolves built-in bc*
            barcode IDs, and writes one materialized .lungfishfastq bundle per
            sample. Barcode definitions must contain sample_id, barcode_1, and
            barcode_2 columns, or headerless rows in that order.

            Repeated sample IDs are numbered _1, _2, and so on.
            Unique sample IDs remain unchanged. The thread count (--threads) is a compatibility option for legacy chunked demux paths and defaults to 1.
            """
    )

    @Argument(help: "Input ONT FASTQ file, barcode directory, run directory, or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file with sample_id, barcode_1, and barcode_2 columns, or headerless rows in that order")
    var barcodes: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory for per-sample .lungfishfastq bundles")
    var output: String

    @OptionGroup var globalOptions: GlobalOptions
    var threads: Int { globalOptions.threads ?? 1 }

    // Keep "(default: active cores)" in this help. Golden rule H2 (scripts/golden/normalize.py) masks the
    // core count that ArgumentParser prints after those words, and only after them.
    @Option(name: .customLong("chunk-jobs"), help: "Compatibility option for legacy chunked demux paths (default: active cores)")
    var chunkJobs: Int = ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs

    @Option(name: .customLong("max-reads-per-slice"), help: "Compatibility option for legacy chunked demux paths; 0 disables sub-slicing")
    var maxReadsPerSlice: Int = 100_000

    @Option(name: .customLong("max-bytes-per-cutadapt"), help: "Compatibility option for legacy chunked demux paths")
    var maxBytesPerCutadapt: Int64 = 512 * 1024 * 1024

    @Flag(name: .customLong("force"), help: "Replace an existing output directory")
    var force: Bool = false

    func run() async throws {
        guard threads > 0 else {
            throw ValidationError("--threads must be positive.")
        }
        guard chunkJobs > 0 else {
            throw ValidationError("--chunk-jobs must be positive.")
        }
        guard maxReadsPerSlice >= 0 else {
            throw ValidationError("--max-reads-per-slice must be non-negative.")
        }
        guard maxBytesPerCutadapt > 0 else {
            throw ValidationError("--max-bytes-per-cutadapt must be positive.")
        }

        try await execute(emit: printStatusLine)
    }

    /// Demultiplexes the reads and writes the events of the run through `emit`, one line each. The
    /// events go to standard error until 2.8, because the FASTQ operation family reads that stream,
    /// and the command prints its result document on standard output, as it always did. A throw
    /// after the start ends the stream with one `failed` line (plan decision S9).
    func execute(emit: @escaping (String) -> Void) async throws {
        let events = CLIEventEmitter(enabled: true, emit: emit)
        events.emitStart("Starting PacBio barcode demultiplexing.")
        do {
            try await demultiplex(reporting: events)
        } catch {
            events.emitFailed(CLIFailureWords.describe(error))
            throw error
        }
    }

    private func demultiplex(reporting events: CLIEventEmitter) async throws {
        let inputURL = URL(fileURLWithPath: input)
        let barcodeURL = URL(fileURLWithPath: barcodes)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let runClock = ProvenanceRunClock()
        let request = ONTPacBioBarcodeDemuxMaterializationRequest(
            inputURL: inputURL,
            barcodeDefinitionsURL: barcodeURL,
            outputDirectory: outputURL,
            force: force,
            threads: threads,
            chunkJobs: chunkJobs,
            maxReadsPerSlice: maxReadsPerSlice,
            maxInputBytesPerCutadapt: maxBytesPerCutadapt
        )
        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(request) { fraction, message in
            events.emitProgress(fraction, message: message)
        }

        var cliArguments = [
            "ont-pacbio-barcode-demux",
            inputURL.path,
            "--barcodes", barcodeURL.path,
            "--output", outputURL.path,
            "--threads", String(threads),
            "--chunk-jobs", String(chunkJobs),
            "--max-reads-per-slice", String(maxReadsPerSlice),
            "--max-bytes-per-cutadapt", String(maxBytesPerCutadapt),
        ]
        if force {
            cliArguments.append("--force")
        }

        let resolvedInputFASTQs = ONTBarcodeDemuxGenotypingPipeline.provenanceInputURLs(for: inputURL)
        let outputPayloads = result.outputBundleURLs
            .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let inputs = resolvedInputFASTQs.map {
            ProvenanceRecorder.fileOrDirectoryRecord(url: $0, format: .fastq, role: .input)
        } + [
            ProvenanceRecorder.fileRecord(url: barcodeURL, format: .text, role: .input),
        ]
        let outputs = Self.provenanceOutputRecords(
            outputDirectory: result.outputDirectory,
            manifestURL: result.manifestURL,
            outputBundleURLs: result.outputBundleURLs,
            outputPayloads: outputPayloads
        )

        let cutadaptArgv = result.cutadaptRuns
            .map { $0.argv.joined(separator: " ") }
            .joined(separator: "\n")
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq ont-pacbio-barcode-demux",
            parameters: [
                "input": .file(inputURL),
                "barcodes": .file(barcodeURL),
                "output": .file(outputURL),
                "threads": .integer(threads),
                "chunkJobs": .integer(chunkJobs),
                "effectiveChunkJobs": .integer(result.chunkJobs),
                "force": .boolean(force),
                "maxReadsPerSlice": .integer(maxReadsPerSlice),
                "maxBytesPerCutadapt": .integer(Int(maxBytesPerCutadapt)),
                "inputChunkCount": .integer(result.inputChunkCount),
                "executedCutadaptChunkCount": .integer(result.executedCutadaptChunkCount),
                "inputReadCount": .integer(result.inputReadCount),
                "assignedReadCount": .integer(result.assignedReadCount),
                "unassignedReadCount": .integer(result.unassignedReadCount),
                "payloadRepresentation": .string("gzip-compressed full demultiplexed FASTQ"),
                "cutadaptCommands": .string(cutadaptArgv),
                // The demultiplexed reads keep every score (lane C2-ONTBIN).
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
            ],
            defaults: [
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                "threads": .integer(1),
                "chunkJobs": .integer(ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs),
                "force": .boolean(false),
                "maxReadsPerSlice": .integer(100_000),
                "maxBytesPerCutadapt": .integer(512 * 1024 * 1024),
                "payloadRepresentation": .string("gzip-compressed full demultiplexed FASTQ"),
            ],
            toolName: "lungfish fastq ont-pacbio-barcode-demux",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: result.outputDirectory
        )

        let payload: [String: Any] = [
            "outputDirectory": result.outputDirectory.path,
            "manifest": result.manifestURL.path,
            "outputBundles": result.outputBundleURLs.map(\.path),
            "inputChunkCount": result.inputChunkCount,
            "executedCutadaptChunkCount": result.executedCutadaptChunkCount,
            "chunkJobs": result.chunkJobs,
            "inputReadCount": result.inputReadCount,
            "assignedReadCount": result.assignedReadCount,
            "unassignedReadCount": result.unassignedReadCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        events.emitComplete(
            outputs: [result.outputDirectory.path, result.manifestURL.path] + result.outputBundleURLs.map(\.path),
            message: "\(result.outputBundleURLs.count) sample bundle(s), \(result.assignedReadCount) of \(result.inputReadCount) reads assigned"
        )
    }

    static func provenanceOutputRecords(
        outputDirectory: URL,
        manifestURL: URL,
        outputBundleURLs: [URL],
        outputPayloads: [URL]
    ) -> [FileRecord] {
        [
            ProvenanceRecorder.fileOrDirectoryRecord(url: outputDirectory, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output),
        ] + outputBundleURLs.map {
            ProvenanceRecorder.fileOrDirectoryRecord(url: $0, format: .unknown, role: .output)
        } + outputPayloads.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
        }
    }
}
