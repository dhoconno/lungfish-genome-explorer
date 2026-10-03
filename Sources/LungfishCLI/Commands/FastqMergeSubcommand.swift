// FastqMergeSubcommand.swift - Merge overlapping paired-end reads using bbmerge
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - PE Merge

struct FastqMergeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge overlapping paired-end reads using bbmerge"
    )

    @Argument(help: "Input interleaved FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("min-overlap"), help: "Minimum overlap (default: 12)")
    var minOverlap: Int = 12

    @Flag(name: .customLong("strict"), help: "Use strict merge mode")
    var strict: Bool = false

    @Flag(name: .customLong("count-duplicates"), help: "Collapse identical output sequences after merge and encode support as size=N")
    var countDuplicates: Bool = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "merge", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard minOverlap > 0 else { throw ValidationError("--min-overlap must be > 0") }
        let runner = NativeToolRunner.shared

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "bbmerge-",
            contextURL: URL(fileURLWithPath: output.output)
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mergedURL = tempDir.appendingPathComponent("merged.fastq")
        let unmergedURL = tempDir.appendingPathComponent("unmerged.fastq")

        // bbmerge interleaved=t pairs records by position, so only strictly
        // interleaved pairs reach it. A file that already mixes merged reads
        // with pairs (a merge recipe's output) is first split by NAME: the
        // pairs go to bbmerge and the merged reads pass through untouched.
        let resolution = FASTQInputLayoutResolver.resolve(fastqURL: inputURL, metadataFrom: resolvedInput.pairingMetadataURL)
        var bbmergeInputURL = inputURL
        var passthroughURL: URL?
        var passthroughReadCount = 0
        switch resolution.layout {
        case .strictlyInterleaved:
            break
        case .mixedMergedAndPairs:
            let partition = try IlluminaAmpliconPairMerger.partitionMixedInput(
                fastqURL: inputURL, workingDirectory: tempDir, stem: "input"
            )
            bbmergeInputURL = partition.pairsURL
            passthroughURL = partition.unpairedURL
            passthroughReadCount = partition.counts.unpaired
            FileHandle.standardError.write(Data(
                "Warning: \(inputURL.lastPathComponent) mixes merged reads with pairs (\(resolution.reason)) Merging the \(partition.counts.pairs) pairs; the \(partition.counts.unpaired) reads without a mate pass through unchanged.\n".utf8
            ))
        case .singleEnd, .pairedFiles:
            throw ValidationError("The input holds no interleaved pairs to merge (\(resolution.reason)) Nothing was written.")
        }

        var args = [
            "in=\(bbmergeInputURL.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedURL.path)",
            "minoverlap=\(minOverlap)",
            "interleaved=t",
        ]
        if strict { args.append("strict=t") }
        let outputSources = [mergedURL, unmergedURL] + (passthroughURL.map { [$0] } ?? [])

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "bbmerge failed: \(result.stderr)")
        }

        let outputURL = URL(fileURLWithPath: output.output)
        var countedResult: CountedFASTQMaterializationResult?
        var gzipResult: FASTQGzipProvenanceResult?
        var concatenateWallTime: TimeInterval = 0
        if countDuplicates {
            let countedInputs = outputSources.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if countedInputs.isEmpty {
                countedResult = try CountedFASTQMaterializer().write(
                    counts: [:],
                    outputURL: outputURL,
                    compress: output.compress,
                    inputRecordCount: 0,
                    totalReadCount: 0
                )
            } else {
                countedResult = try await CountedFASTQMaterializer().materialize(
                    inputs: countedInputs,
                    outputURL: outputURL,
                    compress: output.compress,
                    normalization: .uppercase
                )
            }
        } else {
            // Concatenate merged + unmerged.
            let concatenateStartedAt = Date()
            let concatenatedURL = output.compress
                ? tempDir.appendingPathComponent("merged-and-unmerged.fastq")
                : outputURL
            FileManager.default.createFile(atPath: concatenatedURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: concatenatedURL)
            for url in outputSources {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let inputHandle = try FileHandle(forReadingFrom: url)
                defer { try? inputHandle.close() }
                while true {
                    let chunk = inputHandle.readData(ofLength: 1_048_576)
                    if chunk.isEmpty { break }
                    outputHandle.write(chunk)
                }
            }
            try outputHandle.close()
            concatenateWallTime = Date().timeIntervalSince(concatenateStartedAt)
            if output.compress {
                gzipResult = try gzipCompress(
                    sourceURL: concatenatedURL,
                    outputURL: outputURL
                )
            }
        }
        var cliArguments = ["merge", resolvedInput.originalURL.path]
        if minOverlap != 12 {
            cliArguments += ["--min-overlap", String(minOverlap)]
        }
        if strict {
            cliArguments.append("--strict")
        }
        if countDuplicates {
            cliArguments.append("--count-duplicates")
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let countedOutputRecords: ParameterValue = countedResult
            .map { ParameterValue.integer($0.uniqueSequenceCount) } ?? .string("not counted")
        let countedOutputReadCount: ParameterValue = countedResult
            .map { ParameterValue.integer($0.totalReadCount) } ?? .string("not counted")
        let provenanceParameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "output": .file(outputURL),
            "minOverlap": .integer(minOverlap),
            "strict": .boolean(strict),
            "countDuplicatesAfterMerge": .boolean(countDuplicates),
            "duplicateCountEncoding": .string(countDuplicates ? "size=N" : "none"),
            "countedOutputRecords": countedOutputRecords,
            "countedOutputReadCount": countedOutputReadCount,
            "readLayout": .string(resolution.layout.rawValue),
            "readLayoutReason": .string(resolution.reason),
            "unpairedPassthroughReads": .integer(passthroughReadCount),
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        let provenanceDefaults: [String: ParameterValue] = [
            "minOverlap": .integer(12),
            "strict": .boolean(false),
            "readLayout": .string(FASTQInputLayout.strictlyInterleaved.rawValue),
            "unpairedPassthroughReads": .integer(0),
            "countDuplicatesAfterMerge": .boolean(false),
            "duplicateCountEncoding": .string("none"),
            "force": .boolean(false),
            "compress": .boolean(false)
        ]
        if countDuplicates {
            guard let countedResult else {
                throw CLIError.conversionFailed(reason: "Counted merge did not produce an output for provenance recording")
            }
            try await recordFASTQCountedMergeProvenance(
                cliArguments: cliArguments,
                nativeArguments: args,
                bbmergeResult: result,
                inputURL: resolvedInput.originalURL,
                bbmergeOutputURLs: [mergedURL, unmergedURL],
                countedResult: countedResult,
                finalOutputURL: outputURL,
                parameters: provenanceParameters,
                defaults: provenanceDefaults,
                inputRecords: try resolvedInput.inputRecords(),
                materializationSteps: try resolvedInput.materializationSteps(),
                startedAt: startedAt
            )
        } else {
            try await recordFASTQMergeProvenance(
                cliArguments: cliArguments,
                nativeArguments: args,
                bbmergeResult: result,
                gzipResult: gzipResult,
                inputURL: resolvedInput.originalURL,
                bbmergeOutputURLs: [mergedURL, unmergedURL],
                finalOutputURL: outputURL,
                parameters: provenanceParameters,
                defaults: provenanceDefaults,
                inputRecords: try resolvedInput.inputRecords(),
                materializationSteps: try resolvedInput.materializationSteps(),
                concatenateWallTime: concatenateWallTime,
                startedAt: startedAt
            )
        }

        FileHandle.standardError.write(Data("Merged reads written to \(output.output)\n".utf8))
    }

    private func gzipCompress(sourceURL: URL, outputURL: URL) throws -> FASTQGzipProvenanceResult {
        try gzipCompressFASTQ(
            sourceURL: sourceURL,
            outputURL: outputURL,
            failureDescription: "merged FASTQ"
        )
    }
}
