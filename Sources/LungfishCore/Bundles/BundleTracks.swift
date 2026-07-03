// BundleTracks.swift - Reference genome bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - MetadataGroup

/// A named group of metadata key-value pairs for flexible metadata storage.
///
/// Groups organize metadata by category (e.g., "Assembly", "Taxonomy", "Virus").
/// Each group contains an ordered list of items that are displayed together in the Inspector.
///
/// ## Example
///
/// ```swift
/// MetadataGroup(
///     name: "Assembly",
///     items: [
///         MetadataItem(label: "Assembly Level", value: "Chromosome"),
///         MetadataItem(label: "Coverage", value: "30x"),
///         MetadataItem(label: "Contig N50", value: "56,413,054 bp")
///     ]
/// )
/// ```
public struct MetadataGroup: Codable, Sendable, Equatable, Identifiable {

    /// Stable unique identifier (persisted across save/load cycles).
    public let id: String

    /// Display name for this group (e.g., "Assembly", "Taxonomy", "Virus").
    public let name: String

    /// Ordered key-value metadata items in this group.
    public let items: [MetadataItem]

    /// Creates a metadata group.
    public init(name: String, items: [MetadataItem]) {
        self.id = UUID().uuidString
        self.name = name
        self.items = items
    }

    /// Backward-compatible decoding: generates a UUID if `id` is missing in older manifests.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([MetadataItem].self, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, items
    }
}

/// A single metadata key-value pair within a ``MetadataGroup``.
public struct MetadataItem: Codable, Sendable, Equatable, Identifiable {

    /// Stable unique identifier (persisted across save/load cycles).
    public let id: String

    /// Human-readable label (e.g., "Assembly Level", "Taxonomy ID").
    public let label: String

    /// The metadata value (e.g., "Chromosome", "9606").
    public let value: String

    /// Optional URL for clickable links (e.g., to Pathoplexus or NCBI pages).
    public let url: String?

    /// Creates a metadata item.
    public init(label: String, value: String, url: String? = nil) {
        self.id = UUID().uuidString
        self.label = label
        self.value = value
        self.url = url
    }

    /// Backward-compatible decoding: generates a UUID if `id` is missing in older manifests.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try container.decode(String.self, forKey: .label)
        value = try container.decode(String.self, forKey: .value)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, value, url
    }
}

// MARK: - SourceInfo

/// Information about the source of a reference genome.
public struct SourceInfo: Codable, Sendable, Equatable {

    /// Scientific name of the organism (e.g., "Homo sapiens").
    public let organism: String

    /// Common name of the organism (e.g., "Human").
    public let commonName: String?

    /// NCBI taxonomy ID.
    public let taxonomyId: Int?

    /// Assembly name (e.g., "GRCh38", "GRCm39").
    public let assembly: String

    /// Assembly accession (e.g., "GCF_000001405.40").
    public let assemblyAccession: String?

    /// Source database (e.g., "NCBI", "Ensembl", "UCSC").
    public let database: String?

    /// URL to the source data.
    public let sourceURL: URL?

    /// Date the source data was downloaded.
    public let downloadDate: Date?

    /// Additional notes about the source.
    public let notes: String?

    /// Creates source information.
    public init(
        organism: String,
        commonName: String? = nil,
        taxonomyId: Int? = nil,
        assembly: String,
        assemblyAccession: String? = nil,
        database: String? = nil,
        sourceURL: URL? = nil,
        downloadDate: Date? = nil,
        notes: String? = nil
    ) {
        self.organism = organism
        self.commonName = commonName
        self.taxonomyId = taxonomyId
        self.assembly = assembly
        self.assemblyAccession = assemblyAccession
        self.database = database
        self.sourceURL = sourceURL
        self.downloadDate = downloadDate
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case organism
        case commonName = "common_name"
        case taxonomyId = "taxonomy_id"
        case assembly
        case assemblyAccession = "assembly_accession"
        case database
        case sourceURL = "source_url"
        case downloadDate = "download_date"
        case notes
    }
}

