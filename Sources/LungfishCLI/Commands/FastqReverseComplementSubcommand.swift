// FastqReverseComplementSubcommand.swift - Reverse-complement FASTQ reads and reverse their quality scores
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Reverse Complement

struct FastqReverseComplementSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reverse-complement",
        abstract: "Reverse-complement FASTQ reads and reverse their quality scores"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "reverse-complement", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let outputURL = URL(fileURLWithPath: output.output)
        let runClock = ProvenanceRunClock()

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputURL)
        do {
            try writer.open()
            for try await record in reader.records(from: inputURL) {
                try writer.write(record.reverseComplement())
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        var cliArguments = ["reverse-complement", resolvedInput.originalURL.path, "-o", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQSwiftToolProvenance(
            workflowName: "lungfish fastq reverse-complement",
            cliArguments: cliArguments,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            runClock: runClock
        )
        FileHandle.standardError.write(Data("Reverse-complemented reads written to \(output.output)\n".utf8))
    }
}
