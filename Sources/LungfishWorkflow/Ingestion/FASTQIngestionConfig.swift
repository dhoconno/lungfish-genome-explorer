// FASTQIngestionConfig.swift - Configuration for the FASTQ ingestion pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

// MARK: - FASTQIngestionConfig

/// Configuration for the FASTQ ingestion pipeline.
public struct FASTQIngestionConfig: Sendable {

    /// Pairing mode for the input files.
    public enum PairingMode: String, Sendable {
        case singleEnd
        case pairedEnd
        case interleaved
    }

    /// Input FASTQ files. For paired-end, provide [R1, R2].
    public let inputFiles: [URL]

    /// Pairing mode.
    public let pairingMode: PairingMode

    /// Output directory where the processed file will be written.
    public let outputDirectory: URL

    /// Number of threads for pigz compression.
    public let threads: Int

    /// Whether to delete original files after successful ingestion.
    public let deleteOriginals: Bool

    /// Quality binning scheme for compression optimization.
    public let qualityBinning: QualityBinningScheme

    /// Gzip compression level for tool output when supported.
    public let compressionLevel: CompressionLevel

    /// Requested storage optimization tool. `.auto` resolves after recipe execution
    /// against the actual files that will be optimized.
    public let clumpingTool: ClumpingTool

    /// The Java heap BBTools clumpify runs with, in GB, when `--clumpify-heap-gb` pins it. Nil sizes it from
    /// this host's free memory when clumpify starts, and the automatic tool choice plans with the host's.
    public let clumpifyHeapGB: Int?

    /// Whether to skip storage optimization. Preserved for older call sites.
    public var skipClumpify: Bool { clumpingTool == .none }

    public init(
        inputFiles: [URL],
        pairingMode: PairingMode = .singleEnd,
        outputDirectory: URL,
        threads: Int = 4,
        deleteOriginals: Bool = true,
        // The pipeline bins only when its caller asks. Each import route passes
        // `IngestionPlatform.defaultQualityBinning(for:)` when the user names no binning,
        // and a derived operation output is re-imported with `.none`.
        qualityBinning: QualityBinningScheme = .none,
        skipClumpify: Bool = false,
        compressionLevel: CompressionLevel = .balanced,
        clumpingTool: ClumpingTool = .default,
        clumpifyHeapGB: Int? = nil
    ) {
        self.inputFiles = inputFiles
        self.pairingMode = pairingMode
        self.outputDirectory = outputDirectory
        self.threads = threads
        self.deleteOriginals = deleteOriginals
        self.qualityBinning = qualityBinning
        self.compressionLevel = compressionLevel
        self.clumpingTool = skipClumpify ? .none : clumpingTool
        self.clumpifyHeapGB = clumpifyHeapGB
    }
}
