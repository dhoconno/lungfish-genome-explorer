// PersistedFASTQMetadata.swift - Metadata persisted alongside a FASTQ file as a sidecar JSON
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Persisted FASTQ Metadata

/// Metadata persisted alongside a FASTQ file as a sidecar JSON.
///
/// File convention: `SRR12345.fastq.gz.lungfish-meta.json`
///
/// Contains cached statistics (to avoid re-computing on reload),
/// download provenance, and SRA/ENA metadata when available.
public struct PersistedFASTQMetadata: Codable, Sendable {

    /// Cached dataset statistics (avoids re-streaming the FASTQ).
    public var computedStatistics: FASTQDatasetStatistics?

    /// SRA run info (from NCBI SRA search).
    public var sraRunInfo: SRARunInfo?

    /// ENA read record (from ENA Portal API).
    public var enaReadRecord: ENAReadRecord?

    /// Date the FASTQ was downloaded.
    public var downloadDate: Date?

    /// Source URL or identifier for the download.
    public var downloadSource: String?

    /// Ingestion pipeline metadata (clumpify/compress/index status).
    public var ingestion: IngestionMetadata?

    /// Cached summary parsed from `seqkit stats -a -T`.
    public var seqkitStats: SeqkitStatsMetadata?

    /// Read type classification for bundles with heterogeneous read types
    /// (e.g. after paired-end merging produces paired + merged + orphan reads).
    /// Nil for homogeneous single-end or paired-end bundles.
    public var readClassification: ReadClassification?

    /// Optional FASTQ demultiplex metadata edited in the FASTQ bottom drawer.
    public var demultiplexMetadata: FASTQDemultiplexMetadata?

    /// Sequencing platform that generated this data (ONT, Illumina, PacBio, etc.).
    /// Used to select appropriate adapter contexts and error rates.
    public var sequencingPlatform: SequencingPlatform?

    /// Optional user-confirmed assembly read type for this dataset.
    ///
    /// This is narrower than `sequencingPlatform`: PacBio datasets are only
    /// represented here when the user explicitly confirms HiFi/CCS suitability.
    public var assemblyReadType: FASTQAssemblyReadType?

    /// How `sequencingPlatform` and `assemblyReadType` were decided, with the
    /// evidence. Nil for bundles imported before platform inference.
    public var platformAssignment: PlatformAssignment?

    public init(
        computedStatistics: FASTQDatasetStatistics? = nil,
        sraRunInfo: SRARunInfo? = nil,
        enaReadRecord: ENAReadRecord? = nil,
        downloadDate: Date? = nil,
        downloadSource: String? = nil,
        ingestion: IngestionMetadata? = nil,
        seqkitStats: SeqkitStatsMetadata? = nil,
        readClassification: ReadClassification? = nil,
        demultiplexMetadata: FASTQDemultiplexMetadata? = nil,
        sequencingPlatform: SequencingPlatform? = nil,
        assemblyReadType: FASTQAssemblyReadType? = nil,
        platformAssignment: PlatformAssignment? = nil
    ) {
        self.computedStatistics = computedStatistics
        self.sraRunInfo = sraRunInfo
        self.enaReadRecord = enaReadRecord
        self.downloadDate = downloadDate
        self.downloadSource = downloadSource
        self.ingestion = ingestion
        self.seqkitStats = seqkitStats
        self.readClassification = readClassification
        self.demultiplexMetadata = demultiplexMetadata
        self.sequencingPlatform = sequencingPlatform
        self.assemblyReadType = assemblyReadType
        self.platformAssignment = platformAssignment
    }
}
