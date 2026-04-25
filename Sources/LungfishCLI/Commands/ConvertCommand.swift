// ConvertCommand.swift - Format conversion command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Convert between sequence file formats
struct ConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert between sequence file formats",
        discussion: """
            Convert sequences between FASTA, GenBank, GFF3, and other formats.
            Format is auto-detected from input file extension or can be specified.

            Examples:
              lungfish convert input.gb --to output.fa --to-format fasta
              lungfish convert input.fasta --to output.gb --to-format genbank
            """
    )

    @Argument(help: "Input file path")
    var input: String

    @Option(
        name: .customLong("to-format"),
        help: "Output format: fasta, genbank, gff3, fastq"
    )
    var toFormat: String = "fasta"

    @Option(
        name: .customLong("to"),
        help: "Output file path (required)"
    )
    var outputFile: String

    @Flag(
        name: .customLong("include-annotations"),
        help: "Include annotations in output (if supported)"
    )
    var includeAnnotations: Bool = false

    @Flag(
        name: .customLong("force"),
        help: "Overwrite existing output file"
    )
    var force: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        // Check output file
        if FileManager.default.fileExists(atPath: outputFile) && !force {
            throw CLIError.outputWriteFailed(
                path: outputFile,
                reason: "File already exists. Use --force to overwrite."
            )
        }

        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: outputFile)

        // Show progress
        if !globalOptions.quiet {
            print(formatter.info("Converting \(inputURL.lastPathComponent) to \(toFormat.uppercased())..."))
        }

        // Detect input format and read - strip .gz extension for format detection
        let sequences: [Sequence]
        let annotations: [SequenceAnnotation]

        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()
        switch ext {
        case "fa", "fasta", "fna", "faa":
            let reader = try FASTAReader(url: inputURL)
            sequences = try await reader.readAll()
            annotations = []

        case "gb", "gbk", "genbank":
            let reader = try GenBankReader(url: inputURL)
            let records = try await reader.readAll()
            sequences = records.map { $0.sequence }
            annotations = records.flatMap { $0.annotations }

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
            annotations = []

        case "lungfishref":
            (sequences, annotations) = try await Self.readReferenceBundle(
                inputURL,
                includeAnnotations: includeAnnotations
            )

        default:
            throw CLIError.formatDetectionFailed(path: input)
        }

        // Write output
        switch toFormat.lowercased() {
        case "fasta", "fa":
            let writer = FASTAWriter(url: outputURL)
            try writer.write(sequences)

        case "genbank", "gb":
            let writer = GenBankWriter(url: outputURL)
            let records = sequences.map { seq in
                GenBankRecord(
                    sequence: seq,
                    annotations: includeAnnotations ? annotations.filter { $0.chromosome == seq.name } : [],
                    locus: LocusInfo(
                        name: seq.name,
                        length: seq.length,
                        moleculeType: seq.alphabet == .dna ? .dna : (seq.alphabet == .rna ? .rna : .protein),
                        topology: .linear,
                        division: nil,
                        date: Self.currentDateString()
                    ),
                    definition: seq.description,
                    accession: nil,
                    version: nil
                )
            }
            try writer.write(records)

        case "fastq", "fq":
            // Convert Sequence to FASTQRecord with default high quality scores
            let fastqRecords = sequences.map { seq in
                FASTQRecord(
                    identifier: seq.name,
                    description: seq.description,
                    sequence: seq.asString(),
                    qualityString: String(repeating: "I", count: seq.length),  // Q40 quality
                    encoding: .phred33
                )
            }
            try FASTQWriter.write(fastqRecords, to: outputURL)

        case "gff3", "gff":
            guard !annotations.isEmpty else {
                throw CLIError.conversionFailed(reason: "No annotations to write to GFF3")
            }
            try await GFF3Writer.write(annotations, to: outputURL)

        default:
            throw CLIError.unsupportedFormat(format: toFormat)
        }

        // Success message
        if !globalOptions.quiet {
            print(formatter.success("Converted \(sequences.count) sequence(s) to \(outputURL.lastPathComponent)"))
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let result = ConvertResult(
                inputFile: input,
                outputFile: outputFile,
                inputFormat: ext,
                outputFormat: toFormat,
                sequenceCount: sequences.count,
                annotationCount: includeAnnotations ? annotations.count : 0
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }

    private static func readReferenceBundle(
        _ bundleURL: URL,
        includeAnnotations: Bool
    ) async throws -> ([Sequence], [SequenceAnnotation]) {
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let genome = manifest.genome else {
            throw CLIError.conversionFailed(reason: "Reference bundle has no genome sequence: \(bundleURL.path)")
        }

        let bundle = try await ReferenceBundle(url: bundleURL)
        let sequences = try await genome.chromosomes.mapAsync { chromosome in
            let region = GenomicRegion(chromosome: chromosome.name, start: 0, end: Int(chromosome.length))
            let bases = try await bundle.fetchSequence(region: region)
            return try Sequence(
                name: chromosome.name,
                description: chromosome.fastaDescription,
                alphabet: .dna,
                bases: bases
            )
        }

        guard includeAnnotations else {
            return (sequences, [])
        }

        var annotations: [SequenceAnnotation] = []
        for track in manifest.annotations {
            guard let dbPath = track.databasePath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            let db = try AnnotationDatabase(url: dbURL)
            annotations.append(contentsOf: db.query(limit: Int.max).map { $0.toAnnotation() })
        }

        return (sequences, annotations)
    }
}

private extension Array {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}

/// Result data for convert command
struct ConvertResult: Codable {
    let inputFile: String
    let outputFile: String
    let inputFormat: String
    let outputFormat: String
    let sequenceCount: Int
    let annotationCount: Int
}
