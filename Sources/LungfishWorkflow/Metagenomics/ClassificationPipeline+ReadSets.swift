// ClassificationPipeline+ReadSets.swift - How the Kraken2 pipeline shapes its read inputs for kraken2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ClassificationPipeline {

    /// Scratch directory (inside the run's output directory) holding the two
    /// mate files split from a strictly interleaved input for the kraken2 run.
    static let interleavedSplitDirectoryName = ".lungfish-interleaved-split"

    /// Re-checks a request to split one input as interleaved pairs against
    /// the records, through the shared layout resolver.
    ///
    /// kraken2 pairs the split halves by position, so only a strictly
    /// interleaved file may be split. When the file mixes merged reads with
    /// pairs, or holds no adjacent mates at all, the returned config runs
    /// the file unpaired and `warning` says why. A config that did not ask
    /// for interleaved handling is returned unchanged with no warning.
    static func reconcileInterleavedRequest(
        _ config: ClassificationConfig
    ) -> (config: ClassificationConfig, resolution: FASTQInputLayoutResolution?, warning: String?) {
        guard config.interleavedInput, config.inputFiles.count == 1, let source = config.inputFiles.first else {
            return (config, nil, nil)
        }
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [source])
        guard resolution.layout != .strictlyInterleaved else {
            return (config, resolution, nil)
        }
        var adjusted = config
        adjusted.interleavedInput = false
        adjusted.isPairedEnd = false
        adjusted.inputLayout = resolution.classification ?? config.inputLayout
        let warning = "\(source.lastPathComponent) was requested as interleaved pairs, but \(resolution.reason) "
            + "kraken2 pairs split halves by position, so the reads run as single-end instead."
        return (adjusted, resolution, warning)
    }

    /// Splits a strictly interleaved FASTQ into `<stem>_R1.fastq` and
    /// `<stem>_R2.fastq` under `directory`, replacing any earlier split.
    ///
    /// The halves are plain FASTQ (kraken2 reads them directly) and live only
    /// for the kraken2 step; `runPipeline` removes the directory afterwards.
    static func splitInterleavedInput(
        _ source: URL,
        into directory: URL
    ) async throws -> (r1: URL, r2: URL, counts: FASTQPairInterleaver.Counts) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var stem = source.lastPathComponent
        for suffix in [".gz", ".fastq", ".fq"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        let r1 = directory.appendingPathComponent("\(stem)_R1.fastq")
        let r2 = directory.appendingPathComponent("\(stem)_R2.fastq")

        let worker = Task.detached(priority: .utility) { () throws -> FASTQPairInterleaver.Counts in
            let fm = FileManager.default
            fm.createFile(atPath: r1.path, contents: nil)
            fm.createFile(atPath: r2.path, contents: nil)
            guard let handle1 = FileHandle(forWritingAtPath: r1.path),
                  let handle2 = FileHandle(forWritingAtPath: r2.path) else {
                throw ClassificationPipelineError.interleavedSplitFailed(
                    "cannot open mate files for writing in \(directory.path)"
                )
            }
            defer {
                try? handle1.close()
                try? handle2.close()
            }
            return try FASTQPairInterleaver.deinterleave(interleaved: source, r1: handle1, r2: handle2)
        }
        do {
            let counts = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return (r1, r2, counts)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
}

// MARK: - Kraken2 Progress Parsing

/// Parses a Kraken2 stderr progress line and reports it via the progress callback.
///
/// Kraken2 writes lines like:
/// ```
///   12345 sequences (1.2 Mbp) processed
/// ```
///
/// This function extracts the sequence count and reports it in the 0.30--0.80
/// progress range used by the classification pipeline. Since we don't know the
/// total sequence count upfront, we use the count itself as an informational
/// message without computing a fraction.
///
/// - Parameters:
///   - line: A single line from kraken2's stderr output.
///   - progress: The pipeline's progress callback.
func parseKraken2ProgressLine(
    _ line: String,
    progress: @Sendable (Double, String) -> Void
) {
    // Match lines like "  12345 sequences (1.2 Mbp) processed"
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("sequences") && trimmed.contains("processed") else { return }

    // Extract the sequence count (first number in the line)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard let countStr = parts.first, let count = Int(countStr) else { return }

    // Report in the kraken2 execution progress range (0.30 -- 0.80).
    // We can't compute a true fraction since we don't know total reads,
    // so report a fixed 0.50 progress with a descriptive message.
    let formattedCount: String
    if count >= 1_000_000 {
        formattedCount = String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        formattedCount = String(format: "%.1fK", Double(count) / 1_000)
    } else {
        formattedCount = String(count)
    }

    progress(0.50, "Classifying: \(formattedCount) sequences processed...")
}
