// BundleManifest.swift - Reference genome bundle manifest data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Declares an indexed record-level metadata store embedded in a reference bundle.
public struct ReferenceRecordStoreInfo: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let format: String
    public let databasePath: String
    public let recordCount: Int

    public init(schemaVersion: Int, format: String, databasePath: String, recordCount: Int) {
        self.schemaVersion = schemaVersion
        self.format = format
        self.databasePath = databasePath
        self.recordCount = recordCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case format
        case databasePath = "database_path"
        case recordCount = "record_count"
    }
}

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
/// │   ├── snps.bcf                     # Variant payload
/// │   ├── snps.bcf.csi                 # CSI index when BCF is present
/// │   └── snps.sqlite                  # Optional SQLite sidecar for app queries
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

    /// Optional indexed record-level metadata store, such as one produced from GenBank.
    public let recordStore: ReferenceRecordStoreInfo?

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

    /// Hand-rolled equality. Instead of comparing the stored `browserSummary`
    /// directly, it compares `equivalentBrowserSummary` (the stored summary, or
    /// the one synthesized from genome/track counts when absent). Two manifests
    /// are therefore equal when their *effective* summaries match, so a manifest
    /// with a cached summary equals an otherwise-identical one that would
    /// synthesize the same summary. Synthesized `Equatable` would compare the raw
    /// stored `browserSummary` and is therefore unacceptable here.
    public static func == (lhs: BundleManifest, rhs: BundleManifest) -> Bool {
        lhs.formatVersion == rhs.formatVersion
            && lhs.name == rhs.name
            && lhs.identifier == rhs.identifier
            && lhs.description == rhs.description
            && lhs.originBundlePath == rhs.originBundlePath
            && lhs.createdDate == rhs.createdDate
            && lhs.modifiedDate == rhs.modifiedDate
            && lhs.source == rhs.source
            && lhs.genome == rhs.genome
            && lhs.recordStore == rhs.recordStore
            && lhs.annotations == rhs.annotations
            && lhs.variants == rhs.variants
            && lhs.tracks == rhs.tracks
            && lhs.alignments == rhs.alignments
            && lhs.metadata == rhs.metadata
            && lhs.equivalentBrowserSummary == rhs.equivalentBrowserSummary
    }

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
        browserSummary: BundleBrowserSummary? = nil,
        recordStore: ReferenceRecordStoreInfo?
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
        self.recordStore = recordStore
        self.annotations = annotations
        self.variants = variants
        self.tracks = tracks
        self.alignments = alignments
        self.metadata = metadata
        self.browserSummary = browserSummary
    }

    /// Backward-compatible initializer for manifests without a record store.
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
            browserSummary: browserSummary,
            recordStore: nil
        )
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
        browserSummary: BundleBrowserSummary? = nil,
        recordStore: ReferenceRecordStoreInfo?
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
            browserSummary: browserSummary,
            recordStore: recordStore
        )
    }

    /// Backward-compatible initializer preserved for existing call sites that
    /// do not supply `originBundlePath` or a record store.
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
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: source,
            genome: genome,
            annotations: annotations,
            variants: variants,
            tracks: tracks,
            alignments: alignments,
            metadata: metadata,
            browserSummary: browserSummary,
            recordStore: nil
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
        metadata: [MetadataGroup]? = nil,
        recordStore: ReferenceRecordStoreInfo?
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
            browserSummary: nil,
            recordStore: recordStore
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
            browserSummary: nil,
            recordStore: nil
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
        metadata: [MetadataGroup]? = nil,
        recordStore: ReferenceRecordStoreInfo?
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
            browserSummary: nil,
            recordStore: recordStore
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
            browserSummary: nil,
            recordStore: nil
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
        case recordStore = "record_store"
        case annotations
        case variants
        case tracks
        case alignments
        case metadata
        case browserSummary = "browser_summary"
    }

    // MARK: - Backward-Compatible Decoding

    /// Custom decoder whose only backward-compat behavior over synthesized `Codable`
    /// is defaulting `alignments` to `[]` when the key is absent (manifests created
    /// before the `alignments` field existed). Every other key mirrors synthesized
    /// decoding behavior.
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
        recordStore = try container.decodeIfPresent(ReferenceRecordStoreInfo.self, forKey: .recordStore)
        annotations = try container.decode([AnnotationTrackInfo].self, forKey: .annotations)
        variants = try container.decode([VariantTrackInfo].self, forKey: .variants)
        tracks = try container.decode([SignalTrackInfo].self, forKey: .tracks)
        alignments = try container.decodeIfPresent([AlignmentTrackInfo].self, forKey: .alignments) ?? []
        metadata = try container.decodeIfPresent([MetadataGroup].self, forKey: .metadata)
        browserSummary = try container.decodeIfPresent(BundleBrowserSummary.self, forKey: .browserSummary)
    }
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

    /// Returns a copy of this manifest with the given fields overridden.
    ///
    /// Every parameter defaults to the current property value, so callers only
    /// specify the fields that change. This threads the ~15 initializer arguments
    /// in one place; the immutable-update helpers below own their own semantics
    /// (whether to reset `browserSummary` and bump `modifiedDate`) by passing
    /// those fields explicitly.
    private func copy(
        formatVersion: String? = nil,
        name: String? = nil,
        identifier: String? = nil,
        description: String?? = nil,
        originBundlePath: String?? = nil,
        createdDate: Date? = nil,
        modifiedDate: Date? = nil,
        source: SourceInfo? = nil,
        genome: GenomeInfo?? = nil,
        annotations: [AnnotationTrackInfo]? = nil,
        variants: [VariantTrackInfo]? = nil,
        tracks: [SignalTrackInfo]? = nil,
        alignments: [AlignmentTrackInfo]? = nil,
        metadata: [MetadataGroup]?? = nil,
        browserSummary: BundleBrowserSummary?? = nil,
        recordStore: ReferenceRecordStoreInfo?? = nil
    ) -> BundleManifest {
        BundleManifest(
            formatVersion: formatVersion ?? self.formatVersion,
            name: name ?? self.name,
            identifier: identifier ?? self.identifier,
            description: description ?? self.description,
            originBundlePath: originBundlePath ?? self.originBundlePath,
            createdDate: createdDate ?? self.createdDate,
            modifiedDate: modifiedDate ?? self.modifiedDate,
            source: source ?? self.source,
            genome: genome ?? self.genome,
            annotations: annotations ?? self.annotations,
            variants: variants ?? self.variants,
            tracks: tracks ?? self.tracks,
            alignments: alignments ?? self.alignments,
            metadata: metadata ?? self.metadata,
            browserSummary: browserSummary ?? self.browserSummary,
            recordStore: recordStore ?? self.recordStore
        )
    }

    /// Returns a new manifest with the given variant track appended.
    public func addingVariantTrack(_ track: VariantTrackInfo) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(modifiedDate: Date(), variants: variants + [track], browserSummary: .some(nil))
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
        // Mutators reset the cached browser summary and bump the modified date.
        return copy(modifiedDate: Date(), variants: updatedVariants, browserSummary: .some(nil))
    }

    /// Returns a new manifest with the given annotation track appended.
    public func addingAnnotationTrack(_ track: AnnotationTrackInfo) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(modifiedDate: Date(), annotations: annotations + [track], browserSummary: .some(nil))
    }

    /// Returns a new manifest with the specified annotation track removed.
    public func removingAnnotationTrack(id: String) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(
            modifiedDate: Date(),
            annotations: annotations.filter { $0.id != id },
            browserSummary: .some(nil)
        )
    }

    /// Returns a new manifest with an existing annotation track replaced.
    public func replacingAnnotationTrack(_ replacement: AnnotationTrackInfo) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(
            modifiedDate: Date(),
            annotations: annotations.map { $0.id == replacement.id ? replacement : $0 },
            browserSummary: .some(nil)
        )
    }

    /// Returns a new manifest with the given alignment track appended.
    public func addingAlignmentTrack(_ track: AlignmentTrackInfo) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(modifiedDate: Date(), alignments: alignments + [track], browserSummary: .some(nil))
    }

    /// Returns a new manifest with the specified alignment track removed.
    public func removingAlignmentTrack(id: String) -> BundleManifest {
        // Mutators reset the cached browser summary and bump the modified date.
        copy(
            modifiedDate: Date(),
            alignments: alignments.filter { $0.id != id },
            browserSummary: .some(nil)
        )
    }

    // Used only by Equatable; see ==
    private var equivalentBrowserSummary: BundleBrowserSummary? {
        browserSummary ?? synthesizedBrowserSummary()
    }

    private func synthesizedBrowserSummary() -> BundleBrowserSummary? {
        guard let genome else { return nil }

        let mappedReadCounts = alignments.compactMap(\.mappedReadCount)
        let totalMappedReads = mappedReadCounts.isEmpty ? nil : mappedReadCounts.reduce(0, +)
        return BundleBrowserSummary(
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
    }

    public func withSynthesizedBrowserSummaryIfNeeded() -> BundleManifest {
        guard browserSummary == nil, let synthesized = synthesizedBrowserSummary() else { return self }

        // Unlike the mutators, this keeps `modifiedDate` and sets the synthesized
        // summary rather than clearing it.
        return copy(browserSummary: .some(synthesized))
    }

    public func save(to bundleURL: URL) throws {
        let manifestURL = bundleURL.appendingPathComponent(Self.filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(withSynthesizedBrowserSummaryIfNeeded())
        try data.write(to: manifestURL, options: .atomic)
    }
}
