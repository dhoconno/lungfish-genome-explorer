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
            CompositionSubcommand.self,
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
        name: .customLong("gc"),
        inversion: .prefixedNo,
        help: "Calculate GC content (use --no-gc to skip)"
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

        var summary = SequenceStatsAccumulator(calculateGC: calculateGCContent, includeRecords: perSequence)
        try await SequenceSummaryInput.forEachRecord(at: inputURL) { sequence in
            summary.add(sequence)
        }
        let stats = summary.result(includeLengthDistribution: lengthDistribution)

        switch globalOptions.outputFormat {
        case .json:
            JSONOutputHandler().writeData(stats, label: nil)
        case .tsv:
            print("file\tsequences\ttotal_length\tgc_content\tn50\tn90\tmin_length\tmax_length")
            let gc = stats.gcContent.map { String(format: "%.3f", $0) } ?? "."
            print("\(inputURL.lastPathComponent)\t\(stats.sequenceCount)\t\(stats.totalLength)\t\(gc)\t\(stats.n50)\t\(stats.n90 ?? 0)\t\(stats.minLength)\t\(stats.maxLength)")
            if let records = stats.perSequence {
                print("\nname\tlength\tgc_content")
                for record in records {
                    let gc = record.gcContent.map { String(format: "%.3f", $0) } ?? "."
                    print("\(record.name)\t\(record.length)\t\(gc)")
                }
            }
            if let distribution = stats.lengthDistribution {
                print("\nlength\tcount")
                for length in distribution.keys.sorted() { print("\(length)\t\(distribution[length] ?? 0)") }
            }
        case .text:
            print(formatter.header("Sequence Statistics"))
            var rows = [
                ("File", inputURL.lastPathComponent),
                ("Sequences", formatter.number(stats.sequenceCount)),
                ("Total length", "\(formatter.number(stats.totalLength)) bp"),
                ("N50", "\(formatter.number(stats.n50)) bp"),
                ("N90", "\(formatter.number(stats.n90 ?? 0)) bp"),
                ("Min length", "\(formatter.number(stats.minLength)) bp"),
                ("Max length", "\(formatter.number(stats.maxLength)) bp"),
                ("Mean length", String(format: "%.0f bp", stats.meanLength)),
            ]
            if let gc = stats.gcContent { rows.insert(("GC content", String(format: "%.1f%%", gc * 100)), at: 3) }
            print(formatter.keyValueTable(rows))
            if let records = stats.perSequence {
                print("\n" + formatter.header("Per-Sequence Statistics"))
                let rows = records.map { record in
                    [record.name, String(record.length)] + (calculateGCContent ? [String(format: "%.1f", (record.gcContent ?? 0) * 100)] : [])
                }
                print(formatter.table(headers: ["Name", "Length"] + (calculateGCContent ? ["GC%"] : []), rows: rows))
            }
            if let distribution = stats.lengthDistribution {
                print("\n" + formatter.header("Length Distribution"))
                print(formatter.table(headers: ["Length", "Count"], rows: distribution.keys.sorted().map {
                    [String($0), String(distribution[$0] ?? 0)]
                }))
            }
        }
    }
}

struct SequenceRecordStats: Codable {
    let name: String
    let length: Int
    let gcContent: Double?
}

/// Optional fields preserve the distinction between a measured zero and a skipped calculation.
struct SequenceStats: Codable {
    let sequenceCount: Int
    let totalLength: Int
    let gcContent: Double?
    let n50: Int
    let minLength: Int
    let maxLength: Int
    let meanLength: Double
    var n90: Int? = nil
    var lengthDistribution: [Int: Int]? = nil
    var perSequence: [SequenceRecordStats]? = nil
}

private struct SequenceStatsAccumulator {
    let calculateGC: Bool
    let includeRecords: Bool
    var recordCount = 0
    var totalLength = 0
    var gcCount = 0
    var knownBaseCount = 0
    var histogram: [Int: Int] = [:]
    var records: [SequenceRecordStats] = []

    mutating func add(_ sequence: Sequence) {
        recordCount += 1
        totalLength += sequence.length
        histogram[sequence.length, default: 0] += 1
        var gc = 0
        var known = 0
        if calculateGC {
            for base in sequence.asString().uppercased() {
                switch base {
                case "G", "C": gc += 1; known += 1
                case "A", "T", "U": known += 1
                default: break
                }
            }
            gcCount += gc
            knownBaseCount += known
        }
        if includeRecords {
            records.append(SequenceRecordStats(
                name: sequence.name, length: sequence.length,
                gcContent: calculateGC ? Double(gc) / Double(max(known, 1)) : nil
            ))
        }
    }

    func result(includeLengthDistribution: Bool) -> SequenceStats {
        SequenceStats(
            sequenceCount: recordCount, totalLength: totalLength,
            gcContent: calculateGC ? Double(gcCount) / Double(max(knownBaseCount, 1)) : nil,
            n50: SequenceLengthStatistics.nx(histogram: histogram, totalBases: Int64(totalLength)),
            minLength: histogram.keys.min() ?? 0, maxLength: histogram.keys.max() ?? 0,
            meanLength: Double(totalLength) / Double(max(recordCount, 1)),
            n90: SequenceLengthStatistics.nx(histogram: histogram, totalBases: Int64(totalLength), percentage: 90),
            lengthDistribution: includeLengthDistribution ? histogram : nil,
            perSequence: includeRecords ? records : nil
        )
    }
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
        var sawMissingInput = false
        var results: [ValidationFileResult] = []

        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                allValid = false
                sawMissingInput = true
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
            var detectURL = url
            if detectURL.pathExtension.lowercased() == "gz" {
                detectURL = detectURL.deletingPathExtension()
            }
            let ext = detectURL.pathExtension.lowercased()
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
            throw sawMissingInput ? CLIExitCode.inputError.exitCode : CLIExitCode.formatError.exitCode
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
