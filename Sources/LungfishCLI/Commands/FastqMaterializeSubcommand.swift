// FastqMaterializeSubcommand.swift - CLI subcommand to materialize virtual FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
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
              lungfish fastq materialize myreads.lungfishfastq -o output.fastq
              lungfish fastq materialize trimmed.lungfishfastq -o reads.fastq --temp-dir /tmp/work
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

        let outputURL = URL(fileURLWithPath: output.output)
        if materializedURL != outputURL {
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
        let inputRecords = FASTQBundle.resolvePrimarySequenceURL(for: inputURL).map {
            [ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)]
        } ?? []
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
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq materialize",
            parameters: parameters,
            defaults: [
                "tempDir": .null,
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            toolName: "lungfish fastq materialize",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish", "fastq"] + cliArguments,
            stepCommand: ["lungfish", "fastq"] + cliArguments,
            inputs: inputRecords,
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent()
        )
        FileHandle.standardError.write(Data("Materialized to \(output.output)\n".utf8))
    }
}
