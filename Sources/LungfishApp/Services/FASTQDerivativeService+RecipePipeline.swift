// FASTQDerivativeService+RecipePipeline.swift - Materialized recipe pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Materialized Recipe Pipeline

    /// Runs recipe steps directly on materialized FASTQ files, chaining tool outputs.
    ///
    /// Unlike the virtual derivative chain, this pipeline:
    /// - Writes real FASTQ files at every step
    /// - Correctly handles paired-end merge (outputs can be longer than inputs)
    /// - Passes properly de-interleaved R1/R2 to fastp for adapter/quality trim
    /// - Returns the URL of the final processed FASTQ in `tempDir`
    ///
    /// - Parameters:
    ///   - fastqURL: Uncompressed FASTQ to process (usually decompressed bundle content).
    ///   - steps: Ordered recipe steps to apply.
    ///   - isInterleaved: Whether the input is interleaved paired-end.
    ///   - tempDir: Scratch directory for intermediate files.
    ///   - measureReadCounts: When true, gathers per-step input/output read counts via seqkit stats.
    ///     Disable for ingestion hot paths to avoid extra full-file scans per step.
    ///   - progress: Optional callback (fraction 0–1, message).
    func runMaterializedRecipe(
        fastqURL: URL,
        steps: [FASTQDerivativeOperation],
        isInterleaved: Bool,
        tempDir: URL,
        measureReadCounts: Bool = true,
        progress: ((Double, String) -> Void)?
    ) async throws -> (url: URL, stepResults: [RecipeStepResult]) {
        var currentURL = fastqURL
        var currentIsInterleaved = isInterleaved
        let fm = FileManager.default
        var stepResults: [RecipeStepResult] = []

        for (index, step) in steps.enumerated() {
            let fraction = Double(index) / Double(steps.count)
            let outputURL = tempDir.appendingPathComponent("step_\(index + 1)_\(step.kind.rawValue).fastq")
            let inputCount = measureReadCounts
                ? await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                : nil
            let stepStart = Date()
            var commandLine: String?

            switch step.kind {
            case .fastpTrim:
                progress?(fraction, "Adapter and quality trimming (\(index + 1)/\(steps.count))...")
                commandLine = "fastp (adapter+quality-trim) threshold=\(step.qualityThreshold ?? 20) window=\(step.windowSize ?? 4) mode=\((step.qualityTrimMode ?? .cutRight).rawValue) adapter=\((step.adapterMode ?? .autoDetect).rawValue) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpCombinedTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    threshold: step.qualityThreshold ?? 20,
                    windowSize: step.windowSize ?? 4,
                    mode: step.qualityTrimMode ?? .cutRight,
                    adapterMode: step.adapterMode ?? .autoDetect,
                    adapterSequence: step.adapterSequence,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .qualityTrim:
                progress?(fraction, "Quality trimming (\(index + 1)/\(steps.count))...")
                commandLine = "fastp (quality-trim) threshold=\(step.qualityThreshold ?? 20) window=\(step.windowSize ?? 4) mode=\((step.qualityTrimMode ?? .cutRight).rawValue) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpQualityTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    threshold: step.qualityThreshold ?? 20,
                    windowSize: step.windowSize ?? 4,
                    mode: step.qualityTrimMode ?? .cutRight,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .adapterTrim:
                progress?(fraction, "Adapter trimming (\(index + 1)/\(steps.count))…")
                commandLine = "fastp (adapter-trim) mode=\((step.adapterMode ?? .autoDetect).rawValue) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpAdapterTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    mode: step.adapterMode ?? .autoDetect,
                    sequence: step.adapterSequence,
                    sequenceR2: step.adapterSequenceR2,
                    fastaFilename: step.adapterFastaFilename,
                    sourceBundleURL: tempDir,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .fixedTrim:
                progress?(fraction, "Fixed trimming (\(index + 1)/\(steps.count))…")
                commandLine = "fastp (fixed-trim) trim5=\(step.trimFrom5Prime ?? 0) trim3=\(step.trimFrom3Prime ?? 0) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpFixedTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    from5Prime: step.trimFrom5Prime ?? 0,
                    from3Prime: step.trimFrom3Prime ?? 0,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .deduplicate:
                progress?(fraction, "Deduplicating (\(index + 1)/\(steps.count))…")
                let subs = step.deduplicateSubstitutions ?? 0
                let optical = step.deduplicateOptical ?? false
                let opticalDist = step.deduplicateOpticalDistance ?? 2500
                commandLine = "clumpify.sh dedupe=t subs=\(subs)\(optical ? " optical=t dupedist=\(opticalDist)" : "") interleaved=\(currentIsInterleaved)"
                let env = await bbToolsEnvironment()
                let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                let heapGB = max(1, min(31, physicalMemoryGB * 80 / 100))
                var args = [
                    "in=\(currentURL.path)",
                    "out=\(outputURL.path)",
                    "-Xmx\(heapGB)g",
                    "dedupe=t",
                    "subs=\(subs)",
                    "ow=t",
                ]
                if currentIsInterleaved { args.append("interleaved=t") }
                if optical {
                    args.append("optical=t")
                    args.append("dupedist=\(opticalDist)")
                }
                let dedupeResult = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
                guard dedupeResult.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("clumpify deduplication failed: \(dedupeResult.stderr)")
                }
                currentURL = outputURL

            case .pairedEndMerge:
                progress?(fraction, "Merging paired-end reads (\(index + 1)/\(steps.count))…")
                let strictness = step.mergeStrictness ?? .normal
                let minOverlap = step.mergeMinOverlap ?? 12
                commandLine = "bbmerge.sh strictness=\(strictness.rawValue) minoverlap=\(minOverlap); reformat.sh (unmerged interleave)"
                let mergeDir = tempDir.appendingPathComponent("step_\(index + 1)_merge")
                try fm.createDirectory(at: mergeDir, withIntermediateDirectories: true)

                // bbmerge writes: merged.fastq, unmerged_R1.fastq, unmerged_R2.fastq
                let (_, _) = try await runBBMerge(
                    sourceFASTQ: currentURL,
                    outputBundleURL: mergeDir,
                    strictness: strictness,
                    minOverlap: minOverlap
                )

                // Build output: merged reads + re-interleaved unmerged pairs
                let mergedFile = mergeDir.appendingPathComponent("merged.fastq")
                let unmergedR1 = mergeDir.appendingPathComponent("unmerged_R1.fastq")
                let unmergedR2 = mergeDir.appendingPathComponent("unmerged_R2.fastq")

                // Re-interleave unmerged pairs using reformat.sh
                let unmergedInterleaved = mergeDir.appendingPathComponent("unmerged_interleaved.fastq")
                let hasMerged = fm.fileExists(atPath: mergedFile.path)
                let hasUnmerged = fm.fileExists(atPath: unmergedR1.path) && fm.fileExists(atPath: unmergedR2.path)

                if hasUnmerged {
                    try await reinterleaveFastpOutput(r1: unmergedR1, r2: unmergedR2, output: unmergedInterleaved)
                }

                // Concatenate parts: merged (singles) + unmerged (interleaved pairs)
                var parts: [URL] = []
                if hasMerged { parts.append(mergedFile) }
                if hasUnmerged { parts.append(unmergedInterleaved) }
                guard !parts.isEmpty else {
                    throw FASTQDerivativeError.emptyResult
                }
                try concatenateFASTQParts(parts, to: outputURL)

                currentURL = outputURL
                // Post-merge: data is mixed (merged singles + interleaved unmerged pairs).
                // Downstream pair-aware tools (bbduk length filter) handle this mixed format
                // correctly with interleaved=t.
                currentIsInterleaved = true

            case .lengthFilter:
                progress?(fraction, "Length filtering (\(index + 1)/\(steps.count))…")
                if currentIsInterleaved {
                    commandLine = "bbduk.sh interleaved=t minlen=\(step.minLength.map(String.init) ?? "none") maxlen=\(step.maxLength.map(String.init) ?? "none")"
                    try await runPairedAwareFilter(
                        sourceFASTQ: currentURL,
                        outputFASTQ: outputURL,
                        minLength: step.minLength,
                        maxLength: step.maxLength
                    )
                } else {
                    commandLine = "seqkit seq -m \(step.minLength.map(String.init) ?? "none") -M \(step.maxLength.map(String.init) ?? "none")"
                    var seqkitArgs = ["seq", "-j", String(toolThreadCount), currentURL.path, "-o", outputURL.path]
                    if let min = step.minLength { seqkitArgs += ["-m", String(min)] }
                    if let max = step.maxLength { seqkitArgs += ["-M", String(max)] }
                    let seqkitResult = try await runner.run(.seqkit, arguments: seqkitArgs)
                    guard seqkitResult.isSuccess else {
                        throw FASTQDerivativeError.invalidOperation("seqkit length filter failed: \(seqkitResult.stderr)")
                    }
                }
                currentURL = outputURL

            case .humanReadScrub:
                progress?(fraction, "Removing human reads (\(index + 1)/\(steps.count))…")
                let dbID = step.humanScrubDatabaseID ?? DeaconPanhumanDatabaseInstaller.databaseID
                let resolvedDBID = Self.canonicalHumanScrubDatabaseID(for: dbID)
                commandLine = currentIsInterleaved
                    ? "deacon filter -d \(resolvedDBID) <R1> <R2> -o <R1.out> -O <R2.out> -t \(toolThreadCount)"
                    : "deacon filter -d \(resolvedDBID) <input> -o <output> -t \(toolThreadCount)"
                try await runDeaconHumanReadScrub(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    databaseID: resolvedDBID,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

                let outputCount = measureReadCounts
                    ? await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                    : nil
                let duration = Date().timeIntervalSince(stepStart)
                stepResults.append(RecipeStepResult(
                    stepName: step.displaySummary,
                    tool: "deacon",
                    toolVersion: step.toolVersion,
                    commandLine: commandLine,
                    inputReadCount: inputCount,
                    outputReadCount: outputCount,
                    durationSeconds: duration
                ))
                continue  // skip the generic result append at the bottom of the loop

            default:
                derivativeLogger.warning("runMaterializedRecipe: Skipping unsupported step '\(step.kind.rawValue)'")
            }

            // Record per-step stats
            let outputCount = measureReadCounts
                ? await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                : nil
            let duration = Date().timeIntervalSince(stepStart)
            stepResults.append(RecipeStepResult(
                stepName: step.displaySummary,
                tool: step.toolUsed ?? step.kind.rawValue,
                toolVersion: step.toolVersion,
                commandLine: commandLine,
                inputReadCount: inputCount,
                outputReadCount: outputCount,
                durationSeconds: duration
            ))
        }

        return (currentURL, stepResults)
    }

    /// Concatenates FASTQ parts into one output file without loading full files into memory.
    func concatenateFASTQParts(_ inputs: [URL], to output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw FASTQDerivativeError.invalidOperation("Failed to create merged FASTQ output at \(output.path)")
        }

        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }

        for input in inputs {
            let inputHandle = try FileHandle(forReadingFrom: input)
            defer { try? inputHandle.close() }
            while true {
                let chunk = try inputHandle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try outputHandle.write(contentsOf: chunk)
            }
        }
    }

    /// Counts reads in a FASTQ file using seqkit stats.
    /// Returns nil if the file doesn't exist or seqkit fails.
    /// For interleaved files, returns the read pair count (total reads / 2).
    func countFASTQReads(at url: URL, isInterleaved: Bool) async -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try? await runner.run(.seqkit, arguments: ["stats", "-T", url.path])
        guard let result, result.isSuccess else { return nil }
        // seqkit stats -T output: file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: "\t")
        guard fields.count >= 4, let total = Int(fields[3]) else { return nil }
        return isInterleaved ? total / 2 : total
    }

}
