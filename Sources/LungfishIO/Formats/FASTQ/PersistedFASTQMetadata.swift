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

    /// The count of this file's records taken at import and bound to its size. Every lone file records it, a file of
    /// one kind included, where ``readClassification`` stays nil. A person's own Single-end outranks it.
    public var recordedReadCount: FASTQRecordedReadCount?

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
        platformAssignment: PlatformAssignment? = nil,
        recordedReadCount: FASTQRecordedReadCount? = nil
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
        self.recordedReadCount = recordedReadCount
    }
}

/// The count of a lone FASTQ file's records, taken from the stored file at import and bound to it by its size, so a
/// file replaced under the same name keeps no stale proof (row READ-LAYOUT-PARTIAL-SCAN).
public struct FASTQRecordedReadCount: Codable, Sendable, Equatable {
    /// Read 1 of each adjacent mate pair.
    public let pairedR1: Int
    /// Read 2 of each adjacent mate pair.
    public let pairedR2: Int
    /// Records without an adjacent mate (merged, orphan or single reads).
    public let unpaired: Int
    /// The size of the stored file the count was taken from.
    public let storedSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case pairedR1 = "paired_r1"
        case pairedR2 = "paired_r2"
        case unpaired
        case storedSizeBytes
    }

    public init(pairedR1: Int, pairedR2: Int, unpaired: Int, storedSizeBytes: Int64) {
        self.pairedR1 = pairedR1
        self.pairedR2 = pairedR2
        self.unpaired = unpaired
        self.storedSizeBytes = storedSizeBytes
    }
}
