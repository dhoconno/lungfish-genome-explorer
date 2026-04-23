// BundleManifest.swift - Reference genome bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - BundleManifest

/// Manifest describing the contents of a `.lungfishref` reference genome bundle.
///
/// The manifest is stored as `manifest.json` in the bundle root and contains:
/// - Bundle metadata (name, identifier, version)
/// - Source information (organism, assembly, source database)
/// - Genome sequence information with index paths
/// - Annotation track definitions
/// - Variant track definitions
/// - Signal track definitions (BigWig)
///
/// ## Bundle Format
///
/// ```
/// MyGenome.lungfishref/
/// ├── manifest.json                    # This manifest
/// ├── genome/
/// │   ├── sequence.fa.gz               # bgzip-compressed FASTA
/// │   ├── sequence.fa.gz.fai           # samtools faidx index
/// │   └── sequence.fa.gz.gzi           # bgzip index (random access)
/// ├── annotations/
/// │   ├── genes.bb                     # BigBed format
/// │   └── transcripts.bb
/// ├── variants/
/// │   ├── snps.bcf                     # Indexed BCF
/// │   └── snps.bcf.csi                 # CSI index
/// └── tracks/
///     └── gc_content.bw                # BigWig signal tracks
/// ```
///
/// ## Example
///
/// ```swift
/// let manifest = BundleManifest(
///     formatVersion: "1.0",
///     name: "Human Reference Genome",
///     identifier: "org.lungfish.hg38",
///     source: SourceInfo(organism: "Homo sapiens", assembly: "GRCh38"),
///     genome: GenomeInfo(
///         path: "genome/sequence.fa.gz",
///         indexPath: "genome/sequence.fa.gz.fai",
///         totalLength: 3_088_286_401,
///         chromosomes: [...]
///     )
/// )
/// ```
public struct BundleManifest: Codable, Sendable, Equatable {

    // MARK: - Core Properties

    /// Version of the bundle format (e.g., "1.0").
    public let formatVersion: String

    /// Human-readable name of the bundle.
    public let name: String

    /// Unique identifier for the bundle (reverse-DNS style).
    public let identifier: String

    /// Optional description of the bundle.
    public let description: String?

    /// Optional origin bundle path when this bundle is a copied derivative of
    /// another reference bundle. Stored as a project-relative (`@/…`),
    /// filesystem-relative (`../…`), or absolute path.
    public let originBundlePath: String?

    /// Date the bundle was created.
    public let createdDate: Date

    /// Date the bundle was last modified.
    public let modifiedDate: Date

    // MARK: - Source Information

    /// Information about the source of the genome data.
    public let source: SourceInfo

    // MARK: - Genome Content

    /// Information about the reference genome sequence.
    /// `nil` for variant-only bundles created from standalone VCF import.
    public let genome: GenomeInfo?

    /// Whether this bundle contains only variant data (no reference sequence).
    public var isVariantOnly: Bool { genome == nil }

    /// Annotation tracks in the bundle.
    public let annotations: [AnnotationTrackInfo]

    /// Variant tracks in the bundle.
    public let variants: [VariantTrackInfo]

    /// Signal tracks (BigWig) in the bundle.
    public let tracks: [SignalTrackInfo]

    /// Alignment tracks (BAM/CRAM) referenced by the bundle.
    /// Alignment files are stored externally; the bundle holds metadata and indexes.
    public let alignments: [AlignmentTrackInfo]

    // MARK: - Extended Metadata

    /// Categorized metadata groups for flexible, source-specific metadata storage.
    ///
    /// Each group represents a category (e.g., "Assembly", "Taxonomy", "Virus")
    /// with key-value metadata items. This enables different bundle sources
    /// (GenBank, Genome, Virus) to store their full metadata without schema changes.
    ///
    /// Optional for backward compatibility with existing bundles.
    public let metadata: [MetadataGroup]?

    /// Typed browser summary used to populate bundle browser rows quickly.
    /// Optional so legacy manifests without this cache still decode successfully.
    public let browserSummary: BundleBrowserSummary?

    // MARK: - Initialization

