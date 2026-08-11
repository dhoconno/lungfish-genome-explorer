// NvdManifest.swift - JSON manifest for NVD result bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - NvdManifest

/// Top-level manifest for an imported NVD result bundle.
///
/// Stored as `manifest.json` inside the bundle directory.  Captures provenance
/// metadata (experiment ID, import date, BLAST DB version, run ID) and a full
/// list of per-sample summaries for sidebar display without opening the database.
public struct NvdManifest: Codable, Sendable {

    /// Schema version string — currently `"1.0"`.
    public let formatVersion: String

    /// Experiment identifier from the NVD pipeline (e.g. `"100"`).
    public let experiment: String

    /// Date and time the bundle was imported into the project.
    public let importDate: Date

    /// Number of samples in the import.
    public let sampleCount: Int

    /// Total assembled contigs across all samples.
    public let contigCount: Int

    /// Total BLAST hits across all samples.
    public let hitCount: Int

    /// BLAST database version string, if available.
    public let blastDbVersion: String?

    /// Snakemake run identifier, if available.
    public let snakemakeRunId: String?

    /// Absolute or project-relative path to the source directory.
    public let sourceDirectoryPath: String

    /// Per-sample summaries for sidebar and detail views.
    public let samples: [NvdSampleSummary]

    /// Cached top contigs (best hits) for fast initial display.  May be nil
    /// if the manifest was created without caching or has been trimmed.
    public var cachedTopContigs: [NvdContigRow]?

    public init(
        experiment: String,
        importDate: Date = Date(),
        sampleCount: Int,
        contigCount: Int,
        hitCount: Int,
        blastDbVersion: String?,
        snakemakeRunId: String?,
        sourceDirectoryPath: String,
        samples: [NvdSampleSummary],
        cachedTopContigs: [NvdContigRow]?
    ) {
        self.formatVersion = "1.0"
        self.experiment = experiment
        self.importDate = importDate
        self.sampleCount = sampleCount
        self.contigCount = contigCount
        self.hitCount = hitCount
        self.blastDbVersion = blastDbVersion
        self.snakemakeRunId = snakemakeRunId
        self.sourceDirectoryPath = sourceDirectoryPath
        self.samples = samples
        self.cachedTopContigs = cachedTopContigs
    }
}

// MARK: - NvdSampleSummary

/// Lightweight per-sample entry stored in the manifest.
///
/// Used to populate the sidebar sample list and the sample picker without
/// opening the SQLite database.
public struct NvdSampleSummary: Codable, Sendable {

    /// Sample identifier from the NVD pipeline.
    public let sampleId: String

    /// Number of assembled contigs that had at least one BLAST hit.
    public let contigCount: Int

    /// Total BLAST hits for this sample.
    public let hitCount: Int

    /// Total input reads for this sample (used for RPB normalization display).
    public let totalReads: Int

    /// Path to the BAM alignment file, relative to the bundle root.
    public let bamRelativePath: String

    /// Explicit final stored BAM index path, relative to the bundle root.
    /// Optional for backward-compatible decoding of pre-index manifests.
    public let bamIndexRelativePath: String?

    /// Path to the assembled FASTA file, relative to the bundle root.
    public let fastaRelativePath: String

    public init(
        sampleId: String,
        contigCount: Int,
        hitCount: Int,
        totalReads: Int,
        bamRelativePath: String,
        bamIndexRelativePath: String? = nil,
        fastaRelativePath: String
    ) {
        self.sampleId = sampleId
        self.contigCount = contigCount
        self.hitCount = hitCount
        self.totalReads = totalReads
        self.bamRelativePath = bamRelativePath
        self.bamIndexRelativePath = bamIndexRelativePath
        self.fastaRelativePath = fastaRelativePath
    }

    /// Source-compatible initializer retained for clients built against the
    /// original manifest schema.
    public init(
        sampleId: String,
        contigCount: Int,
        hitCount: Int,
        totalReads: Int,
        bamRelativePath: String,
        fastaRelativePath: String
    ) {
        self.init(
            sampleId: sampleId,
            contigCount: contigCount,
            hitCount: hitCount,
            totalReads: totalReads,
            bamRelativePath: bamRelativePath,
            bamIndexRelativePath: nil,
            fastaRelativePath: fastaRelativePath
        )
    }
}

// MARK: - NvdContigRow

/// A single row in the cached top-contigs table stored in the manifest.
///
/// Mirrors the key columns from `blast_hits` for the best hit of each contig,
/// enabling fast display of the contig table without a database query.
public struct NvdContigRow: Codable, Sendable {

    /// Sample identifier.
    public let sampleId: String

    /// Query sequence identifier (assembled contig name).
    public let qseqid: String

    /// Query (contig) length in bases.
    public let qlen: Int

    /// Name of the adjusted taxon.
    public let adjustedTaxidName: String

    /// Rank of the adjusted taxon (e.g. `"species"`).
    public let adjustedTaxidRank: String

    /// Subject sequence accession (e.g. `"NC_045512.2"`).
    public let sseqid: String

    /// Subject sequence title.
    public let stitle: String

    /// Percent identity of the best BLAST alignment.
    public let pident: Double

    /// E-value of the best BLAST alignment.
    public let evalue: Double

    /// Bit score of the best BLAST alignment.
    public let bitscore: Double

    /// Number of reads that mapped to this contig.
    public let mappedReads: Int

    /// Reads per billion: `mappedReads / totalReads * 1e9`.
    public let readsPerBillion: Double

    public init(
        sampleId: String,
        qseqid: String,
        qlen: Int,
        adjustedTaxidName: String,
        adjustedTaxidRank: String,
        sseqid: String,
        stitle: String,
        pident: Double,
        evalue: Double,
        bitscore: Double,
        mappedReads: Int,
        readsPerBillion: Double
    ) {
        self.sampleId = sampleId
        self.qseqid = qseqid
        self.qlen = qlen
        self.adjustedTaxidName = adjustedTaxidName
        self.adjustedTaxidRank = adjustedTaxidRank
        self.sseqid = sseqid
        self.stitle = stitle
        self.pident = pident
        self.evalue = evalue
        self.bitscore = bitscore
        self.mappedReads = mappedReads
        self.readsPerBillion = readsPerBillion
    }
}
