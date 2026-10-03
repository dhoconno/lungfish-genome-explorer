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
        abstract: "Translate FASTQ reads to protein FASTA"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("frame"), help: "Reading frame: 1-3 forward, 4-6 reverse (default: 1)")
    var frame: Int = 1

    @Option(name: .customLong("table"), help: "Genetic code table ID (default: 1)")
    var table: Int = 1

    @OptionGroup var output: OutputOptions

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
        let startedAt = Date()

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        do {
            let reader = FASTQReader(validateSequence: false)
            for try await record in reader.records(from: inputURL) {
                let translated = TranslationEngine.translateFrames(
                    [readingFrame],
                    sequence: record.sequence,
                    table: codonTable
                )
                guard let protein = translated.first?.1, !protein.isEmpty else { continue }
                try Self.writeFASTARecord(
                    identifier: "\(record.identifier)_frame\(readingFrame.rawValue)",
                    description: "[\(codonTable.name)] [\(protein.count) aa]",
                    sequence: protein,
                    to: handle
                )
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
        if output.compress {
            cliArguments.append("--compress")
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
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "frame": .integer(1),
                "table": .integer(1),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            outputFormat: .fasta,
            startedAt: startedAt
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
