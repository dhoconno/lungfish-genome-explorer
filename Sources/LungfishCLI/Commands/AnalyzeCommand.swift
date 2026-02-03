// AnalyzeCommand.swift - Analysis command group
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Analyze sequences and annotations
struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze sequences and generate statistics",
        subcommands: [
            StatsSubcommand.self,
            FileValidateSubcommand.self,
        ],
        defaultSubcommand: StatsSubcommand.self
    )
}

// MARK: - Stats Subcommand

/// Calculate sequence statistics
struct StatsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Calculate sequence statistics",
        discussion: """
            Calculate statistics for sequence files including:
            - Sequence count and total length
            - GC content
            - N50/N90 values
            - Length distribution

            Examples:
              lungfish analyze stats genome.fasta
              lungfish analyze stats reads.fastq --per-sequence
            """
    )

    @Argument(help: "Input file path")
    var input: String

    @Flag(
        name: .customLong("per-sequence"),
        help: "Show statistics per sequence"
    )
    var perSequence: Bool = false

    @Flag(
        name: .customLong("no-gc"),
        inversion: .prefixedNo,
        help: "Skip GC content calculation"
    )
    var calculateGCContent: Bool = true

    @Flag(
        name: .customLong("length-distribution"),
        help: "Show length distribution"
    )
    var lengthDistribution: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        let inputURL = URL(fileURLWithPath: input)

        // Read sequences
        let sequences: [Sequence]
        let ext = inputURL.pathExtension.lowercased()

        switch ext {
        case "fa", "fasta", "fna", "faa":
            let reader = try FASTAReader(url: inputURL)
            sequences = try await reader.readAll()
        case "fastq", "fq":
            let reader = FASTQReader()
            let fastqRecords = try await reader.readAll(from: inputURL)
            // Convert FASTQRecord to Sequence
            sequences = try fastqRecords.map { record in
                try Sequence(
                    name: record.identifier,
                    description: record.description,
                    alphabet: .dna,
                    bases: record.sequence
                )
            }
        case "gb", "gbk", "genbank":
            let reader = try GenBankReader(url: inputURL)
            let records = try await reader.readAll()
            sequences = records.map { $0.sequence }
        default:
            throw CLIError.formatDetectionFailed(path: input)
        }

        // Calculate statistics
        let stats = calculateStats(sequences: sequences)

        // Output based on format
        switch globalOptions.outputFormat {
        case .json:
            let handler = JSONOutputHandler()
            handler.writeData(stats, label: nil)

        case .tsv:
            print("file\tsequences\ttotal_length\tgc_content\tn50\tmin_length\tmax_length")
            print("\(inputURL.lastPathComponent)\t\(stats.sequenceCount)\t\(stats.totalLength)\t\(String(format: "%.3f", stats.gcContent))\t\(stats.n50)\t\(stats.minLength)\t\(stats.maxLength)")

        case .text:
            print(formatter.header("Sequence Statistics"))
            print(formatter.keyValueTable([
                ("File", inputURL.lastPathComponent),
                ("Sequences", formatter.number(stats.sequenceCount)),
                ("Total length", "\(formatter.number(stats.totalLength)) bp"),
                ("GC content", String(format: "%.1f%%", stats.gcContent * 100)),
                ("N50", "\(formatter.number(stats.n50)) bp"),
                ("Min length", "\(formatter.number(stats.minLength)) bp"),
                ("Max length", "\(formatter.number(stats.maxLength)) bp"),
                ("Mean length", String(format: "%.0f bp", stats.meanLength)),
            ]))

            if perSequence && sequences.count <= 50 {
                print("\n" + formatter.header("Per-Sequence Statistics"))
                let headers = ["Name", "Length", "GC%"]
                let rows = sequences.map { seq -> [String] in
                    let seqStr = seq.asString()
                    let gc = calculateGC(seqStr)
                    return [seq.name, "\(seq.length)", String(format: "%.1f", gc * 100)]
                }
                print(formatter.table(headers: headers, rows: rows))
            }
        }
    }

    private func calculateStats(sequences: [Sequence]) -> SequenceStats {
        let lengths = sequences.map { $0.length }
        let totalLength = lengths.reduce(0, +)

        // Calculate GC
        var gcCount = 0
        var atCount = 0
        for seq in sequences {
            let str = seq.asString().uppercased()
            for char in str {
                if char == "G" || char == "C" {
                    gcCount += 1
                } else if char == "A" || char == "T" || char == "U" {
                    atCount += 1
                }
            }
        }
        let gcContent = Double(gcCount) / Double(max(gcCount + atCount, 1))

        // Calculate N50
        let sortedLengths = lengths.sorted(by: >)
        var cumulativeLength = 0
        var n50 = 0
        for length in sortedLengths {
            cumulativeLength += length
            if cumulativeLength >= totalLength / 2 {
                n50 = length
                break
            }
        }

        return SequenceStats(
            sequenceCount: sequences.count,
            totalLength: totalLength,
            gcContent: gcContent,
            n50: n50,
            minLength: lengths.min() ?? 0,
            maxLength: lengths.max() ?? 0,
            meanLength: Double(totalLength) / Double(max(sequences.count, 1))
        )
    }

    private func calculateGC(_ sequence: String) -> Double {
        var gc = 0
        var total = 0
        for char in sequence.uppercased() {
            if char == "G" || char == "C" {
                gc += 1
                total += 1
            } else if char == "A" || char == "T" || char == "U" {
                total += 1
            }
        }
        return Double(gc) / Double(max(total, 1))
    }
}