// MARK: - GenomeInfo

/// Information about the reference genome sequence.
public struct GenomeInfo: Codable, Sendable, Equatable {

    /// Relative path to the compressed FASTA file within the bundle.
    public let path: String

    /// Relative path to the .fai index file.
    public let indexPath: String

    /// Relative path to the .gzi bgzip index (for random access).
    public let gzipIndexPath: String?

    /// Total length of all sequences in base pairs.
    public let totalLength: Int64

    /// Information about each chromosome/contig.
    public let chromosomes: [ChromosomeInfo]

    /// MD5 checksum of the uncompressed FASTA.
    public let md5Checksum: String?

    /// Creates genome information.
    public init(
        path: String,
        indexPath: String,
        gzipIndexPath: String? = nil,
        totalLength: Int64,
        chromosomes: [ChromosomeInfo],
        md5Checksum: String? = nil
    ) {
        self.path = path
        self.indexPath = indexPath
        self.gzipIndexPath = gzipIndexPath
        self.totalLength = totalLength
        self.chromosomes = chromosomes
        self.md5Checksum = md5Checksum
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case indexPath = "index_path"
        case gzipIndexPath = "gzip_index_path"
        case totalLength = "total_length"
        case chromosomes
        case md5Checksum = "md5_checksum"
    }
}

// MARK: - ChromosomeInfo

/// Information about a single chromosome or contig.
public struct ChromosomeInfo: Codable, Sendable, Equatable, Identifiable {

    /// Chromosome/contig name (e.g., "chr1", "MT", "scaffold_1").
    public let name: String

    /// Unique identifier (same as name).
    public var id: String { name }

    /// Length in base pairs.
    public let length: Int64

    /// Byte offset in the FASTA file (from .fai index).
    public let offset: Int64

    /// Number of bases per line in the FASTA.
    public let lineBases: Int

    /// Number of bytes per line (including newline).
    public let lineWidth: Int

    /// Aliases for this chromosome (e.g., "1" for "chr1").
    public let aliases: [String]

    /// Whether this is a primary assembly sequence.
    public let isPrimary: Bool

    /// Whether this is the mitochondrial genome.
    public let isMitochondrial: Bool

    /// FASTA header description (text after the first space on the `>` line).
    /// e.g., for `>NC_041754.1 Macaca mulatta chromosome 1`, this is `"Macaca mulatta chromosome 1"`.
    public let fastaDescription: String?

    /// Creates chromosome information.
    public init(
        name: String,
        length: Int64,
        offset: Int64,
        lineBases: Int,
        lineWidth: Int,
        aliases: [String] = [],
        isPrimary: Bool = true,
        isMitochondrial: Bool = false,
        fastaDescription: String? = nil
    ) {
        self.name = name
        self.length = length
        self.offset = offset
        self.lineBases = lineBases
        self.lineWidth = lineWidth
        self.aliases = aliases
        self.isPrimary = isPrimary
        self.isMitochondrial = isMitochondrial
        self.fastaDescription = fastaDescription
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case length
        case offset
        case lineBases = "line_bases"
        case lineWidth = "line_width"
        case aliases
        case isPrimary = "is_primary"
        case isMitochondrial = "is_mitochondrial"
        case fastaDescription = "fasta_description"
    }
}

// MARK: - AnnotationTrackInfo

/// Information about an annotation track in the bundle.
public struct AnnotationTrackInfo: Codable, Sendable, Equatable, Identifiable {

    /// Unique identifier for the track.
    public let id: String

    /// Human-readable name.
    public let name: String

    /// Description of the track.
    public let description: String?

    /// Relative path to the BigBed file.
    public let path: String

    /// Relative path to the SQLite annotation database (for fast search/filtering).
    /// Nil for older bundles that pre-date this feature.
    public let databasePath: String?

    /// Type of annotations in this track.
    public let annotationType: AnnotationTrackType

    /// Number of annotations in the track.
    public let featureCount: Int?

    /// Source of the annotation data.
    public let source: String?

