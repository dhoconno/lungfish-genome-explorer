// FastqONTFluidigmSamplesSubcommand.swift - Materialize counted per-sample ONT Fluidigm amplicon FASTQs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - ONT Fluidigm Sample Materialization

struct FastqONTFluidigmSamplesSubcommand: AsyncParsableCommand {
    private static let progressEmitLock = NSLock()

    static let configuration = CommandConfiguration(
        commandName: "ont-fluidigm-samples",
        abstract: "Materialize counted per-sample ONT Fluidigm amplicon FASTQs",
        discussion: """
            Assigns ONT reads to samples with the same exact Fluidigm barcode matching
            used by amplicon genotyping, extracts the CS1-CS2 amplicon insert, then
            writes one physical .lungfishfastq bundle per sample containing unique
            insert exemplars. Payloads are gzip-compressed and duplicate support is
            encoded in FASTQ headers as size=N. The thread count (--threads) is recorded in provenance, is reserved for parallel materialization, and defaults to 1.
            """
    )

    @Argument(help: "Input FASTQ file, directory, or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("barcodes"), help: "CSV/TSV file with sample and Fluidigm barcode sequence columns")
    var barcodes: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output directory for per-sample .lungfishfastq bundles")
    var output: String

    @OptionGroup var globalOptions: GlobalOptions
    var threads: Int { globalOptions.threads ?? 1 }

    @Option(name: .customLong("primer-mismatches"), help: "Maximum mismatches allowed when detecting CS1/CS2 primer boundaries (default: 2)")
    var primerMismatches: Int = 2

    @Option(name: .customLong("minimum-insert-length"), help: "Minimum CS1-CS2 insert length to retain (default: 20)")
    var minimumInsertLength: Int = 20

    @Flag(
        name: .customLong("canonicalize-reverse-complements"),
        inversion: .prefixedNo,
        help: "Canonicalize exact reverse-complement insert duplicates after orienting CS1-CS2 reads (default: disabled)"
    )
    var canonicalizeReverseComplements: Bool = false

    @Flag(name: .customLong("force"), help: "Replace an existing output directory")
    var force: Bool = false

    func run() async throws {
        guard threads > 0 else {
            throw ValidationError("--threads must be positive.")
        }
        guard primerMismatches >= 0 else {
            throw ValidationError("--primer-mismatches must be non-negative.")
        }
        guard minimumInsertLength > 0 else {
            throw ValidationError("--minimum-insert-length must be positive.")
        }

        let inputURL = URL(fileURLWithPath: input)
        let barcodeURL = URL(fileURLWithPath: barcodes)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let startedAt = Date()
        let request = ONTFluidigmAmpliconMaterializationRequest(
            inputURL: inputURL,
            barcodeDefinitionsURL: barcodeURL,
            outputDirectory: outputURL,
            primerMismatches: primerMismatches,
            minimumInsertLength: minimumInsertLength,
            canonicalizeReverseComplements: canonicalizeReverseComplements,
            force: force
        )
        let result = try await ONTFluidigmAmpliconMaterializer().run(request) { fraction, message in
            emitProgress(fraction, message)
        }

        var cliArguments = [
            "ont-fluidigm-samples",
            inputURL.path,
            "--barcodes", barcodeURL.path,
            "--output", outputURL.path,
            "--primer-mismatches", String(primerMismatches),
            "--minimum-insert-length", String(minimumInsertLength),
        ]
        if threads != 1 {
            cliArguments += ["--threads", String(threads)]
        }
        if !canonicalizeReverseComplements {
            cliArguments.append("--no-canonicalize-reverse-complements")
        }
        if force {
            cliArguments.append("--force")
        }

        let outputPayloads = result.outputBundleURLs
            .compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        let outputs = [
            directoryOutputRecord(result.outputDirectory),
            ProvenanceRecorder.fileRecord(url: result.manifestURL, format: .json, role: .output),
        ] + result.outputBundleURLs.map {
            directoryOutputRecord($0)
        } + outputPayloads.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
        }
        let inputRecords = [
            ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input),
            ProvenanceRecorder.fileRecord(url: barcodeURL, format: .text, role: .input),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq ont-fluidigm-samples",
            parameters: [
                "input": .file(inputURL),
                "barcodes": .file(barcodeURL),
                "output": .file(outputURL),
                "threads": .integer(threads),
                "force": .boolean(force),
                "forwardPrimer": .string(request.forwardPrimer),
                "reversePrimer": .string(request.reversePrimer),
                "primerMismatches": .integer(primerMismatches),
                "minimumInsertLength": .integer(minimumInsertLength),
                "canonicalizeReverseComplements": .boolean(canonicalizeReverseComplements),
                "payloadRepresentation": .string("deduplicated gzip-compressed CS1-CS2 insert FASTQ"),
                "duplicateCountEncoding": .string("size=N"),
                "inputReadCount": .integer(result.inputReadCount),
                "assignedReadCount": .integer(result.assignedReadCount),
                "extractedReadCount": .integer(result.extractedReadCount),
                "uniqueSequenceCount": .integer(result.uniqueSequenceCount),
                "unassignedReadCount": .integer(result.unassignedReadCount),
                "unextractedReadCount": .integer(result.unextractedReadCount),
            ],
            defaults: [
                "threads": .integer(1),
                "force": .boolean(false),
                "forwardPrimer": .string(ONTFluidigmAmpliconMaterializer.defaultForwardPrimer),
                "reversePrimer": .string(ONTFluidigmAmpliconMaterializer.defaultReversePrimer),
                "primerMismatches": .integer(2),
                "minimumInsertLength": .integer(20),
                "canonicalizeReverseComplements": .boolean(false),
                "payloadRepresentation": .string("deduplicated gzip-compressed CS1-CS2 insert FASTQ"),
                "duplicateCountEncoding": .string("size=N"),
            ],
            toolName: "lungfish fastq ont-fluidigm-samples",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            inputs: inputRecords,
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
            "inputReadCount": result.inputReadCount,
            "assignedReadCount": result.assignedReadCount,
            "extractedReadCount": result.extractedReadCount,
            "uniqueSequenceCount": result.uniqueSequenceCount,
            "unassignedReadCount": result.unassignedReadCount,
            "unextractedReadCount": result.unextractedReadCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func directoryOutputRecord(_ url: URL) -> FileRecord {
        FileRecord(
            path: url.standardizedFileURL.path,
            sha256: nil,
            sizeBytes: nil,
            format: .unknown,
            role: .output
        )
    }

    private func emitProgress(_ fraction: Double, _ message: String) {
        let payload: [String: Any] = [
            "event": "progress",
            "operation": "ontFluidigmSamples",
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
}
