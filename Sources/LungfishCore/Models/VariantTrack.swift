// VariantTrack.swift - VCF variant track data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VariantTrack

/// A track containing VCF variants associated with a sequence.
///
/// `VariantTrack` represents a collection of variants loaded from a VCF file
/// that can be visualized alongside sequence data. Variants can be converted
/// to `SequenceAnnotation` objects for rendering using the existing annotation
/// rendering system.
///
/// ## Association with Sequences
/// A track can be associated with:
/// - A specific sequence by setting `sequenceName`
/// - All sequences by leaving `sequenceName` as nil
///
/// ## Rendering
/// Use `toAnnotations()` to convert variants to annotations for display.
/// Colors are automatically assigned based on variant type.
///
/// ## Example
/// ```swift
/// var track = VariantTrack(name: "Sample1 Variants")
/// track.variants = loadedVariants
/// track.sequenceName = "chr1"
///
/// // Convert to annotations for rendering
/// let annotations = track.toAnnotations()
/// ```
public struct VariantTrack: Identifiable, Sendable {

    // MARK: - Properties

    /// Unique identifier for this track
    public let id: UUID

    /// Display name for the track
    public var name: String

    /// URL of the source VCF file, if loaded from disk
    public let sourceURL: URL?

    /// The variants in this track
    public var variants: [VCFVariant]

    /// Whether this track is currently visible
    public var isVisible: Bool

    /// The sequence this track is associated with.
    ///
    /// If nil, the track applies to all sequences (variants are filtered
    /// by their chromosome field when rendering).
    public var sequenceName: String?

    /// Custom display settings for this track
    public var displaySettings: VariantTrackDisplaySettings

    /// VCF file header metadata
    public var metadata: VCFMetadata?

    // MARK: - Initialization

    /// Creates a new variant track.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - name: Display name for the track
    ///   - sourceURL: URL of the source VCF file
    ///   - variants: Initial variants (default empty)
    ///   - isVisible: Initial visibility state (default true)
    ///   - sequenceName: Associated sequence name (nil for all sequences)
    ///   - displaySettings: Custom display settings
    ///   - metadata: VCF file header metadata
    public init(
        id: UUID = UUID(),
        name: String,
        sourceURL: URL? = nil,
        variants: [VCFVariant] = [],
        isVisible: Bool = true,
        sequenceName: String? = nil,
        displaySettings: VariantTrackDisplaySettings = VariantTrackDisplaySettings(),
        metadata: VCFMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.variants = variants
        self.isVisible = isVisible
        self.sequenceName = sequenceName
        self.displaySettings = displaySettings
        self.metadata = metadata
    }

    // MARK: - Computed Properties

    /// Number of variants in this track
    public var variantCount: Int {
        variants.count
    }

    /// Whether this track has any variants
    public var isEmpty: Bool {
        variants.isEmpty
    }

    /// All unique chromosomes/contigs represented in this track
    public var chromosomes: Set<String> {
        Set(variants.map(\.chromosome))
    }

    /// Sample names from variant genotype data
    public var sampleNames: [String] {
        guard let first = variants.first else { return [] }
        return Array(first.sampleData.keys).sorted()
    }

    // MARK: - Filtering Methods

    /// Returns variants for a specific chromosome/sequence.
    ///
    /// - Parameter chromosome: The chromosome name to filter by
    /// - Returns: Array of variants on the specified chromosome
    public func variants(forChromosome chromosome: String) -> [VCFVariant] {
        variants.filter { $0.chromosome == chromosome }
    }

    /// Returns variants within a genomic region.
    ///
    /// - Parameters:
    ///   - chromosome: The chromosome name
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of variants overlapping the region
    public func variants(inRegion chromosome: String, start: Int, end: Int) -> [VCFVariant] {
        variants.filter { variant in
            variant.chromosome == chromosome &&
            variant.zeroBasedEnd > start &&
            variant.zeroBasedStart < end
        }
    }

    /// Returns variants that passed all filters.
    public func passingVariants() -> [VCFVariant] {
        variants.filter(\.passedFilters)
    }

    /// Returns variants of a specific type.
    ///
    /// - Parameter type: The variant type to filter by
    /// - Returns: Array of variants matching the type
    public func variants(ofType type: VariantType) -> [VCFVariant] {
        variants.filter { $0.variantType == type }
    }

    /// Returns variants with quality score above a threshold.
    ///
    /// - Parameter minQuality: Minimum quality score
    /// - Returns: Array of variants meeting the quality threshold
    public func variants(minQuality: Double) -> [VCFVariant] {
        variants.filter { ($0.quality ?? 0) >= minQuality }
    }

    // MARK: - Annotation Conversion

    /// Converts all variants to sequence annotations for rendering.
    ///
    /// Each variant is converted to a `SequenceAnnotation` with appropriate
    /// type and color based on the variant type. This allows variants to be
    /// rendered using the existing annotation rendering system.
    ///
    /// - Returns: Array of annotations representing the variants
    public func toAnnotations() -> [SequenceAnnotation] {
        variants.map { variant in
            variant.toAnnotation(
                colorScheme: displaySettings.colorScheme,
                customColors: displaySettings.customColors
            )
        }
    }

    /// Converts variants for a specific chromosome to annotations.
    ///
    /// - Parameter chromosome: The chromosome to filter by
    /// - Returns: Array of annotations for variants on that chromosome
    public func toAnnotations(forChromosome chromosome: String) -> [SequenceAnnotation] {
        variants(forChromosome: chromosome).map { variant in
            variant.toAnnotation(
                colorScheme: displaySettings.colorScheme,
                customColors: displaySettings.customColors
            )
        }
    }

    /// Converts variants in a region to annotations.
    ///
    /// - Parameters:
    ///   - chromosome: The chromosome name
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of annotations for variants in the region
    public func toAnnotations(inRegion chromosome: String, start: Int, end: Int) -> [SequenceAnnotation] {
        variants(inRegion: chromosome, start: start, end: end).map { variant in
            variant.toAnnotation(
                colorScheme: displaySettings.colorScheme,
                customColors: displaySettings.customColors
            )
        }
    }
}

// MARK: - VariantTrack Codable Extension

extension VariantTrack: Codable {

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceURL
        case variants
        case isVisible
        case sequenceName
        case displaySettings
        case metadata
    }

    /// Hand-rolled decode: the tolerant `displaySettings ?? VariantTrackDisplaySettings()`
    /// fallback is load-bearing so older persisted payloads that predate the
    /// `displaySettings` key still decode successfully.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        variants = try container.decode([VCFVariant].self, forKey: .variants)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        sequenceName = try container.decodeIfPresent(String.self, forKey: .sequenceName)
        displaySettings = try container.decodeIfPresent(
            VariantTrackDisplaySettings.self,
            forKey: .displaySettings
        ) ?? VariantTrackDisplaySettings()
        metadata = try container.decodeIfPresent(VCFMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(variants, forKey: .variants)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encodeIfPresent(sequenceName, forKey: .sequenceName)
        try container.encode(displaySettings, forKey: .displaySettings)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}