    /// Version of the annotation data.
    public let version: String?

    /// Creates annotation track information.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        path: String,
        databasePath: String? = nil,
        annotationType: AnnotationTrackType = .gene,
        featureCount: Int? = nil,
        source: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.databasePath = databasePath
        self.annotationType = annotationType
        self.featureCount = featureCount
        self.source = source
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case path
        case databasePath = "database_path"
        case annotationType = "annotation_type"
        case featureCount = "feature_count"
        case source
        case version
    }
}

/// Types of annotation tracks.
public enum AnnotationTrackType: String, Codable, Sendable {
    /// Gene annotations.
    case gene
    /// Transcript annotations.
    case transcript
    /// Exon annotations.
    case exon
    /// CDS (coding sequence) annotations.
    case cds
    /// Open reading frame annotations.
    case orf
    /// Six-frame translation annotations.
    case translation
    /// Regulatory elements.
    case regulatory
    /// Repeat elements.
    case repeats
    /// Conservation scores.
    case conservation
    /// Custom annotations.
    case custom
}

// MARK: - VariantTrackInfo

/// Information about a variant track in the bundle.
public struct VariantTrackInfo: Codable, Sendable, Equatable, Identifiable {

    /// Unique identifier for the track.
    public let id: String

    /// Human-readable name.
    public let name: String

    /// Description of the track.
    public let description: String?

    /// Relative path to the BCF file.
    public let path: String

    /// Relative path to the CSI index file.
    public let indexPath: String

    /// Relative path to the SQLite variant database (for fast region queries).
    /// Nil for bundles that only have BCF/CSI without a pre-built database.
    public let databasePath: String?

    /// Type of variants in this track.
    public let variantType: VariantTrackType

    /// Number of variants in the track.
    public let variantCount: Int?

    /// Source of the variant data.
    public let source: String?

    /// Version of the variant data.
    public let version: String?

    /// Creates variant track information.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        path: String,
        indexPath: String,
        databasePath: String? = nil,
        variantType: VariantTrackType = .mixed,
        variantCount: Int? = nil,
        source: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.indexPath = indexPath
        self.databasePath = databasePath
        self.variantType = variantType
        self.variantCount = variantCount
        self.source = source
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case path
        case indexPath = "index_path"
        case databasePath = "database_path"
        case variantType = "variant_type"
        case variantCount = "variant_count"
        case source
        case version
    }
}

/// Types of variant tracks.
public enum VariantTrackType: String, Codable, Sendable {
    /// SNPs only.
    case snp
    /// Indels only.
    case indel
    /// Structural variants.
    case structural
    /// Copy number variants.
    case cnv
    /// Mixed variant types.
    case mixed
}

// MARK: - SignalTrackInfo

/// Information about a signal track (BigWig) in the bundle.
public struct SignalTrackInfo: Codable, Sendable, Equatable, Identifiable {

    /// Unique identifier for the track.
    public let id: String

    /// Human-readable name.
    public let name: String

    /// Description of the track.
    public let description: String?

    /// Relative path to the BigWig file.
    public let path: String

    /// Type of signal data.
    public let signalType: SignalTrackType

    /// Minimum value in the track.
    public let minValue: Float?

    /// Maximum value in the track.
    public let maxValue: Float?

    /// Source of the signal data.
    public let source: String?

    /// Creates signal track information.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        path: String,
        signalType: SignalTrackType = .coverage,
        minValue: Float? = nil,
        maxValue: Float? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.signalType = signalType
        self.minValue = minValue
        self.maxValue = maxValue
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case path
        case signalType = "signal_type"
        case minValue = "min_value"
        case maxValue = "max_value"
        case source
    }
}

// MARK: - AlignmentTrackInfo

