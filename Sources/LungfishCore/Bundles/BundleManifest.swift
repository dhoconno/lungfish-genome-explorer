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

    /// Date the bundle was created.
    public let createdDate: Date

    /// Date the bundle was last modified.
    public let modifiedDate: Date

    // MARK: - Source Information

    /// Information about the source of the genome data.
    public let source: SourceInfo

    // MARK: - Genome Content

    /// Information about the reference genome sequence.
    public let genome: GenomeInfo

    /// Annotation tracks in the bundle.
    public let annotations: [AnnotationTrackInfo]

    /// Variant tracks in the bundle.
    public let variants: [VariantTrackInfo]

    /// Signal tracks (BigWig) in the bundle.
    public let tracks: [SignalTrackInfo]

    // MARK: - Initialization

    /// Creates a new bundle manifest.
    public init(
        formatVersion: String = "1.0",
        name: String,
        identifier: String,
        description: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        source: SourceInfo,
        genome: GenomeInfo,
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        tracks: [SignalTrackInfo] = []
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.identifier = identifier
        self.description = description
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.source = source
        self.genome = genome
        self.annotations = annotations
        self.variants = variants
        self.tracks = tracks
    }

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case name
        case identifier
        case description
        case createdDate = "created_date"
        case modifiedDate = "modified_date"
        case source
        case genome
        case annotations
        case variants
        case tracks
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

    /// Creates chromosome information.
    public init(
        name: String,
        length: Int64,
        offset: Int64,
        lineBases: Int,
        lineWidth: Int,
        aliases: [String] = [],
        isPrimary: Bool = true,
        isMitochondrial: Bool = false
    ) {
        self.name = name
        self.length = length
        self.offset = offset
        self.lineBases = lineBases
        self.lineWidth = lineWidth
        self.aliases = aliases
        self.isPrimary = isPrimary
        self.isMitochondrial = isMitochondrial
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

    /// Saves the manifest to a bundle directory.
    ///
    /// - Parameter bundleURL: URL to the `.lungfishref` bundle directory
    /// - Throws: If the manifest cannot be encoded or written
    public func save(to bundleURL: URL) throws {
        let manifestURL = bundleURL.appendingPathComponent(Self.filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(self)
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
        if genome.path.isEmpty {
            errors.append(.missingField("genome.path"))
        }
        if genome.indexPath.isEmpty {
            errors.append(.missingField("genome.indexPath"))
        }
        if genome.chromosomes.isEmpty {
            errors.append(.missingField("genome.chromosomes"))
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