    /// Creates a new bundle manifest.
    public init(
        formatVersion: String = "1.0",
        name: String,
        identifier: String,
        description: String? = nil,
        originBundlePath: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        source: SourceInfo,
        genome: GenomeInfo? = nil,
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        tracks: [SignalTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = [],
        metadata: [MetadataGroup]? = nil,
        browserSummary: BundleBrowserSummary? = nil
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.identifier = identifier
        self.description = description
        self.originBundlePath = originBundlePath
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.source = source
        self.genome = genome
        self.annotations = annotations
        self.variants = variants
        self.tracks = tracks
        self.alignments = alignments
        self.metadata = metadata
        self.browserSummary = browserSummary
    }

    /// Backward-compatible initializer preserved for existing call sites that
    /// do not supply `originBundlePath`.
    public init(
        formatVersion: String = "1.0",
        name: String,
        identifier: String,
        description: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        source: SourceInfo,
        genome: GenomeInfo? = nil,
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        tracks: [SignalTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = [],
        metadata: [MetadataGroup]? = nil,
        browserSummary: BundleBrowserSummary? = nil
    ) {
        self.init(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: nil,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: browserSummary
        )
    }

    /// Backward-compatible initializer preserved for existing binaries and
    /// call sites that pre-date `browserSummary` but include `originBundlePath`.
    public init(
        formatVersion: String = "1.0",
        name: String,
        identifier: String,
        description: String? = nil,
        originBundlePath: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        source: SourceInfo,
        genome: GenomeInfo? = nil,
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        tracks: [SignalTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = [],
        metadata: [MetadataGroup]? = nil
    ) {
        self.init(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Backward-compatible initializer preserved for existing binaries and
    /// call sites that pre-date `browserSummary`.
    public init(
        formatVersion: String = "1.0",
        name: String,
        identifier: String,
        description: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        source: SourceInfo,
        genome: GenomeInfo? = nil,
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        tracks: [SignalTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = [],
        metadata: [MetadataGroup]? = nil
    ) {
        self.init(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case name
        case identifier
        case description
        case originBundlePath = "origin_bundle_path"
        case createdDate = "created_date"
        case modifiedDate = "modified_date"
        case source
        case genome
        case annotations
        case variants
        case tracks
        case alignments
        case metadata
        case browserSummary = "browser_summary"
    }

    // MARK: - Backward-Compatible Decoding

    /// Custom decoder that handles manifests created before the `alignments` field existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(String.self, forKey: .formatVersion)
        name = try container.decode(String.self, forKey: .name)
        identifier = try container.decode(String.self, forKey: .identifier)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        originBundlePath = try container.decodeIfPresent(String.self, forKey: .originBundlePath)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        modifiedDate = try container.decode(Date.self, forKey: .modifiedDate)
        source = try container.decode(SourceInfo.self, forKey: .source)
        genome = try container.decodeIfPresent(GenomeInfo.self, forKey: .genome)
        annotations = try container.decode([AnnotationTrackInfo].self, forKey: .annotations)
        variants = try container.decode([VariantTrackInfo].self, forKey: .variants)
        tracks = try container.decode([SignalTrackInfo].self, forKey: .tracks)
        alignments = try container.decodeIfPresent([AlignmentTrackInfo].self, forKey: .alignments) ?? []
        metadata = try container.decodeIfPresent([MetadataGroup].self, forKey: .metadata)
        browserSummary = try container.decodeIfPresent(BundleBrowserSummary.self, forKey: .browserSummary)
    }
}

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

// MARK: - Manifest I/O

extension BundleManifest {

    /// The standard filename for bundle manifests.
    public static let filename = "manifest.json"

    /// Loads a manifest from a bundle directory.
    ///
    /// - Parameter bundleURL: URL to the `.lungfishref` bundle directory
    /// - Returns: The loaded manifest
    /// - Throws: If the manifest cannot be read or decoded
    public static func load(from bundleURL: URL) throws -> BundleManifest {
        let manifestURL = bundleURL.appendingPathComponent(filename)
        let data = try Data(contentsOf: manifestURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(BundleManifest.self, from: data)
    }

    /// Returns a new manifest with the given variant track appended.
    public func addingVariantTrack(_ track: VariantTrackInfo) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants + [track],
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Returns a new manifest with the variant count updated for a specific track.
    public func updatingVariantCount(trackId: String, newCount: Int) -> BundleManifest {
        let updatedVariants = variants.map { track -> VariantTrackInfo in
            guard track.id == trackId else { return track }
            return VariantTrackInfo(
                id: track.id,
                name: track.name,
                description: track.description,
                path: track.path,
                indexPath: track.indexPath,
                databasePath: track.databasePath,
                variantType: track.variantType,
                variantCount: newCount,
                source: track.source,
                version: track.version
            )
        }
        return BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations,
            variants: updatedVariants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Returns a new manifest with the given annotation track appended.
    public func addingAnnotationTrack(_ track: AnnotationTrackInfo) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations + [track],
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Returns a new manifest with the specified annotation track removed.
    public func removingAnnotationTrack(id: String) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations.filter { $0.id != id },
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Returns a new manifest with the given alignment track appended.
    public func addingAlignmentTrack(_ track: AlignmentTrackInfo) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments + [track],
            metadata: metadata,
            browserSummary: nil
        )
    }

    /// Returns a new manifest with the specified alignment track removed.
    public func removingAlignmentTrack(id: String) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: Date(),
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments.filter { $0.id != id },
            metadata: metadata,
            browserSummary: nil
        )
    }

    public func withSynthesizedBrowserSummaryIfNeeded() -> BundleManifest {
        guard browserSummary == nil, let genome else { return self }

        let mappedReadCounts = alignments.compactMap(\.mappedReadCount)
        let totalMappedReads = mappedReadCounts.isEmpty ? nil : mappedReadCounts.reduce(0, +)
        let synthesized = BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: annotations.count,
                variantTrackCount: variants.count,
                alignmentTrackCount: alignments.count,
                totalMappedReads: totalMappedReads
            ),
            sequences: genome.chromosomes.map { chromosome in
                BundleBrowserSequenceSummary(
                    name: chromosome.name,
                    displayDescription: chromosome.fastaDescription,
                    length: chromosome.length,
                    aliases: chromosome.aliases,
                    isPrimary: chromosome.isPrimary,
                    isMitochondrial: chromosome.isMitochondrial,
                    metrics: nil
                )
            }
        )

        return BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: identifier,
            description: description,
            originBundlePath: originBundlePath,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: synthesized
        )
    }

    public func save(to bundleURL: URL) throws {
        let manifestURL = bundleURL.appendingPathComponent(Self.filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(withSynthesizedBrowserSummaryIfNeeded())
        try data.write(to: manifestURL)
    }
}

// MARK: - Validation

extension BundleManifest {

    /// Validates the manifest for completeness and consistency.
    ///
    /// - Returns: Array of validation errors (empty if valid)
    public func validate() -> [BundleValidationError] {
        var errors: [BundleValidationError] = []

        // Check required fields
        if name.isEmpty {
            errors.append(.missingField("name"))
        }
        if identifier.isEmpty {
            errors.append(.missingField("identifier"))
        }
        // Genome fields are only required for bundles with sequence data.
        if let genome {
            if genome.path.isEmpty {
                errors.append(.missingField("genome.path"))
            }
            if genome.indexPath.isEmpty {
                errors.append(.missingField("genome.indexPath"))
            }
            if genome.chromosomes.isEmpty {
                errors.append(.missingField("genome.chromosomes"))
            }
        }

        // Check for duplicate track IDs
        var trackIds = Set<String>()
        for track in annotations {
            if trackIds.contains(track.id) {
                errors.append(.duplicateTrackId(track.id))
            }
            trackIds.insert(track.id)
        }
        for track in variants {
            if trackIds.contains(track.id) {
                errors.append(.duplicateTrackId(track.id))
            }
            trackIds.insert(track.id)
        }
        for track in tracks {
            if trackIds.contains(track.id) {
                errors.append(.duplicateTrackId(track.id))
            }
            trackIds.insert(track.id)
        }
        for track in alignments {
            if trackIds.contains(track.id) {
                errors.append(.duplicateTrackId(track.id))
            }
            trackIds.insert(track.id)
        }

        return errors
    }
}

/// Validation errors for bundle manifests.
public enum BundleValidationError: Error, LocalizedError, Sendable {
    /// Required field is missing or empty.
    case missingField(String)
    /// Duplicate track ID found.
    case duplicateTrackId(String)
    /// File referenced in manifest not found.
    case fileNotFound(String)
    /// Invalid file format.
    case invalidFileFormat(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Required field '\(field)' is missing or empty"
        case .duplicateTrackId(let id):
            return "Duplicate track ID: '\(id)'"
        case .fileNotFound(let path):
            return "Referenced file not found: '\(path)'"
        case .invalidFileFormat(let path, let expected):
            return "File '\(path)' has invalid format (expected \(expected))"
        }
    }
}

// MARK: - Chromosome Name Mapping

/// Builds a mapping from VCF chromosome names to bundle chromosome names.
///
/// Handles common mismatches:
/// - Version suffixes: `MN908947.3` → `MN908947`
/// - `chr` prefix: `chr1` → `1` or `1` → `chr1`
/// - Alias matching via `ChromosomeInfo.aliases`
///
/// - Parameters:
///   - vcfChromosomes: Distinct chromosome names found in the VCF
///   - bundleChromosomes: Chromosome info from the bundle manifest
/// - Returns: Dictionary mapping VCF names to bundle names (only for names that differ)
public func mapVCFChromosomes(
    _ vcfChromosomes: [String],
    toBundleChromosomes bundleChromosomes: [ChromosomeInfo]
) -> [String: String] {
    var mapping: [String: String] = [:]

    for vcfChrom in vcfChromosomes {
        // 1. Exact match — no mapping needed
        if bundleChromosomes.contains(where: { $0.name == vcfChrom }) {
            continue
        }

        // 2. Alias match
        if let match = bundleChromosomes.first(where: { $0.aliases.contains(vcfChrom) }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 3. Version suffix stripping: "MN908947.3" → "MN908947"
        let stripped = stripVersionSuffix(vcfChrom)
        if stripped != vcfChrom {
            if let match = bundleChromosomes.first(where: { $0.name == stripped }) {
                mapping[vcfChrom] = match.name
                continue
            }
            if let match = bundleChromosomes.first(where: { $0.aliases.contains(stripped) }) {
                mapping[vcfChrom] = match.name
                continue
            }
        }

        // 4. chr prefix handling: "chr1" ↔ "1"
        let chrVariant: String
        if vcfChrom.hasPrefix("chr") {
            chrVariant = String(vcfChrom.dropFirst(3))
        } else {
            chrVariant = "chr" + vcfChrom
        }
        if let match = bundleChromosomes.first(where: { $0.name == chrVariant }) {
            mapping[vcfChrom] = match.name
            continue
        }
        if let match = bundleChromosomes.first(where: { $0.aliases.contains(chrVariant) }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 5. Combined: strip version then try chr prefix
        if stripped != vcfChrom {
            let strippedChr: String
            if stripped.hasPrefix("chr") {
                strippedChr = String(stripped.dropFirst(3))
            } else {
                strippedChr = "chr" + stripped
            }
            if let match = bundleChromosomes.first(where: { $0.name == strippedChr }) {
                mapping[vcfChrom] = match.name
                continue
            }
        }

        // 6. Fuzzy: check if any bundle chromosome name starts with vcfChrom or vice versa
        //    e.g., bundle has "MN908947" and VCF has "MN908947.3"
        if let match = bundleChromosomes.first(where: { vcfChrom.hasPrefix($0.name + ".") }) {
            mapping[vcfChrom] = match.name
            continue
        }

        // 7. FASTA description match: parse "chromosome N" from description
        //    e.g., description "Macaca mulatta chromosome 7" matches VCF "7"
        if let match = bundleChromosomes.first(where: { chrom in
            guard let desc = chrom.fastaDescription?.lowercased() else { return false }
            // Match "chromosome <vcfChrom>" at word boundary
            return desc.contains("chromosome \(vcfChrom.lowercased())")
                && (desc.hasSuffix("chromosome \(vcfChrom.lowercased())")
                    || desc.contains("chromosome \(vcfChrom.lowercased()),")
                    || desc.contains("chromosome \(vcfChrom.lowercased()) "))
        }) {
            mapping[vcfChrom] = match.name
            continue
        }
    }

    return mapping
}

/// Strips a trailing version suffix from an accession-style name.
///
/// Examples: `MN908947.3` → `MN908947`, `NC_045512.2` → `NC_045512`, `chr1` → `chr1`
private func stripVersionSuffix(_ name: String) -> String {
    // Match pattern: name ends with .<digits>
    guard let dotIndex = name.lastIndex(of: ".") else { return name }
    let suffix = name[name.index(after: dotIndex)...]
    // Only strip if the suffix is all digits (version number)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isWholeNumber) else { return name }
    return String(name[..<dotIndex])
}
