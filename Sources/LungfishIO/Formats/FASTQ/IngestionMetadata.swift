// IngestionMetadata.swift - Records the state of the FASTQ ingestion pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Ingestion Metadata

/// Records the state of the FASTQ ingestion pipeline.
public struct IngestionMetadata: Codable, Sendable {

    /// Pairing mode of the FASTQ data.
    public enum PairingMode: String, Codable, Sendable {
        case singleEnd = "single_end"
        case pairedEnd = "paired_end"
        case interleaved = "interleaved"
    }

    /// Where the recorded ``pairingMode`` came from.
    ///
    /// Only an ``explicit`` single-end pairing lets a consumer skip reading the
    /// records (``FASTQInputLayoutResolver``). A ``detected`` or ``defaulted``
    /// value, or metadata written before this field existed (`nil`), is a hint
    /// and the records are scanned: bundles imported with no pairing choice
    /// recorded `single_end` even when the file alternated mates.
    public enum PairingSource: String, Codable, Sendable {
        /// The user chose the pairing (`--pairing single|paired|interleaved`,
        /// or a Pairing popup item the user picked in the Import sheet).
        case explicit
        /// The importer read the records (or R1/R2 file names) and decided.
        case detected
        /// A fallback no one chose and nothing verified.
        case defaulted = "default"
    }

    /// Whether the file has been clumpified (k-mer sorted for compression).
    public var isClumpified: Bool

    /// Whether the file is gzip-compressed.
    public var isCompressed: Bool

    /// Pairing mode (single-end, paired-end, or interleaved).
    public var pairingMode: PairingMode

    /// Where ``pairingMode`` came from. `nil` for metadata written before
    /// 2026-09-25, which is treated like ``PairingSource/defaulted``.
    public var pairingSource: PairingSource?

    /// Quality binning scheme applied (e.g. "illumina4", "eightLevel", "none").
    /// Nil for files ingested before quality binning was added.
    public var qualityBinning: String?

    /// Original filenames before ingestion (e.g. ["SRR123_1.fastq", "SRR123_2.fastq"]).
    public var originalFilenames: [String]

    /// Date the ingestion pipeline completed.
    public var ingestionDate: Date?

    /// Size of the original source files before import or recipe processing (bytes).
    public var originalSizeBytes: Int64?

    /// Size of the FASTQ payload handed to the final storage optimization step (bytes).
    public var storageInputSizeBytes: Int64?

    /// Size of the final stored FASTQ payload after storage optimization/compression (bytes).
    public var storageOutputSizeBytes: Int64?

    /// Post-import recipe applied during ingestion, with per-step stats.
    public var recipeApplied: RecipeAppliedInfo?

    public init(
        isClumpified: Bool = false,
        isCompressed: Bool = false,
        pairingMode: PairingMode = .singleEnd,
        pairingSource: PairingSource? = nil,
        qualityBinning: String? = nil,
        originalFilenames: [String] = [],
        ingestionDate: Date? = nil,
        originalSizeBytes: Int64? = nil,
        storageInputSizeBytes: Int64? = nil,
        storageOutputSizeBytes: Int64? = nil,
        recipeApplied: RecipeAppliedInfo? = nil
    ) {
        self.isClumpified = isClumpified
        self.isCompressed = isCompressed
        self.pairingMode = pairingMode
        self.pairingSource = pairingSource
        self.qualityBinning = qualityBinning
        self.originalFilenames = originalFilenames
        self.ingestionDate = ingestionDate
        self.originalSizeBytes = originalSizeBytes
        self.storageInputSizeBytes = storageInputSizeBytes
        self.storageOutputSizeBytes = storageOutputSizeBytes
        self.recipeApplied = recipeApplied
    }
}
