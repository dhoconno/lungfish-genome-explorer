// BAMToFASTQConverter.swift — Shared BAM→FASTQ conversion helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(
    subsystem: "com.lungfish.workflow",
    category: "BAMToFASTQConverter"
)

// MARK: - Error

/// A reason the shared BAM→FASTQ converter failed. Callers map this to their
/// own error domain (`ExtractionError`, `ClassifierExtractionError`, …).
public enum BAMToFASTQConversionError: Error {
    /// A samtools invocation exited non-zero. The captured stderr is attached.
    case samtoolsFailed(stderr: String)
    /// All sidecar outputs were empty and the caller disallowed stdout fallback.
    case emptySidecarOutputs
}

// MARK: - convertBAMToSingleFASTQ

/// Converts a BAM file into a single FASTQ by collecting every read class
/// (READ1, READ2, READ_OTHER, singletons).
///
/// `samtools fastq -o` only writes READ1/READ2, silently dropping READ_OTHER
/// singletons. `samtools fastq -0` only writes READ_OTHER, silently dropping
/// READ1/READ2. Both modes have historically caused silent data loss, so this
/// converter routes all four read classes to separate sidecar files (`-0/-1/-2/-s`)
/// and concatenates them into a single output FASTQ.
///
/// If the sidecar outputs are all empty (rare but observed on oddball single-end
/// BAMs), the converter retries with a plain `samtools fastq` stdout capture and
/// writes the stdout string as UTF-8. ASCII-only FASTQ quality scores make this
/// safe in practice, but the UTF-8 decode round-trip is a latent memory-pressure
/// concern for very large outputs — tracked separately as a shared refactor.
///
/// - Parameters:
///   - inputBAM: BAM file to read from. Must already be filtered/sorted as the
///               caller requires — this helper does not apply any additional
///               flag filtering via `samtools view`.
///   - outputFASTQ: Destination FASTQ path. Overwritten if it exists.
///   - tempDir: Temp directory in which to place the four sidecar files. Must
///              be writable. Caller owns cleanup of `tempDir`.
///   - sidecarPrefix: Stem used for the four sidecar filenames
///                    (`<prefix>_other.fastq`, `<prefix>_r1.fastq`,
///                    `<prefix>_r2.fastq`, `<prefix>_singletons.fastq`).
///                    Must be unique per concurrent call within a shared `tempDir`.
///   - flagFilter: Value to pass to `samtools fastq -F`. `samtools fastq`'s
///                 built-in default is `0x900` (exclude secondary +
///                 supplementary); pass `0x900` to preserve that behavior, or
///                 a caller-specific mask (e.g. `0x404`) to align the FASTQ
///                 output with a matching `samtools view -c -F <flags>` count.
///                 User-supplied `-F` REPLACES the default — it does not OR
///                 with `0x900`.
///   - timeout: Timeout for each `samtools` invocation, in seconds.
///   - toolRunner: Actor used to run the samtools subprocess. The caller must
///                 already have a reference to the shared runner.
/// - Throws: ``BAMToFASTQConversionError/samtoolsFailed(stderr:)`` if either
///           samtools invocation exits non-zero, plus any `FileHandle` /
///           `FileManager` errors from the merge step.
///
/// This helper is shared by ``ReadExtractionService/convertBAMToFASTQSingleFile``
/// and ``ClassifierReadResolver``; do not duplicate the 4-file-split logic elsewhere.
public func convertBAMToSingleFASTQ(
    inputBAM: URL,
    outputFASTQ: URL,
    tempDir: URL,
    sidecarPrefix: String,
    flagFilter: Int,
    timeout: TimeInterval,
    toolRunner: NativeToolRunner,
    allowStdoutFallback: Bool = true
) async throws {
    let fm = FileManager.default

    let otherURL = tempDir.appendingPathComponent("\(sidecarPrefix)_other.fastq")
    let r1URL = tempDir.appendingPathComponent("\(sidecarPrefix)_r1.fastq")
    let r2URL = tempDir.appendingPathComponent("\(sidecarPrefix)_r2.fastq")
    let singletonURL = tempDir.appendingPathComponent("\(sidecarPrefix)_singletons.fastq")

    let fastqResult = try await toolRunner.run(
        .samtools,
        arguments: [
            "fastq",
            "-F", String(flagFilter),
            "-0", otherURL.path,
            "-1", r1URL.path,
            "-2", r2URL.path,
            "-s", singletonURL.path,
            inputBAM.path,
        ],
        timeout: timeout
    )
    guard fastqResult.isSuccess else {
        throw BAMToFASTQConversionError.samtoolsFailed(stderr: fastqResult.stderr)
    }

    if fm.fileExists(atPath: outputFASTQ.path) {
        try fm.removeItem(at: outputFASTQ)
    }
    fm.createFile(atPath: outputFASTQ.path, contents: nil)

    let outHandle = try FileHandle(forWritingTo: outputFASTQ)
    defer { try? outHandle.close() }

    // Order matches the historical ReadExtractionService implementation:
    // singletons + READ_OTHER first, then the paired R1/R2 stream.
    let orderedParts = [otherURL, singletonURL, r1URL, r2URL]
    for partURL in orderedParts {
        guard fm.fileExists(atPath: partURL.path) else { continue }
        let attrs = try fm.attributesOfItem(atPath: partURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        guard size > 0 else { continue }

        let inHandle = try FileHandle(forReadingFrom: partURL)
        defer { try? inHandle.close() }

        while true {
            let chunk = inHandle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            outHandle.write(chunk)
        }
    }

    let mergedSize = (try? fm.attributesOfItem(atPath: outputFASTQ.path)[.size] as? UInt64) ?? 0
    if mergedSize == 0 {
        guard allowStdoutFallback else {
            throw BAMToFASTQConversionError.emptySidecarOutputs
        }
        // Sidecar outputs were all empty — retry capturing stdout. This covers
        // oddball BAMs (e.g. single-end with unusual flag patterns) that produce
        // reads on stdout but nothing into the named sidecars.
        logger.warning("samtools fastq sidecar outputs were empty; retrying via stdout capture")
        let stdoutResult = try await toolRunner.run(
            .samtools,
            arguments: ["fastq", "-F", String(flagFilter), inputBAM.path],
            timeout: timeout
        )
        guard stdoutResult.isSuccess else {
            throw BAMToFASTQConversionError.samtoolsFailed(stderr: stdoutResult.stderr)
        }
        // ASCII-only FASTQ quality scores make this UTF-8 round-trip safe in
        // practice, but the latent concern is shared with other callers that
        // buffer stdout as String; tracked separately.
        try stdoutResult.stdout.write(to: outputFASTQ, atomically: true, encoding: .utf8)
    }
}
