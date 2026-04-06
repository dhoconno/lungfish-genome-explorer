// FastqSequenceFilterSubcommand.swift - CLI subcommand to filter reads by sequence presence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqSequenceFilterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence-filter",
        abstract: "Filter reads by sequence presence (adapter/barcode matching)"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("sequence"), help: "Literal sequence to match against reads")
    var sequence: String?

    @Option(name: .customLong("fasta-path"), help: "Path to FASTA file containing sequences to match")
    var fastaPath: String?

    @Option(name: .customLong("search-end"), help: "Which end to search: \"left\", \"right\", or \"both\" (default: both)")
    var searchEnd: String = "both"

    @Option(name: .customLong("min-overlap"), help: "Minimum overlap length (default: 8)")
    var minOverlap: Int = 8

    @Option(name: .customLong("error-rate"), help: "Allowed error rate as fraction (default: 0.1)")
    var errorRate: Double = 0.1

    @Flag(name: .customLong("keep-matched"), help: "Keep matched reads instead of discarding them")
    var keepMatched: Bool = false

    @Flag(name: .customLong("search-rc"), help: "Also search the reverse complement of the sequence")
    var searchReverseComplement: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        guard sequence != nil || fastaPath != nil else {
            throw CLIError.conversionFailed(reason: "Either --sequence or --fasta-path must be specified")
        }

        var args: [String] = ["in=\(inputURL.path)"]

        if keepMatched {
            args.append("outm=\(output.output)")
        } else {
            args.append("out=\(output.output)")
        }

        if let sequence {
            args.append("literal=\(sequence)")
        } else if let fastaPath {
            let fastaURL = try validateInput(fastaPath)
            args.append("ref=\(fastaURL.path)")
        }

        args.append("k=\(minOverlap)")
        args.append("hdist=0")
        args.append("edist=\(Int(errorRate * Double(minOverlap)))")

        if searchReverseComplement {
            args.append("rcomp=t")
        }

        switch searchEnd {
        case "left":
            args.append("restrictleft=\(minOverlap * 3)")
        case "right":
            args.append("restrictright=\(minOverlap * 3)")
        default:
            break
        }

        let runner = NativeToolRunner.shared
        let env = await bbToolsEnvironment(runner: runner)
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }
    }
}
