// TaxonomyExtractionConfig.swift - Configuration for extracting reads by taxonomic classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxonomyExtractionConfig

/// Configuration for extracting reads classified to specific taxa from FASTQ file(s).
///
/// An extraction selects reads from one or more classified FASTQs based on their
/// Kraken2 per-read taxonomy assignments. When ``includeChildren`` is `true`, all
/// descendant tax IDs from the target nodes are included in the filter.
///
/// ## Single-End Usage
///
/// ```swift
/// let config = TaxonomyExtractionConfig(
///     taxIds: [562],
///     includeChildren: true,
///     sourceFile: inputFASTQ,
///     outputFile: outputFASTQ,
///     classificationOutput: krakenOutputURL
/// )
/// ```
///
/// ## Paired-End Usage
///
/// ```swift
/// let config = TaxonomyExtractionConfig(
///     taxIds: [562],
///     includeChildren: true,
///     sourceFiles: [r1FASTQ, r2FASTQ],
///     outputFiles: [r1Output, r2Output],
///     classificationOutput: krakenOutputURL
/// )
/// ```
///
/// ## Thread Safety
///
/// `TaxonomyExtractionConfig` is a value type conforming to `Sendable`, safe
/// to pass across isolation boundaries.
public struct TaxonomyExtractionConfig: Sendable, Equatable {

    /// The set of NCBI taxonomy IDs to extract reads for.
    ///
    /// These are the directly selected taxa. If ``includeChildren`` is `true`,
    /// the extraction pipeline will also collect all descendant tax IDs from
    /// the taxonomy tree before filtering.
    public let taxIds: Set<Int>

    /// Whether to include reads classified to descendant taxa.
    ///
    /// When `true`, the pipeline traverses the taxonomy tree to collect all
    /// child tax IDs for each entry in ``taxIds``, creating a comprehensive
    /// clade-level extraction.
    public let includeChildren: Bool

    /// The input FASTQ file(s) from which reads are extracted.
    ///
    /// For single-end data, this contains one URL. For paired-end data, it
    /// contains two URLs (R1, R2). Each file may be gzip-compressed (`.fastq.gz`).
    public let sourceFiles: [URL]

    /// The output FASTQ file(s) for matching reads.
    ///
    /// Must have the same count as ``sourceFiles``. The pipeline writes matching
    /// reads to the corresponding output file, maintaining pair ordering.
    public let outputFiles: [URL]

    /// The Kraken2 per-read classification output file.
    ///
    /// This is the 5-column TSV produced by `kraken2 --output`, not the kreport.
    /// Each line maps a read ID to its assigned taxonomy ID, which is used to
    /// determine which reads to extract.
    public let classificationOutput: URL

    /// Whether to extract both mates of a read pair when either is classified.
    ///
    /// When `true` (the default), paired-end suffixes (`/1`, `/2`) are stripped
    /// from read IDs before matching so that both mates are extracted whenever
    /// either mate is classified. When `false`, only reads whose exact IDs
    /// appear in the Kraken2 output are extracted -- if only `read123/1` is
    /// classified, `read123/2` is not included.
    public let keepReadPairs: Bool

    /// Creates a taxonomy extraction configuration for paired-end or multi-file input.
    ///
    /// - Parameters:
    ///   - taxIds: Tax IDs to extract.
    ///   - includeChildren: Whether to include descendant taxa.
    ///   - sourceFiles: Input FASTQ file(s).
    ///   - outputFiles: Output FASTQ file(s), one per source file.
    ///   - classificationOutput: Kraken2 per-read output file.
    public init(
        taxIds: Set<Int>,
        includeChildren: Bool,
        sourceFiles: [URL],
        outputFiles: [URL],
        classificationOutput: URL,
        keepReadPairs: Bool = true
    ) {
        self.taxIds = taxIds
        self.includeChildren = includeChildren
        self.sourceFiles = sourceFiles
        self.outputFiles = outputFiles
        self.classificationOutput = classificationOutput
        self.keepReadPairs = keepReadPairs
    }

    /// Creates a taxonomy extraction configuration for a single input file.
    ///
    /// Convenience initializer that wraps `sourceFile` and `outputFile` into
    /// single-element arrays, preserving backward compatibility with existing
    /// callers.
    ///
    /// - Parameters:
    ///   - taxIds: Tax IDs to extract.
    ///   - includeChildren: Whether to include descendant taxa.
    ///   - sourceFile: Input FASTQ file.
    ///   - outputFile: Output FASTQ file.
    ///   - classificationOutput: Kraken2 per-read output file.
    public init(
        taxIds: Set<Int>,
        includeChildren: Bool,
        sourceFile: URL,
        outputFile: URL,
        classificationOutput: URL,
        keepReadPairs: Bool = true
    ) {
        self.taxIds = taxIds
        self.includeChildren = includeChildren
        self.sourceFiles = [sourceFile]
        self.outputFiles = [outputFile]
        self.classificationOutput = classificationOutput
        self.keepReadPairs = keepReadPairs
    }

    // MARK: - Backward-Compatible Accessors

    /// The first (or only) input FASTQ file.
    ///
    /// For single-end data this is the sole input; for paired-end it is R1.
    public var sourceFile: URL {
        sourceFiles[0]
    }

    /// The first (or only) output FASTQ file.
    ///
    /// For single-end data this is the sole output; for paired-end it is the R1 output.
    public var outputFile: URL {
        outputFiles[0]
    }

    /// Whether this configuration targets paired-end data.
    public var isPairedEnd: Bool {
        sourceFiles.count > 1
    }

    /// A human-readable description of this extraction for logging.
    public var summary: String {
        let taxStr = taxIds.count == 1
            ? "taxId \(taxIds.first!)"
            : "\(taxIds.count) taxa"
        let childStr = includeChildren ? " (with children)" : ""
        let fileStr = sourceFiles.count == 1
            ? sourceFile.lastPathComponent
            : "\(sourceFiles.count) files"
        return "Extract \(taxStr)\(childStr) from \(fileStr)"
    }
}

// MARK: - TaxonomyExtractionError

/// Errors produced during taxonomy-based read extraction.
public enum TaxonomyExtractionError: Error, LocalizedError, Sendable {

    /// The classification output file could not be read.
    case classificationOutputNotFound(URL)

    /// The source FASTQ file could not be read.
    case sourceFileNotFound(URL)

    /// No read IDs matched the specified taxonomy filter.
    case noMatchingReads

    /// The output file could not be written.
    case outputWriteFailed(URL, String)

    /// The extraction was cancelled.
    case cancelled

    /// The number of source and output files do not match.
    case sourceOutputCountMismatch(sources: Int, outputs: Int)

    public var errorDescription: String? {
        switch self {
        case .classificationOutputNotFound(let url):
            return "Classification output not found: \(url.lastPathComponent)"
        case .sourceFileNotFound(let url):
            return "Source FASTQ not found: \(url.lastPathComponent)"
        case .noMatchingReads:
            return "No reads matched the specified taxa"
        case .outputWriteFailed(let url, let reason):
            return "Cannot write output to \(url.lastPathComponent): \(reason)"
        case .cancelled:
            return "Extraction was cancelled"
        case .sourceOutputCountMismatch(let sources, let outputs):
            return "Source file count (\(sources)) does not match output file count (\(outputs))"
        }
    }
}
