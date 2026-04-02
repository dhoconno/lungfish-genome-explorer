// NaoMgsManifest.swift - Manifest for NAO-MGS result bundles
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation

/// Manifest for a NAO-MGS result bundle.
///
/// Stored as `manifest.json` inside the `naomgs-{sampleName}/` bundle directory.
/// The bundle directory structure is:
///
/// ```
/// naomgs-{runToken}/
///   manifest.json          <- this manifest
///   virus_hits.json        <- serialized NaoMgsVirusHit + NaoMgsTaxonSummary
///   {sample}.sorted.bam    <- sorted alignment file
///   {sample}.sorted.bam.bai <- BAM index
///   references/            <- fetched GenBank FASTA references
///     NC_045512.2.fasta
///     ...
/// ```
public struct NaoMgsManifest: Codable, Sendable {

    /// Bundle format version.
    public let formatVersion: String

    /// Sample name.
    public let sampleName: String

    /// Import date (ISO 8601).
    public let importDate: Date

    /// Original source file path.
    public let sourceFilePath: String

    /// Total virus hit count.
    public let hitCount: Int

    /// Unique taxon count.
    public let taxonCount: Int

    /// Top taxon name (by hit count).
    public let topTaxon: String?

    /// Top taxon ID.
    public let topTaxonId: Int?

    /// Reference accessions that have been fetched to the `references/` directory.
    public var fetchedAccessions: [String]

    /// Version of nao-mgs-workflow (if detectable from results).
    public let workflowVersion: String?

    /// Cached taxon summary rows for instant display before database opens.
    /// Written during import; used by the viewport to show the taxon list
    /// immediately while the SQLite database loads in the background.
    public var cachedTaxonRows: [NaoMgsTaxonSummaryRow]?

    /// Creates a new NAO-MGS bundle manifest.
    ///
    /// - Parameters:
    ///   - sampleName: Sample identifier from the workflow run.
    ///   - sourceFilePath: Path to the original virus_hits_final.tsv(.gz) file.
    ///   - hitCount: Total number of virus hit reads.
    ///   - taxonCount: Number of distinct taxa detected.
    ///   - topTaxon: Name of the most-hit taxon (optional).
    ///   - topTaxonId: NCBI taxonomy ID of the most-hit taxon (optional).
    ///   - fetchedAccessions: GenBank accessions whose FASTA files have been downloaded.
    ///   - workflowVersion: NAO-MGS workflow version string (optional).
    public init(
        sampleName: String,
        sourceFilePath: String,
        hitCount: Int,
        taxonCount: Int,
        topTaxon: String? = nil,
        topTaxonId: Int? = nil,
        fetchedAccessions: [String] = [],
        workflowVersion: String? = nil
    ) {
        self.formatVersion = "1.0"
        self.sampleName = sampleName
        self.importDate = Date()
        self.sourceFilePath = sourceFilePath
        self.hitCount = hitCount
        self.taxonCount = taxonCount
        self.topTaxon = topTaxon
        self.topTaxonId = topTaxonId
        self.fetchedAccessions = fetchedAccessions
        self.workflowVersion = workflowVersion
    }
}

// MARK: - NaoMgsVirusHitsFile

/// On-disk representation of parsed NAO-MGS results for fast reload.
///
/// Serialized as `virus_hits.json` inside the bundle directory so that
/// subsequent opens skip the TSV parsing step entirely.
public struct NaoMgsVirusHitsFile: Codable, Sendable {

    /// The per-read virus hits.
    public let virusHits: [NaoMgsVirusHit]

    /// Taxon-level summaries sorted by hit count descending.
    public let taxonSummaries: [NaoMgsTaxonSummary]

    /// Creates a new virus hits file payload.
    ///
    /// - Parameters:
    ///   - virusHits: All parsed virus hit records.
    ///   - taxonSummaries: Aggregated per-taxon summaries.
    public init(virusHits: [NaoMgsVirusHit], taxonSummaries: [NaoMgsTaxonSummary]) {
        self.virusHits = virusHits
        self.taxonSummaries = taxonSummaries
    }
}
