// FastqMaterializeSubcommand.swift - CLI subcommand to materialize virtual FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct FastqMaterializeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "materialize",
        abstract: "Materialize a virtual FASTQ bundle to a physical FASTQ file",
        discussion: """
            Reads the derived bundle manifest, resolves the root FASTQ, and applies
            payload-specific materialization (subset read IDs, trim positions, or
            copy full payload). Produces a single output FASTQ file.

            Examples:
              lungfish-cli fastq materialize myreads.lungfishfastq -o output.fastq
              lungfish-cli fastq materialize trimmed.lungfishfastq -o reads.fastq --temp-dir /tmp/work
            """
    )

    @Argument(help: "Input .lungfishfastq bundle path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("temp-dir"), help: "Temporary directory for intermediate files")
    var tempDir: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FASTQBundle.isBundleURL(inputURL) else {
            throw CLIError.conversionFailed(reason: "Not a .lungfishfastq bundle: \(input)")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputFileNotFound(path: input)
        }
        try output.validateOutput()

        let tempDirectory: URL
        var ownsTempDirectory = false
        if let tempDir {
            tempDirectory = URL(fileURLWithPath: tempDir)
            try FileManager.default.createDirectory(
                at: tempDirectory, withIntermediateDirectories: true
            )
        } else {
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "lungfish-materialize-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: tempDirectory, withIntermediateDirectories: true
            )
            ownsTempDirectory = true
        }
        defer {
            if ownsTempDirectory {
                try? FileManager.default.removeItem(at: tempDirectory)
            }
        }

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let startedAt = Date()
        let materializedURL = try await materializer.materialize(
            bundleURL: inputURL,
            tempDirectory: tempDirectory,
            progress: { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
        )
        let materializedSequenceFormat = Self.materializedSequenceFormat(
            inputURL: inputURL,
            materializedURL: materializedURL,
            outputURL: URL(fileURLWithPath: output.output)
        )
        let outputFileFormat = Self.provenanceFormat(for: materializedSequenceFormat)

        let outputURL = URL(fileURLWithPath: output.output)
        var gzipResult: FASTQGzipProvenanceResult?
        if output.compress {
            let gzipInputURL: URL
            if materializedURL.standardizedFileURL == outputURL.standardizedFileURL {
                let stagedInputURL = tempDirectory.appendingPathComponent(
                    "materialized-uncompressed-\(UUID().uuidString).\(materializedSequenceFormat.fileExtension)"
                )
                try FileManager.default.copyItem(at: materializedURL, to: stagedInputURL)
                gzipInputURL = stagedInputURL
            } else {
                gzipInputURL = materializedURL
            }
            gzipResult = try gzipCompressFASTQ(
                sourceURL: gzipInputURL,
                outputURL: outputURL,
                failureDescription: "materialized FASTQ"
            )
        } else if materializedURL.standardizedFileURL != outputURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: materializedURL, to: outputURL)
        }
        var cliArguments = ["materialize", inputURL.path, "--output", output.output]
        if let tempDir {
            cliArguments += ["--temp-dir", tempDir]
        }
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let inputRecords = try CLISequenceInputMaterialization.originalInputRecords(for: inputURL)
        var parameters: [String: ParameterValue] = [
            "inputBundle": .file(inputURL),
            "output": .file(outputURL),
            "tempDir": tempDir.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        if let inputPayload = FASTQBundle.resolvePrimarySequenceURL(for: inputURL) {
            parameters["inputPayload"] = .file(inputPayload)
        }
        var extraSteps: [ProvenanceStep] = []
        if let gzipResult {
            let completedAt = Date()
            let gzipInput = try ProvenanceFileDescriptor.file(
                url: gzipResult.inputURL,
                format: outputFileFormat,
                role: .input
            )
            let gzipOutput = try ProvenanceFileDescriptor.file(
                url: gzipResult.outputURL,
                format: outputFileFormat,
                role: .output
            )
            extraSteps.append(
                ProvenanceStep(
                    toolName: gzipResult.command.first ?? "/usr/bin/gzip",
                    toolVersion: "system",
                    argv: gzipResult.command,
                    inputs: [gzipInput],
                    outputs: [gzipOutput],
                    exitStatus: Int(gzipResult.exitCode),
                    wallTimeSeconds: gzipResult.wallTime,
                    stderr: gzipResult.stderr,
                    startedAt: completedAt.addingTimeInterval(-gzipResult.wallTime),
                    completedAt: completedAt
                )
            )
        }
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: CLISequenceInputMaterialization.materializationToolName,
            parameters: parameters,
            defaults: [
                "tempDir": .null,
                "force": .boolean(false),
                "compress": .boolean(false),
                "outputFormat": .string("fastq")
            ],
            resolved: [
                "outputFormat": .string(materializedSequenceFormat.rawValue)
            ],
            toolName: CLISequenceInputMaterialization.materializationToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            extraSteps: extraSteps,
            inputs: inputRecords,
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: outputFileFormat, role: .output)],
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent()
        )
        FileHandle.standardError.write(Data("Materialized to \(output.output)\n".utf8))
    }

    private static func materializedSequenceFormat(
        inputURL: URL,
        materializedURL: URL,
        outputURL: URL
    ) -> SequenceFormat {
        if let manifest = FASTQBundle.loadDerivedManifest(in: inputURL),
           let sequenceFormat = manifest.sequenceFormat {
            return sequenceFormat
        }
        if let format = SequenceFormat.from(url: materializedURL) {
            return format
        }
        if let format = SequenceFormat.from(url: outputURL) {
            return format
        }
        if let inputPayload = FASTQBundle.resolvePrimarySequenceURL(for: inputURL),
           let format = SequenceFormat.from(url: inputPayload) {
            return format
        }
        return .fastq
    }

    private static func provenanceFormat(for sequenceFormat: SequenceFormat) -> FileFormat {
        switch sequenceFormat {
        case .fasta:
            return .fasta
        case .fastq:
            return .fastq
        }
    }
}