/// Statistics result
struct SequenceStats: Codable {
    let sequenceCount: Int
    let totalLength: Int
    let gcContent: Double
    let n50: Int
    let minLength: Int
    let maxLength: Int
    let meanLength: Double
}

// MARK: - Validate Subcommand

/// Validate file format
struct FileValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate sequence file format",
        discussion: """
            Validate that a file is well-formed and conforms to format specifications.

            Examples:
              lungfish analyze validate genome.fasta
              lungfish analyze validate variants.vcf --strict
            """
    )

    @Argument(help: "Input file(s) to validate")
    var files: [String]

    @Flag(
        name: .customLong("strict"),
        help: "Enable strict validation"
    )
    var strict: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        var allValid = true
        var results: [ValidationFileResult] = []

        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                allValid = false
                results.append(ValidationFileResult(
                    file: file,
                    valid: false,
                    format: nil,
                    errors: ["File not found"]
                ))
                print(formatter.error("File not found: \(file)"))
                continue
            }

            let url = URL(fileURLWithPath: file)
            let ext = url.pathExtension.lowercased()
            var errors: [String] = []
            var format: String? = nil

            do {
                switch ext {
                case "fa", "fasta", "fna", "faa":
                    format = "FASTA"
                    let reader = try FASTAReader(url: url)
                    let sequences = try await reader.readAll()
                    if sequences.isEmpty {
                        errors.append("No sequences found")
                    }

                case "fastq", "fq":
                    format = "FASTQ"
                    let reader = FASTQReader()
                    let records = try await reader.readAll(from: url)
                    if records.isEmpty {
                        errors.append("No sequences found")
                    }

                case "gb", "gbk", "genbank":
                    format = "GenBank"
                    let reader = try GenBankReader(url: url)
                    _ = try await reader.readAll()

                case "gff", "gff3":
                    format = "GFF3"
                    let reader = GFF3Reader()
                    _ = try await reader.readAll(from: url)

                case "vcf":
                    format = "VCF"
                    let reader = VCFReader()
                    _ = try await reader.readAll(from: url)

                case "bed":
                    format = "BED"
                    let reader = BEDReader()
                    _ = try await reader.readAll(from: url)

                default:
                    errors.append("Unknown file format")
                }
            } catch {
                errors.append(error.localizedDescription)
            }

            let isValid = errors.isEmpty
            if !isValid { allValid = false }

            results.append(ValidationFileResult(
                file: file,
                valid: isValid,
                format: format,
                errors: errors
            ))

            if globalOptions.outputFormat == .text {
                if isValid {
                    print(formatter.success("\(url.lastPathComponent): Valid \(format ?? "unknown") file"))
                } else {
                    print(formatter.error("\(url.lastPathComponent): Invalid"))
                    for error in errors {
                        print("  - \(error)")
                    }
                }
            }
        }

        if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(ValidationResult(files: results, allValid: allValid), label: nil)
        }

        if !allValid {
            throw ExitCode.failure
        }
    }
}

/// Validation result for a single file
struct ValidationFileResult: Codable {
    let file: String
    let valid: Bool
    let format: String?
    let errors: [String]
}

/// Overall validation result
struct ValidationResult: Codable {
    let files: [ValidationFileResult]
    let allValid: Bool
}
