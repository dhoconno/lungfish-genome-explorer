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
    private static let progressEmitLock = NSLock()

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

    @Option(name: .customLong("chunk-jobs"), help: "Compatibility option for legacy chunked demux paths (default: active cores)")
    var chunkJobs: Int = ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs

    @Option(name: .customLong("max-reads-per-slice"), help: "Compatibility option for legacy chunked demux paths; 0 disables sub-slicing (default: 100000)")
    var maxReadsPerSlice: Int = 100_000

    @Option(name: .customLong("max-bytes-per-cutadapt"), help: "Compatibility option for legacy chunked demux paths (default: 536870912)")
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

        let inputURL = URL(fileURLWithPath: input)
        let barcodeURL = URL(fileURLWithPath: barcodes)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let startedAt = Date()
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
            emitProgress(fraction, message)
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

        let resolvedInputFASTQs = (try? ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: inputURL)) ?? [inputURL]
        let outputPayloads = result.outputBundleURLs
            .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let inputs = resolvedInputFASTQs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
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
            ],
            defaults: [
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
            wallTime: Date().timeIntervalSince(startedAt),
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
    }

    private func emitProgress(_ fraction: Double, _ message: String) {
        let payload: [String: Any] = [
            "event": "progress",
            "operation": "ontPacBioBarcodeDemux",
            "progress": max(0, min(1, fraction)),
            "message": message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(Data("\n".utf8))
        Self.progressEmitLock.lock()
        FileHandle.standardError.write(line)
        Self.progressEmitLock.unlock()
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
