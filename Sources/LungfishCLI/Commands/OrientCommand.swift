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
        let startedAt = Date()
        let result = try await pipeline.run(config: config) { fraction, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
        let vsearchArguments = config.vsearchArguments(
            orientedOutput: result.orientedFASTQ,
            tabbedOutput: result.tabbedOutput,
            unmatchedOutput: result.unorientedFASTQ
        )
        try saveProvenance(
            inputURL: inputURL,
            referenceURL: referenceURL,
            result: result,
            argv: CommandLine.arguments,
            vsearchArguments: ["vsearch"] + vsearchArguments,
            exitCode: 0,
            stderr: nil,
            fallbackWallTime: Date().timeIntervalSince(startedAt)
        )

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

    func provenanceRunForTesting(
        inputURL: URL,
        referenceURL: URL,
        result: OrientResult,
        argv: [String],
        vsearchArguments: [String],
        exitCode: Int32,
        stderr: String?
    ) throws -> WorkflowRun {
        try makeProvenanceRun(
            inputURL: inputURL,
            referenceURL: referenceURL,
            result: result,
            argv: argv,
            vsearchArguments: vsearchArguments,
            exitCode: exitCode,
            stderr: stderr,
            fallbackWallTime: result.wallClockSeconds
        )
    }

    private func saveProvenance(
        inputURL: URL,
        referenceURL: URL,
        result: OrientResult,
        argv: [String],
        vsearchArguments: [String],
        exitCode: Int32,
        stderr: String?,
        fallbackWallTime: TimeInterval
    ) throws {
        let run = try makeProvenanceRun(
            inputURL: inputURL,
            referenceURL: referenceURL,
            result: result,
            argv: argv,
            vsearchArguments: vsearchArguments,
            exitCode: exitCode,
            stderr: stderr,
            fallbackWallTime: fallbackWallTime
        )
        try writeOrientWorkflowRun(run, to: result.orientedFASTQ.deletingLastPathComponent())
    }

    private func makeProvenanceRun(
        inputURL: URL,
        referenceURL: URL,
        result: OrientResult,
        argv: [String],
        vsearchArguments: [String],
        exitCode: Int32,
        stderr: String?,
        fallbackWallTime: TimeInterval
    ) throws -> WorkflowRun {
        var outputs = [
            ProvenanceRecorder.fileRecord(url: result.orientedFASTQ, role: .output),
            ProvenanceRecorder.fileRecord(url: result.tabbedOutput, format: .text, role: .output),
        ]
        if let unorientedFASTQ = result.unorientedFASTQ {
            outputs.append(ProvenanceRecorder.fileRecord(url: unorientedFASTQ, role: .output))
        }
        let step = StepExecution(
            toolName: "vsearch",
            toolVersion: "bundled",
            command: vsearchArguments,
            inputs: [
                ProvenanceRecorder.fileRecord(url: inputURL, role: .input),
                ProvenanceRecorder.fileRecord(url: referenceURL, role: .reference),
            ],
            outputs: outputs,
            exitCode: exitCode,
            wallTime: result.wallClockSeconds > 0 ? result.wallClockSeconds : fallbackWallTime,
            stderr: stderr,
            endTime: Date()
        )
        return WorkflowRun(
            name: "lungfish orient",
            endTime: Date(),
            status: exitCode == 0 ? .completed : .failed,
            steps: [step],
            parameters: [
                "wordLength": .integer(wordLength),
                "mask": .string(mask),
                "saveUnoriented": .boolean(saveUnoriented),
                "threads": .integer(globalOptions.threads ?? 0),
                "extraArgs": .string(extraArgs),
                "argv": .array(argv.map { .string($0) }),
                "command": .string(argv.map(shellEscape).joined(separator: " ")),
                "forwardCount": .integer(result.forwardCount),
                "reverseComplementedCount": .integer(result.reverseComplementedCount),
                "unmatchedCount": .integer(result.unmatchedCount),
            ]
        )
    }
}

private func writeOrientWorkflowRun(_ run: WorkflowRun, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(run)
    try data.write(
        to: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
        options: .atomic
    )
}
