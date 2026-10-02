// NaoMgsResult.swift - Aggregated results from a NAO-MGS workflow run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - NaoMgsResult

/// Aggregated results from a NAO-MGS workflow run.
///
/// Contains the per-read virus hits, taxon-level summaries, and metadata
/// about the source directory and sample.
public struct NaoMgsResult: Sendable {
    /// Per-read virus hits.
    public let virusHits: [NaoMgsVirusHit]

    /// Summary statistics grouped by taxon, sorted by hit count descending.
    public let taxonSummaries: [NaoMgsTaxonSummary]

    /// Total reads with virus hits.
    public let totalHitReads: Int

    /// Sample name (from the first hit, or user-provided).
    public let sampleName: String

    /// Source directory of the results.
    public let sourceDirectory: URL

    /// Path to the virus_hits_final.tsv(.gz) file that was parsed.
    public let virusHitsFile: URL

    /// Creates a new NAO-MGS result set.
    public init(
        virusHits: [NaoMgsVirusHit],
        taxonSummaries: [NaoMgsTaxonSummary],
        totalHitReads: Int,
        sampleName: String,
        sourceDirectory: URL,
        virusHitsFile: URL
    ) {
        self.virusHits = virusHits
        self.taxonSummaries = taxonSummaries
        self.totalHitReads = totalHitReads
        self.sampleName = sampleName
        self.sourceDirectory = sourceDirectory
        self.virusHitsFile = virusHitsFile
    }
}
