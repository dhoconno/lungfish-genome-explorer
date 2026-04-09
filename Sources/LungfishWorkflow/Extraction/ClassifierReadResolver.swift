// ClassifierReadResolver.swift — Unified classifier read extraction actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(
    subsystem: "com.lungfish.workflow",
    category: "ClassifierReadResolver"
)

// MARK: - ClassifierReadResolver

/// Unified extraction actor that takes a tool + row selection + destination
/// and produces an ``ExtractionOutcome``.
///
/// The resolver is the single point through which all classifier read
/// extraction must pass. It replaces four prior parallel implementations
/// (EsViritu / TaxTriage / NAO-MGS hand-rolled `extractByBAMRegion` callers,
/// Kraken2 `TaxonomyExtractionSheet` wizard) so that:
///
/// 1. A single samtools flag filter (`-F 0x404` by default) matches the
///    `MarkdupService.countReads` "Unique Reads" figure shown in the UI.
/// 2. Changes to the extraction pipeline have exactly one place to land.
/// 3. The CLI `--by-classifier` strategy and the GUI extraction dialog share
///    the same backend byte-for-byte (see `ClassifierCLIRoundTripTests`).
///
/// ## Dispatch
///
/// The public API takes a `ClassifierTool` and branches on `usesBAMDispatch`:
///
/// - BAM-backed tools (EsViritu, TaxTriage, NAO-MGS, NVD) run
///   `samtools view -F <flags> -b <bam> <regions...>` to a temp BAM, then
///   `samtools fastq` to a per-sample FASTQ, and concatenate per-sample
///   outputs before routing to the destination.
/// - Kraken2 wraps the existing `TaxonomyExtractionPipeline.extract` with
///   `includeChildren: true` always, then routes its output to the destination.
///
/// ## Thread safety
///
/// `ClassifierReadResolver` is an actor — all method calls are serialised.
public actor ClassifierReadResolver {

    // MARK: - Properties

    private let toolRunner: NativeToolRunner

    // MARK: - Initialization

    /// Creates a resolver using the shared native tool runner.
    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    // MARK: - Static helpers

    /// Walks up from `resultPath` to find the enclosing `.lungfish/` project root.
    ///
    /// If no `.lungfish/` marker is found in any ancestor directory, falls back
    /// to the result path's parent directory. This means callers always get
    /// back *some* writable directory — never `nil`.
    ///
    /// - Parameter resultPath: A file or directory URL inside a Lungfish project.
    /// - Returns: The `.lungfish/`-containing project root, or `resultPath`'s parent on fallback.
    public static func resolveProjectRoot(from resultPath: URL) -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: resultPath.path, isDirectory: &isDirectory)

        // Start from the directory containing resultPath (unless resultPath is a directory).
        var current: URL
        if exists && isDirectory.boolValue {
            current = resultPath.standardizedFileURL
        } else {
            current = resultPath.deletingLastPathComponent().standardizedFileURL
        }

        let fallback = current

        // Walk up until we find .lungfish/ or hit the filesystem root.
        while current.path != "/" {
            let marker = current.appendingPathComponent(".lungfish")
            if fm.fileExists(atPath: marker.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }  // can't go higher
            current = parent
        }

        return fallback
    }

    // MARK: - Public API (stubs — filled in later tasks)

    /// Runs an extraction and routes the result to the requested destination.
    ///
    /// Implemented in Task 2.3 and later. The stub throws so no caller can
    /// reach production code yet.
    public func resolveAndExtract(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions,
        destination: ExtractionDestination,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionOutcome {
        throw ClassifierExtractionError.notImplemented
    }

    /// Cheap pre-flight count. Implemented in Task 2.2.
    public func estimateReadCount(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions
    ) async throws -> Int {
        throw ClassifierExtractionError.notImplemented
    }
}

// MARK: - ClassifierExtractionError

/// Errors produced by `ClassifierReadResolver`.
///
/// Distinct from the lower-level `ExtractionError` so callers can differentiate
/// resolver-scoped failures (BAM-not-found-for-sample, missing Kraken2 output,
/// etc.) from primitive samtools/seqkit failures.
public enum ClassifierExtractionError: Error, LocalizedError, Sendable {

    /// The resolver method is not yet implemented (build-time stub).
    case notImplemented

    /// No BAM file could be found for the given sample ID.
    case bamNotFound(sampleId: String)

    /// The Kraken2 per-read classified output file was missing or unreadable.
    case kraken2OutputMissing(URL)

    /// The Kraken2 taxonomy tree could not be loaded from disk.
    case kraken2TreeMissing(URL)

    /// The Kraken2 source FASTQ could not be located on disk.
    case kraken2SourceMissing

    /// A per-sample samtools invocation failed.
    case samtoolsFailed(sampleId: String, stderr: String)

    /// An extracted clipboard payload exceeded the requested cap.
    case clipboardCapExceeded(requested: Int, cap: Int)

    /// Destination directory not writable.
    case destinationNotWritable(URL)

    /// FASTQ → FASTA conversion failed while reading an input record.
    case fastaConversionFailed(String)

    /// Zero reads were extracted despite a non-empty pre-flight estimate.
    case zeroReadsExtracted

    /// The underlying extraction was cancelled.
    case cancelled

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "ClassifierReadResolver path is not yet implemented"
        case .bamNotFound(let sampleId):
            return "No BAM file found for sample '\(sampleId)'. The classifier result may be corrupted or imported without the underlying alignment data."
        case .kraken2OutputMissing(let url):
            return "Kraken2 per-read classification output not found: \(url.lastPathComponent)"
        case .kraken2TreeMissing(let url):
            return "Kraken2 taxonomy tree not found: \(url.lastPathComponent)"
        case .kraken2SourceMissing:
            return "Kraken2 source FASTQ could not be located. The source file may have been moved or deleted."
        case .samtoolsFailed(let sampleId, let stderr):
            return "samtools view failed for sample '\(sampleId)': \(stderr)"
        case .clipboardCapExceeded(let requested, let cap):
            return "Selection contains \(requested) reads, which exceeds the clipboard cap of \(cap). Choose Save to File, Save as Bundle, or Share instead."
        case .destinationNotWritable(let url):
            return "Destination is not writable: \(url.path)"
        case .fastaConversionFailed(let reason):
            return "FASTQ → FASTA conversion failed: \(reason)"
        case .zeroReadsExtracted:
            return "The selection produced zero reads. Try adjusting the flag filter or selecting different rows."
        case .cancelled:
            return "Extraction was cancelled"
        }
    }
}