/// Information about an alignment track (BAM/CRAM) referenced by the bundle.
///
/// Alignment files may be either bundle-relative (preferred, copied into `alignments/`)
/// or legacy absolute external paths. The track stores metadata, alignment/index paths,
/// and an optional SQLite metadata sidecar.
///
/// ## External File References
///
/// The `sourcePath` points to the BAM/CRAM file on disk. If the file is moved,
/// the `sourceBookmark` (a macOS security-scoped bookmark) can resolve the new
/// location. The `checksumSHA256` and `fileSizeBytes` detect file replacement.
public struct AlignmentTrackInfo: Codable, Sendable, Equatable, Identifiable {

    /// Unique identifier for the track.
    public let id: String

    /// Human-readable name (e.g., "Sample 1 - WGS").
    public let name: String

    /// Description of the track.
    public let description: String?

    /// File format.
    public let format: AlignmentFormat

    /// Path to the alignment file (BAM/CRAM/SAM).
    /// Preferred format: bundle-relative path (e.g., `alignments/aln_123.sorted.bam`).
    /// Legacy manifests may contain absolute external paths.
    public let sourcePath: String

    /// Base64-encoded security-scoped Finder bookmark for relocatable files.
    public let sourceBookmark: String?

    /// Path to the index file (.bai / .csi / .crai).
    /// Preferred format: bundle-relative path aligned with `sourcePath`.
    /// Legacy manifests may contain absolute external paths.
    public let indexPath: String

    /// Base64-encoded bookmark for the index file.
    public let indexBookmark: String?

    /// Relative path within the bundle to the SQLite metadata database.
    public let metadataDBPath: String?

    /// SHA-256 checksum of the alignment file at import time.
    public let checksumSHA256: String?

    /// File size in bytes at import time (for staleness detection).
    public let fileSizeBytes: Int64?

    /// Date this alignment was added to the bundle.
    public let addedDate: Date

    /// Total mapped read count (cached from samtools idxstats).
    public let mappedReadCount: Int64?

    /// Total unmapped read count.
    public let unmappedReadCount: Int64?

    /// Sample name(s) from @RG headers.
    public let sampleNames: [String]

    /// Creates alignment track information.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        format: AlignmentFormat = .bam,
        sourcePath: String,
        sourceBookmark: String? = nil,
        indexPath: String,
        indexBookmark: String? = nil,
        metadataDBPath: String? = nil,
        checksumSHA256: String? = nil,
        fileSizeBytes: Int64? = nil,
        addedDate: Date = Date(),
        mappedReadCount: Int64? = nil,
        unmappedReadCount: Int64? = nil,
        sampleNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.format = format
        self.sourcePath = sourcePath
        self.sourceBookmark = sourceBookmark
        self.indexPath = indexPath
        self.indexBookmark = indexBookmark
        self.metadataDBPath = metadataDBPath
        self.checksumSHA256 = checksumSHA256
        self.fileSizeBytes = fileSizeBytes
        self.addedDate = addedDate
        self.mappedReadCount = mappedReadCount
        self.unmappedReadCount = unmappedReadCount
        self.sampleNames = sampleNames
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case format
        case sourcePath = "source_path"
        case sourceBookmark = "source_bookmark"
        case indexPath = "index_path"
        case indexBookmark = "index_bookmark"
        case metadataDBPath = "metadata_db_path"
        case checksumSHA256 = "checksum_sha256"
        case fileSizeBytes = "file_size_bytes"
        case addedDate = "added_date"
        case mappedReadCount = "mapped_read_count"
        case unmappedReadCount = "unmapped_read_count"
        case sampleNames = "sample_names"
    }
}

/// Alignment file formats.
public enum AlignmentFormat: String, Codable, Sendable {
    /// Binary Alignment/Map format.
    case bam
    /// CRAM (reference-based compressed alignment).
    case cram
    /// SAM (text-based alignment format, not recommended for large files).
    case sam
}

/// Types of signal tracks.
public enum SignalTrackType: String, Codable, Sendable {
    /// Read coverage depth.
    case coverage
    /// GC content.
    case gcContent
    /// Conservation scores.
    case conservation
    /// ChIP-seq signal.
    case chipSeq
    /// ATAC-seq signal.
    case atacSeq
    /// Methylation levels.
    case methylation
    /// Custom signal type.
    case custom
}
