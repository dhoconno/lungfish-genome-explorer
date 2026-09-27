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
        help: ArgumentHelp(
            "Also reject readable but irregular files.",
            discussion: """
                FASTA: duplicate record names, empty records, characters outside the IUPAC \
                nucleotide and protein alphabets. FASTQ: duplicate read identifiers, empty \
                reads. VCF: data lines whose column count disagrees with the #CHROM header, \
                and records that repeat an earlier CHROM, POS, REF and ALT. Other formats \
                have no extra checks.
                """
        )
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
                    if strict {
                        errors.append(contentsOf: StrictSequenceFileChecks.fastaIssues(
                            records: sequences.map { (name: $0.name, sequence: $0.asString()) }
                        ))
                    }

                case "fastq", "fq":
                    format = "FASTQ"
                    let reader = FASTQReader()
                    let records = try await reader.readAll(from: url)
                    if records.isEmpty {
                        errors.append("No sequences found")
                    }
                    if strict {
                        errors.append(contentsOf: StrictSequenceFileChecks.fastqIssues(
                            records: records.map { (identifier: $0.identifier, sequence: $0.sequence) }
                        ))
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
                    if strict {
                        errors.append(contentsOf: try await StrictSequenceFileChecks.vcfIssues(at: url))
                    }

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

/// The extra checks `analyze validate --strict` runs on files that parsed.
///
/// A file can be readable and still irregular: a FASTA with two records of the
/// same name, a FASTQ whose reads repeat an identifier, a VCF whose data lines
/// carry a different number of columns from its `#CHROM` header. The plain
/// validator accepts those; `--strict` reports them.
enum StrictSequenceFileChecks {
    /// Issues beyond this many are summarised as a count.
    static let maxReportedIssues = 20

    static func fastaIssues(records: [(name: String, sequence: String)]) -> [String] {
        var issues: [String] = []
        var seenNames: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            let recordNumber = index + 1
            let name = firstToken(record.name)
            if let firstIndex = seenNames[name] {
                issues.append("Record \(recordNumber) repeats the name '\(name)' of record \(firstIndex)")
            } else {
                seenNames[name] = recordNumber
            }
            if record.sequence.isEmpty {
                issues.append("Record \(recordNumber) ('\(name)') has an empty sequence")
            } else if let offending = record.sequence.first(where: { !isIUPACSequenceCharacter($0) }) {
                issues.append("Record \(recordNumber) ('\(name)') contains '\(offending)', which is not an IUPAC nucleotide or amino acid code")
            }
        }
        return capped(issues)
    }

    static func fastqIssues(records: [(identifier: String, sequence: String)]) -> [String] {
        var issues: [String] = []
        var seenIdentifiers: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            let recordNumber = index + 1
            let identifier = firstToken(record.identifier)
            if let firstIndex = seenIdentifiers[identifier] {
                issues.append("Read \(recordNumber) repeats the identifier '\(identifier)' of read \(firstIndex)")
            } else {
                seenIdentifiers[identifier] = recordNumber
            }
            if record.sequence.isEmpty {
                issues.append("Read \(recordNumber) ('\(identifier)') has an empty sequence")
            }
        }
        return capped(issues)
    }

    static func vcfIssues(at url: URL) async throws -> [String] {
        var lines: [String] = []
        for try await line in url.linesAutoDecompressing() {
            lines.append(line)
        }
        return vcfIssues(lines: lines)
    }

    static func vcfIssues(lines: [String]) -> [String] {
        var issues: [String] = []
        var expectedColumns: Int?
        var seenRecords: [String: Int] = [:]
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty || line.hasPrefix("##") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if line.hasPrefix("#CHROM") {
                expectedColumns = fields.count
                continue
            }
            guard let expectedColumns else { continue }
            if fields.count != expectedColumns {
                issues.append("Line \(lineNumber) has \(fields.count) columns; the #CHROM header declares \(expectedColumns)")
                continue
            }
            guard fields.count >= 5 else { continue }
            let key = "\(fields[0])\t\(fields[1])\t\(fields[3])\t\(fields[4])"
            if let firstLine = seenRecords[key] {
                issues.append("Line \(lineNumber) repeats \(fields[0]):\(fields[1]) \(fields[3])>\(fields[4]) first seen on line \(firstLine)")
            } else {
                seenRecords[key] = lineNumber
            }
        }
        return capped(issues)
    }

    private static func firstToken(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? text
    }

    /// Letters cover every IUPAC nucleotide and amino acid code (including
    /// ambiguity codes); `-` and `.` are gaps, `*` a translation stop.
    private static func isIUPACSequenceCharacter(_ character: Character) -> Bool {
        character.isLetter && character.isASCII || character == "-" || character == "*" || character == "."
    }

    private static func capped(_ issues: [String]) -> [String] {
        guard issues.count > maxReportedIssues else { return issues }
        return Array(issues.prefix(maxReportedIssues)) + ["... and \(issues.count - maxReportedIssues) more"]
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
