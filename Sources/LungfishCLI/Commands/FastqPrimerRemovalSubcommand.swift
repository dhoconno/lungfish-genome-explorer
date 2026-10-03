// FastqPrimerRemovalSubcommand.swift - Remove primer sequences from FASTQ reads
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Primer Removal

struct FastqPrimerRemovalSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "primer-remove",
        abstract: "Remove primer sequences from FASTQ reads"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("literal"), help: "Primer sequence (IUPAC nucleotides)")
    var literalSequence: String?

    @Option(name: .customLong("ref"), help: "Primer reference FASTA file")
    var reference: String?

    @Option(name: .customLong("kmer"), help: "K-mer size (default: 23)")
    var kmerSize: Int = 23

    @Option(name: .customLong("mink"), help: "Minimum k-mer size (default: 11)")
    var minKmer: Int = 11

    @Option(name: .customLong("hdist"), help: "Hamming distance tolerance (default: 1)")
    var hammingDistance: Int = 1

    @Option(name: .customLong("engine"), help: "Primer trimming engine: bbduk or cutadapt-linked")
    var engine: FastqPrimerRemovalEngine = .bbduk

    @Option(name: .customLong("minimum-overlap"), help: "Minimum overlap for cutadapt-linked primer matching")
    var minimumOverlap: Int = 12

    @Option(name: .customLong("error-rate"), help: "Maximum error rate for cutadapt-linked primer matching")
    var errorRate: Double = 0.12

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "primer-remove", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard kmerSize > 0 else { throw ValidationError("--kmer must be > 0") }
        guard minKmer > 0 else { throw ValidationError("--mink must be > 0") }
        guard minKmer <= kmerSize else {
            throw ValidationError("--mink (\(minKmer)) must be <= --kmer (\(kmerSize))")
        }
        guard hammingDistance >= 0 else { throw ValidationError("--hdist must be >= 0") }
        guard minimumOverlap > 0 else { throw ValidationError("--minimum-overlap must be > 0") }
        guard errorRate >= 0.0, errorRate <= 1.0 else {
            throw ValidationError("--error-rate must be between 0 and 1")
        }
        let runner = NativeToolRunner.shared

        let startedAt = Date()
        let referenceURL = reference.map { URL(fileURLWithPath: $0) }
        let execution = try await nativePrimerRemovalExecution(
            inputURL: inputURL,
            outputPath: output.output,
            runner: runner
        )
        let result = execution.result
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "\(execution.tool.rawValue) primer removal failed: \(result.stderr)")
        }
        var cliArguments = ["primer-remove", resolvedInput.originalURL.path]
        if let literalSequence {
            cliArguments += ["--literal", literalSequence]
        }
        if let reference {
            cliArguments += ["--ref", reference]
        }
        if engine != .bbduk {
            cliArguments += ["--engine", engine.rawValue]
        }
        if kmerSize != 23 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        if minKmer != 11 {
            cliArguments += ["--mink", String(minKmer)]
        }
        if hammingDistance != 1 {
            cliArguments += ["--hdist", String(hammingDistance)]
        }
        if engine == .cutadaptLinked || minimumOverlap != 12 {
            cliArguments += ["--minimum-overlap", String(minimumOverlap)]
        }
        if engine == .cutadaptLinked || errorRate != 0.12 {
            cliArguments += ["--error-rate", String(errorRate)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq primer-remove",
            nativeTool: execution.tool,
            cliArguments: cliArguments,
            nativeArguments: execution.arguments,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "literal": literalSequence.map(ParameterValue.string) ?? .null,
                "reference": reference.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
                "kmer": .integer(kmerSize),
                "mink": .integer(minKmer),
                "hdist": .integer(hammingDistance),
                "engine": .string(engine.rawValue),
                "minimumOverlap": .integer(minimumOverlap),
                "errorRate": .number(errorRate),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "literal": .null,
                "reference": .null,
                "kmer": .integer(23),
                "mink": .integer(11),
                "hdist": .integer(1),
                "engine": .string(FastqPrimerRemovalEngine.bbduk.rawValue),
                "minimumOverlap": .integer(12),
                "errorRate": .number(0.12),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords()
                + (referenceURL.map { provenanceRecords(for: $0, format: .fasta, role: .reference) } ?? []),
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Primer-trimmed reads written to \(output.output)\n".utf8))
    }

    private func nativePrimerRemovalExecution(
        inputURL: URL,
        outputPath: String,
        runner: NativeToolRunner
    ) async throws -> (tool: NativeTool, arguments: [String], result: NativeToolResult) {
        switch engine {
        case .bbduk:
            var args = [
                "in=\(inputURL.path)",
                "out=\(outputPath)",
                "ktrim=r",
                "k=\(kmerSize)",
                "mink=\(minKmer)",
                "hdist=\(hammingDistance)",
                // Per record, as FASTQConsumerRegistry declares. Left to
                // guess, bbduk pairs /1 /2 names by position and aborts
                // ("corrupt or truncated") on an odd record count.
                "interleaved=f",
            ]

            if let literalSequence {
                args.append("literal=\(literalSequence)")
            } else if let reference {
                guard FileManager.default.fileExists(atPath: reference) else {
                    throw CLIError.inputFileNotFound(path: reference)
                }
                args.append("ref=\(reference)")
            } else {
                throw ValidationError("Specify --literal or --ref for primer sequence")
            }

            let env = await bbToolsEnvironment(runner: runner)
            let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
            return (.bbduk, args, result)

        case .cutadaptLinked:
            guard literalSequence == nil else {
                throw ValidationError("--engine cutadapt-linked requires --ref, not --literal")
            }
            guard let reference else {
                throw ValidationError("--engine cutadapt-linked requires --ref")
            }
            guard FileManager.default.fileExists(atPath: reference) else {
                throw CLIError.inputFileNotFound(path: reference)
            }
            let stagingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-cutadapt-linked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }

            let linkedPrimerURL = try await writeLinkedPrimerAdapters(
                from: URL(fileURLWithPath: reference),
                to: stagingDirectory.appendingPathComponent("linked-primers.fasta")
            )
            let args = [
                "-e", String(errorRate),
                "-O", String(minimumOverlap),
                "--discard-untrimmed",
                "-g", "file:\(linkedPrimerURL.path)",
                "-o", outputPath,
                inputURL.path,
            ]
            let result = try await runner.run(.cutadapt, arguments: args, timeout: 1800)
            return (.cutadapt, args, result)
        }
    }

    private func writeLinkedPrimerAdapters(from referenceURL: URL, to destinationURL: URL) async throws -> URL {
        let records = try await FASTAReader(url: referenceURL).readAll()
        var forwardByBase: [String: String] = [:]
        var reverseByBase: [String: String] = [:]

        for record in records {
            guard let parsed = parsePrimerPairName(record.name) else { continue }
            let sequence = record.asString().uppercased()
            switch parsed.role {
            case .forward:
                forwardByBase[parsed.base] = sequence
            case .reverse:
                reverseByBase[parsed.base] = sequence
            }
        }

        var contents = ""
        for base in forwardByBase.keys.sorted() {
            guard let forward = forwardByBase[base], let reverse = reverseByBase[base] else { continue }
            contents += ">\(base)_R_to_rcF\n\(reverse)...\(reverseComplement(forward))\n"
            contents += ">\(base)_F_to_rcR\n\(forward)...\(reverseComplement(reverse))\n"
        }

        guard !contents.isEmpty else {
            throw ValidationError(
                "No paired primers found in \(referenceURL.path). Expected FASTA headers ending in -F/-R or _F/_R."
            )
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        return destinationURL
    }

    private enum PrimerRole {
        case forward
        case reverse
    }

    private func parsePrimerPairName(_ name: String) -> (base: String, role: PrimerRole)? {
        let suffixes: [(String, PrimerRole)] = [
            ("-F", .forward), ("_F", .forward),
            ("-R", .reverse), ("_R", .reverse),
            ("-FORWARD", .forward), ("_FORWARD", .forward),
            ("-REVERSE", .reverse), ("_REVERSE", .reverse),
        ]
        let uppercasedName = name.uppercased()
        for (suffix, role) in suffixes {
            guard uppercasedName.hasSuffix(suffix) else { continue }
            let index = name.index(name.endIndex, offsetBy: -suffix.count)
            return (String(name[..<index]), role)
        }
        return nil
    }

    private func reverseComplement(_ sequence: String) -> String {
        let map: [Character: Character] = [
            "A": "T", "C": "G", "G": "C", "T": "A", "U": "A",
            "R": "Y", "Y": "R", "S": "S", "W": "W", "K": "M", "M": "K",
            "B": "V", "D": "H", "H": "D", "V": "B", "N": "N",
        ]
        return String(sequence.uppercased().reversed().map { map[$0] ?? "N" })
    }
}
