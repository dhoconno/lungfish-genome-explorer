// FastqScrubHumanSubcommand.swift - CLI subcommand to remove human reads from FASTQ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqScrubHumanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrub-human",
        abstract: "Remove human reads from FASTQ"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("database-id"), help: "Human read removal database identifier")
    var databaseID: String

    @Flag(
        name: .customLong("remove-reads"),
        help: "Deprecated compatibility flag; ignored because Deacon always removes matched reads"
    )
    var compatibilityRemoveReads: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()
        _ = compatibilityRemoveReads

        let runner = NativeToolRunner.shared
        let resolvedDatabaseID = Self.canonicalHumanReadRemovalDatabaseID(for: databaseID)
        let dbPath = try await DatabaseRegistry.shared.requiredDatabasePath(for: resolvedDatabaseID)
        let outputURL = URL(fileURLWithPath: output.output)
        let shouldCompressOutput = output.compress || outputURL.pathExtension.lowercased() == "gz"
        let workspace = outputURL.deletingLastPathComponent()
        let threads = ProcessInfo.processInfo.activeProcessorCount

        var decompressedInput: URL? = nil
        let scrubInputURL: URL
        if inputURL.pathExtension.lowercased() == "gz" {
            let tmp = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString).fastq")
            let pigzResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: ["-d", "-c", inputURL.path],
                outputFile: tmp
            )
            guard pigzResult.isSuccess else {
                throw CLIError.conversionFailed(reason: "Failed to decompress input for deacon: \(pigzResult.stderr)")
            }
            scrubInputURL = tmp
            decompressedInput = tmp
        } else {
            scrubInputURL = inputURL
        }
        defer {
            if let decompressedInput {
                try? FileManager.default.removeItem(at: decompressedInput)
            }
        }

        let plainOutputURL = workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: plainOutputURL) }

        if try await Self.looksInterleavedFASTQ(at: scrubInputURL) {
            let inputR1 = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString)-R1.fastq")
            let inputR2 = workspace.appendingPathComponent("scrub-human-input-\(UUID().uuidString)-R2.fastq")
            let outputR1 = workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString)-R1.fastq")
            let outputR2 = workspace.appendingPathComponent("scrub-human-output-\(UUID().uuidString)-R2.fastq")
            defer {
                try? FileManager.default.removeItem(at: inputR1)
                try? FileManager.default.removeItem(at: inputR2)
                try? FileManager.default.removeItem(at: outputR1)
                try? FileManager.default.removeItem(at: outputR2)
            }

            try await Self.deinterleaveFASTQ(
                inputFASTQ: scrubInputURL,
                outputR1: inputR1,
                outputR2: inputR2,
                runner: runner
            )
            try await Self.runDeaconFilter(
                inputR1: inputR1,
                inputR2: inputR2,
                outputR1: outputR1,
                outputR2: outputR2,
                databasePath: dbPath,
                threads: threads,
                runner: runner
            )
            try await Self.interleaveFASTQ(
                inputR1: outputR1,
                inputR2: outputR2,
                outputFASTQ: plainOutputURL,
                runner: runner
            )
        } else {
            try await Self.runDeaconFilter(
                inputFASTQ: scrubInputURL,
                outputFASTQ: plainOutputURL,
                databasePath: dbPath,
                threads: threads,
                runner: runner
            )
        }

        if shouldCompressOutput {
            let compressionResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: ["-p", "\(threads)", "-c", plainOutputURL.path],
                outputFile: outputURL
            )
            guard compressionResult.isSuccess else {
                throw CLIError.conversionFailed(reason: "Compression after deacon failed: \(compressionResult.stderr)")
            }
        } else {
            try FileManager.default.moveItem(at: plainOutputURL, to: outputURL)
        }
    }
}

extension FastqScrubHumanSubcommand {
    static func canonicalHumanReadRemovalDatabaseID(for requestedID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: requestedID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }
}

private extension FastqScrubHumanSubcommand {
    static func looksInterleavedFASTQ(at url: URL) async throws -> Bool {
        let reader = FASTQReader(validateSequence: false)
        var iterator = reader.records(from: url).makeAsyncIterator()
        guard let first = try await iterator.next(),
              let second = try await iterator.next(),
              let firstPair = first.readPair,
              let secondPair = second.readPair else {
            return false
        }
        return firstPair.pairId == secondPair.pairId
            && firstPair.readNumber == 1
            && secondPair.readNumber == 2
    }

    static func deinterleaveFASTQ(
        inputFASTQ: URL,
        outputR1: URL,
        outputR2: URL,
        runner: NativeToolRunner
    ) async throws {
        let env = await bbToolsEnvironment(runner: runner)
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in=\(inputFASTQ.path)",
                "out1=\(outputR1.path)",
                "out2=\(outputR2.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh deinterleave failed: \(result.stderr)")
        }
    }

    static func interleaveFASTQ(
        inputR1: URL,
        inputR2: URL,
        outputFASTQ: URL,
        runner: NativeToolRunner
    ) async throws {
        let env = await bbToolsEnvironment(runner: runner)
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(inputR1.path)",
                "in2=\(inputR2.path)",
                "out=\(outputFASTQ.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "reformat.sh interleave failed: \(result.stderr)")
        }
    }

    static func runDeaconFilter(
        inputFASTQ: URL,
        outputFASTQ: URL,
        databasePath: URL,
        threads: Int,
        runner: NativeToolRunner
    ) async throws {
        let result = try await runner.run(
            .deacon,
            arguments: [
                "filter",
                "-d", databasePath.path,
                inputFASTQ.path,
                "-o", outputFASTQ.path,
                "-t", "\(threads)",
            ],
            timeout: 7200
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "deacon filter failed: \(result.stderr)")
        }
    }

    static func runDeaconFilter(
        inputR1: URL,
        inputR2: URL,
        outputR1: URL,
        outputR2: URL,
        databasePath: URL,
        threads: Int,
        runner: NativeToolRunner
    ) async throws {
        let result = try await runner.run(
            .deacon,
            arguments: [
                "filter",
                "-d", databasePath.path,
                inputR1.path,
                inputR2.path,
                "-o", outputR1.path,
                "-O", outputR2.path,
                "-t", "\(threads)",
            ],
            timeout: 7200
        )
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "deacon filter failed: \(result.stderr)")
        }
    }
}
