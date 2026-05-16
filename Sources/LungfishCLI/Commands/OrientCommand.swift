// OrientCommand.swift - CLI command for orienting FASTQ reads
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Orient FASTQ reads relative to a reference sequence.
///
/// Uses vsearch to determine the strand orientation of each read relative
/// to a reference FASTA. Reads in reverse complement orientation are flipped
/// to match the reference.
///
/// ## Examples
///
/// ```
/// # Orient reads against a reference
/// lungfish orient reads.fastq --reference ref.fasta
///
/// # Orient with custom word length and no masking
/// lungfish orient reads.fastq --reference ref.fasta --word-length 15 --mask none
///
/// # Orient and save unoriented reads
/// lungfish orient reads.fastq --reference ref.fasta --save-unoriented
/// ```
struct OrientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orient",
        abstract: "Orient FASTQ reads relative to a reference sequence",
        discussion: """
            Determines the strand orientation of each read relative to a
            reference FASTA using vsearch. Reads on the minus strand are
            reverse-complemented to match the reference orientation. Essential
            for amplicon data with known primer orientation.
            """
    )

    // MARK: - Arguments

    @Argument(help: "Input FASTQ file")
    var fastqFile: String

    @Option(name: .customLong("reference"), help: "Reference FASTA file")
    var reference: String

    @Option(name: .customLong("word-length"), help: "K-mer word length for matching (3-15, default: 12)")
    var wordLength: Int = 12

    @Option(name: .customLong("mask"), help: "Low-complexity masking mode: dust, none (default: dust)")
    var mask: String = "dust"

    @Flag(name: .customLong("save-unoriented"), help: "Save unoriented reads to a separate file")
    var saveUnoriented: Bool = false

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional vsearch arguments passed verbatim"
    )
    var extraArgs: String = ""

    @Option(name: [.customLong("output-dir"), .customShort("o")], help: "Output directory (default: current directory)")
    var outputDir: String?

    @OptionGroup var globalOptions: GlobalOptions

    // MARK: - Execution

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Resolve input files
        let inputURL = URL(fileURLWithPath: fastqFile)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print(formatter.error("Input file not found: \(inputURL.path)"))
            throw ExitCode.failure
        }

        let referenceURL = URL(fileURLWithPath: reference)
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            print(formatter.error("Reference file not found: \(referenceURL.path)"))
            throw ExitCode.failure
        }

        // Validate parameters
        guard (3...15).contains(wordLength) else {
            print(formatter.error("Word length must be between 3 and 15"))
            throw ExitCode.failure
        }
        guard ["dust", "none"].contains(mask) else {
            print(formatter.error("Mask must be 'dust' or 'none'"))
            throw ExitCode.failure
        }

        let effectiveThreads = globalOptions.threads ?? 0
        let config = OrientConfig(
            inputURL: inputURL,
            referenceURL: referenceURL,
            wordLength: wordLength,
            dbMask: mask,
            qMask: mask,
            saveUnoriented: saveUnoriented,
            threads: effectiveThreads,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )

        // Print configuration
        print(formatter.header("Orient Reads"))
        print("")
        print(formatter.keyValueTable([
            ("Input", inputURL.lastPathComponent),
            ("Reference", referenceURL.lastPathComponent),
            ("Word length", "\(wordLength)"),
            ("Mask", mask),
            ("Save unoriented", saveUnoriented ? "yes" : "no"),
            ("Threads", effectiveThreads == 0 ? "all cores" : "\(effectiveThreads)"),
        ]))
        print("")

        // Run pipeline
        let pipeline = OrientPipeline()
        let orientOptions = orientProvenanceOptions(
            inputURL: inputURL,
            referenceURL: referenceURL,
            effectiveThreads: effectiveThreads
        )
        let result = try await pipeline.run(
            config: config,
            provenanceContext: OrientProvenanceContext(
                workflowName: "lungfish orient",
                argv: CommandLine.arguments,
                options: orientOptions
            )
        ) { fraction, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }

        // Clear progress line
        print("")
        print("")

        // Print results
        let total = result.totalCount
        let fwdPct = total > 0 ? String(format: "%.1f%%", Double(result.forwardCount) / Double(total) * 100) : "0%"
        let rcPct = total > 0 ? String(format: "%.1f%%", Double(result.reverseComplementedCount) / Double(total) * 100) : "0%"
        let unmPct = total > 0 ? String(format: "%.1f%%", Double(result.unmatchedCount) / Double(total) * 100) : "0%"

        print(formatter.header("Results"))
        print("")
        print(formatter.keyValueTable([
            ("Total reads", "\(total)"),
            ("Forward (unchanged)", "\(result.forwardCount) (\(fwdPct))"),
            ("Reverse-complemented", "\(result.reverseComplementedCount) (\(rcPct))"),
            ("Unmatched", "\(result.unmatchedCount) (\(unmPct))"),
        ]))
        print("")

        // Print output files
        print(formatter.header("Output Files"))
        print("  Oriented: \(formatter.path(result.orientedFASTQ.path))")
        if let unoriented = result.unorientedFASTQ {
            print("  Unoriented: \(formatter.path(unoriented.path))")
        }
        print("  Results TSV: \(formatter.path(result.tabbedOutput.path))")
        print("")
        print(formatter.success("Orient completed in \(String(format: "%.1f", result.wallClockSeconds))s"))
    }

    func makeConfigForTesting() throws -> OrientConfig {
        OrientConfig(
            inputURL: URL(fileURLWithPath: fastqFile),
            referenceURL: URL(fileURLWithPath: reference),
            wordLength: wordLength,
            dbMask: mask,
            qMask: mask,
            saveUnoriented: saveUnoriented,
            threads: globalOptions.threads ?? 0,
            extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
        )
    }

    private func orientProvenanceOptions(
        inputURL: URL,
        referenceURL: URL,
        effectiveThreads: Int
    ) -> ProvenanceOptions {
        let resolved: [String: ParameterValue] = [
            "input": .file(inputURL),
            "reference": .file(referenceURL),
            "wordLength": .integer(wordLength),
            "mask": .string(mask),
            "dbMask": .string(mask),
            "qMask": .string(mask),
            "saveUnoriented": .boolean(saveUnoriented),
            "threads": .integer(effectiveThreads),
            "extraArgs": .string(extraArgs),
            "extraArguments": .array((try? AdvancedCommandLineOptions.parse(extraArgs))?.map(ParameterValue.string) ?? []),
        ]
        return ProvenanceOptions(
            explicit: resolved,
            defaults: [
                "wordLength": .integer(12),
                "mask": .string("dust"),
                "dbMask": .string("dust"),
                "qMask": .string("dust"),
                "saveUnoriented": .boolean(false),
                "threads": .integer(0),
                "extraArgs": .string(""),
                "extraArguments": .array([]),
            ],
            resolvedDefaults: resolved
        )
    }

}
