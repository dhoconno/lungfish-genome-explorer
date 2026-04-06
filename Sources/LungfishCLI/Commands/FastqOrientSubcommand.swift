// FastqOrientSubcommand.swift - CLI subcommand to orient reads against a reference sequence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqOrientSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orient",
        abstract: "Orient reads against a reference sequence"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("reference"), help: "Reference FASTA file path")
    var reference: String

    @Option(name: .customLong("word-length"), help: "Word length for orientation matching (default: 12)")
    var wordLength: Int = 12

    @Option(name: .customLong("db-mask"), help: "Database masking method (default: dust)")
    var dbMask: String = "dust"

    func run() async throws {
        let inputURL = try validateInput(input)
        let referenceURL = try validateInput(reference)
        try output.validateOutput()

        let tabbedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-orient-\(UUID().uuidString).tsv")
        defer {
            try? FileManager.default.removeItem(at: tabbedOutput)
        }

        let args: [String] = [
            "--orient", inputURL.path,
            "--db", referenceURL.path,
            "--fastqout", output.output,
            "--tabbedout", tabbedOutput.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", dbMask,
            "--threads", "0",
        ]

        let runner = NativeToolRunner.shared
        let result = try await runner.run(.vsearch, arguments: args, environment: [:], timeout: 1800)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }
    }
}
