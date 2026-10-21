// FastqTranslateSubcommand.swift - Translate FASTQ reads to protein FASTA
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - FASTQ Translate

struct FastqTranslateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate FASTQ reads to protein FASTA",
        discussion: """
            When the two mates of an interleaved pair share one read ID, the protein names add .1 for mate 1 \
            and .2 for mate 2 right after the ID, so a pair named A1 gives >A1.1_frame+1 and >A1.2_frame+1. \
            Every other read keeps its name, including single-end reads, mates already named apart such as \
            A1/1 and A1/2, Nanopore and PacBio reads, and the pairs in a bundle that also holds merged or \
            unpaired reads.
            """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(
        name: .customLong("frame"),
        help: "Reading frame: 1-3 forward, 4-6 reverse complement, printed in the headers as -1 to -3 (frame -1 starts at the last base)"
    )
    var frame: Int = 1

    @Option(name: .customLong("table"), help: "Genetic code table ID")
    var table: Int = 1

    @OptionGroup var output: OutputOptions

    /// The writer is plain FASTA with no gzip step, so `--compress` is refused before anything is written.
    func validate() throws {
        try output.rejectCompress(subcommand: "translate")
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "translate", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard (1...6).contains(frame) else {
            throw CLIError.conversionFailed(reason: "Frame must be 1-6.")
        }
        guard let codonTable = CodonTable.table(id: table) else {
            throw CLIError.conversionFailed(reason: "Unknown genetic code table ID \(table).")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        let readingFrame = Self.readingFrame(for: frame)
        let runClock = ProvenanceRunClock()
        // The layout is settled once, before any record is read (decision [9] part B, vote T2).
        let numbersMates = Self.numbersMates(of: resolvedInput)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        do {
            let reader = FASTQReader(validateSequence: false)
            // `mate` is the number the input record carries in its pair, or nil when it stands alone, so a
            // read with no protein is skipped without moving the number of its mate.
            func write(_ record: FASTQRecord, mate: Int?) throws {
                let translated = TranslationEngine.translateFrames(
                    [readingFrame],
                    sequence: record.sequence,
                    table: codonTable
                )
                guard let protein = translated.first?.1, !protein.isEmpty else { return }
                let mark = mate.map { ".\($0)" } ?? ""
                try Self.writeFASTARecord(
                    identifier: "\(record.identifier)\(mark)_frame\(readingFrame.rawValue)",
                    description: "[\(codonTable.name)] [\(protein.count) aa]",
                    sequence: protein,
                    to: handle
                )
            }
            var held: FASTQRecord?
            for try await record in reader.records(from: inputURL) {
                guard numbersMates else {
                    try write(record, mate: nil)
                    continue
                }
                if let first = held {
                    held = nil
                    if Self.areMates(first, record) {
                        try write(first, mate: 1)
                        try write(record, mate: 2)
                        continue
                    }
                    try write(first, mate: nil)
                }
                held = record
            }
            if let last = held {
                try write(last, mate: nil)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        var cliArguments = ["translate", resolvedInput.originalURL.path, "--frame", "\(frame)", "-o", output.output]
        if table != 1 {
            cliArguments += ["--table", "\(table)"]
        }
        if output.force {
            cliArguments.append("--force")
        }
        try await recordFASTQSwiftToolProvenance(
            workflowName: "lungfish fastq translate",
            cliArguments: cliArguments,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "frame": .integer(frame),
                "table": .integer(table),
                "force": .boolean(output.force)
            ],
            defaults: [
                "frame": .integer(1),
                "table": .integer(1),
                "force": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            outputFormat: .fasta,
            runClock: runClock
        )
        FileHandle.standardError.write(Data("Translated reads written to \(output.output)\n".utf8))
    }

    private static func readingFrame(for number: Int) -> ReadingFrame {
        switch number {
        case 1: return .plus1
        case 2: return .plus2
        case 3: return .plus3
        case 4: return .minus1
        case 5: return .minus2
        case 6: return .minus3
        default: return .plus1
        }
    }

    /// Whether the mates of this input take the marks `.1` and `.2`. The read-pairing contract's resolver
    /// settles the layout once, from the bundle's recorded pairing and a scan of the whole file, never a
    /// prefix of it. A mixed file recorded `single_end` and an input that records Oxford Nanopore or PacBio
    /// reads keep their ids, since neither is paired.
    private static func numbersMates(of input: FASTQSubcommandInput) -> Bool {
        let hints = FASTQReadLayoutClassifier.metadataHints(for: input.originalURL)
        if hints.pairingMode == .singleEnd, hints.hasMergedOrUnpairedReads { return false }
        if recordsLongReads(input) { return false }
        let resolution = FASTQInputLayoutResolver.resolve(
            fastqURL: input.executionURL,
            metadataFrom: input.bundleURL == nil ? nil : input.originalURL,
            recordLimit: Int.max
        )
        return resolution.layout == .strictlyInterleaved || resolution.layout == .mixedMergedAndPairs
    }

    /// Whether the input, or a bundle it derives from, records a long-read platform, read by the read set
    /// resolver's own lookup. Such reads are never paired (`docs/contracts/READ-PAIRING.md`).
    private static func recordsLongReads(_ input: FASTQSubcommandInput) -> Bool {
        FASTQLongReadRule.isLongRead(
            FASTQLongReadRule.recordedPlatform(of: (input.bundleURL ?? input.originalURL).standardizedFileURL)
        )
    }

    /// Two adjacent records are the mates of one fragment when their identifiers are byte-equal and the
    /// contract's pair rule reads their headers as read 1 followed by read 2.
    private static func areMates(_ first: FASTQRecord, _ second: FASTQRecord) -> Bool {
        first.identifier.utf8.elementsEqual(second.identifier.utf8)
            && FASTQReadLayoutClassifier.areMates(header(of: first), header(of: second))
    }

    private static func header(of record: FASTQRecord) -> String {
        record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
    }

    private static func writeFASTARecord(
        identifier: String,
        description: String,
        sequence: String,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data(">\(identifier) \(description)\n".utf8))
        var offset = 0
        while offset < sequence.count {
            let start = sequence.index(sequence.startIndex, offsetBy: offset)
            let end = sequence.index(start, offsetBy: min(70, sequence.count - offset))
            try handle.write(contentsOf: Data("\(sequence[start..<end])\n".utf8))
            offset += 70
        }
    }
}
