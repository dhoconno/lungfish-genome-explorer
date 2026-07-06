// VariantTrack.swift - VCF variant track data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VCFVariant

/// A single variant from a VCF file.
///
/// Represents a genomic variant including SNPs, insertions, deletions, and complex
/// variants. Follows the VCF 4.3 specification for variant representation.
///
/// ## Coordinate System
/// Positions are 1-based as per VCF specification. When converting to
/// `SequenceAnnotation` for rendering, positions are adjusted to 0-based coordinates.
///
/// ## Example
/// ```swift
/// // SNP at position 12345
/// let snp = VCFVariant(
///     chromosome: "chr1",
///     position: 12345,
///     reference: "A",
///     alternates: ["G"],
///     quality: 30.0,
///     filter: "PASS",
///     info: ["DP": "50", "AF": "0.25"]
/// )
///
/// // Deletion
/// let deletion = VCFVariant(
///     chromosome: "chr1",
///     position: 20000,
///     reference: "ATCG",
///     alternates: ["A"],
///     quality: 25.0
/// )
/// ```
public struct VCFVariant: Identifiable, Codable, Sendable, Hashable {

    // MARK: - Properties

    /// Unique identifier for this variant
    public let id: UUID

    /// Chromosome or contig name (CHROM field in VCF)
    public let chromosome: String

    /// 1-based position on the chromosome (POS field in VCF)
    ///
    /// This follows VCF convention where positions are 1-based.
    /// For indels, this is the position of the base preceding the variant.
    public let position: Int

    /// Variant identifier (ID field in VCF, e.g., rsID)
    public let variantID: String?

    /// Reference allele (REF field in VCF)
    ///
    /// Must be a non-empty string of A, C, G, T, or N characters.
    public let reference: String

    /// Alternate alleles (ALT field in VCF)
    ///
    /// Can contain multiple alternates for multi-allelic sites.
    /// May be empty for monomorphic reference sites.
    public let alternates: [String]

    /// Phred-scaled quality score (QUAL field in VCF)
    ///
    /// Higher values indicate higher confidence in the variant call.
    /// A value of nil indicates the quality is unknown or not applicable.
    public let quality: Double?

    /// Filter status (FILTER field in VCF)
    ///
    /// - "PASS" indicates the variant passed all filters
    /// - nil indicates filters were not applied
    /// - Other values indicate which filter(s) failed
    public let filter: String?

    /// INFO field key-value pairs
    ///
    /// Common fields include:
    /// - "DP": Total read depth
    /// - "AF": Allele frequency
    /// - "AN": Total number of alleles
    /// - "AC": Allele count
    public let info: [String: String]

    /// Sample genotype data (FORMAT and sample columns)
    ///
    /// Each key is a sample name, value is a dictionary of format fields.
    /// Common format fields include GT (genotype), DP (depth), GQ (genotype quality).
    public let sampleData: [String: [String: String]]

    // MARK: - Initialization

    /// Creates a new VCF variant.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - chromosome: Chromosome or contig name
    ///   - position: 1-based position on the chromosome
    ///   - variantID: Optional variant identifier (e.g., rsID)
    ///   - reference: Reference allele
    ///   - alternates: Alternate allele(s)
    ///   - quality: Phred-scaled quality score
    ///   - filter: Filter status ("PASS", filter name, or nil)
    ///   - info: INFO field key-value pairs
    ///   - sampleData: Per-sample genotype data
    public init(
        id: UUID = UUID(),
        chromosome: String,
        position: Int,
        variantID: String? = nil,
        reference: String,
        alternates: [String],
        quality: Double? = nil,
        filter: String? = nil,
        info: [String: String] = [:],
        sampleData: [String: [String: String]] = [:]
    ) {
        precondition(position >= 1, "VCF position must be 1-based (>= 1)")
        precondition(!reference.isEmpty, "Reference allele cannot be empty")

        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.variantID = variantID
        self.reference = reference
        self.alternates = alternates
        self.quality = quality
        self.filter = filter
        self.info = info
        self.sampleData = sampleData
    }

    // MARK: - Computed Properties

    /// The type of variant based on reference and alternate alleles.
    ///
    /// For multi-allelic sites, examines all alternate alleles:
    /// - All same length as REF and single-base: SNP
    /// - All same length as REF and multi-base: MNP
    /// - All longer than REF: insertion
    /// - All shorter than REF: deletion
    /// - Mixed lengths: complex
    public var variantType: VariantType {
        let nonEmpty = alternates.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            return .reference
        }

        let refLen = reference.count
        var hasEqual = false
        var hasLonger = false
        var hasShorter = false

        for alt in nonEmpty {
            let altLen = alt.count
            if altLen == refLen {
                hasEqual = true
            } else if altLen > refLen {
                hasLonger = true
            } else {
                hasShorter = true
            }
        }

        // Mixed length classes means complex
        let classes = [hasEqual, hasLonger, hasShorter].filter { $0 }.count
        if classes > 1 {
            return .complex
        }

        if hasLonger {
            return .insertion
        }
        if hasShorter {
            return .deletion
        }

        // All alternates are same length as reference
        if refLen == 1 {
            return .snp
        }
        return .mnp
    }

    /// The length of the variant in reference coordinates.
    ///
    /// For SNPs, this is 1. For indels, this is the length of the reference allele.
    public var referenceLength: Int {
        reference.count
    }

    /// The 0-based start position (for internal coordinate conversion).
    public var zeroBasedStart: Int {
        position - 1
    }

    /// The 0-based end position (exclusive).
    public var zeroBasedEnd: Int {
        zeroBasedStart + referenceLength
    }

    /// Whether this variant passed all filters.
    public var passedFilters: Bool {
        filter == "PASS" || filter == "."
    }

    /// A display label for the variant.
    public var displayLabel: String {
        if let vid = variantID, !vid.isEmpty && vid != "." {
            return vid
        }
        return "\(reference)>\(alternates.joined(separator: ","))"
    }

    /// Retrieves an INFO field value.
    ///
    /// - Parameter key: The INFO field key
    /// - Returns: The value if present, nil otherwise
    public func infoValue(_ key: String) -> String? {
        info[key]
    }

    /// Retrieves an INFO field value as a Double.
    ///
    /// - Parameter key: The INFO field key
    /// - Returns: The numeric value if present and parseable, nil otherwise
    public func infoDouble(_ key: String) -> Double? {
        guard let value = info[key] else { return nil }
        return Double(value)
    }

    /// Retrieves an INFO field value as an Int.
    ///
    /// - Parameter key: The INFO field key
    /// - Returns: The integer value if present and parseable, nil otherwise
    public func infoInt(_ key: String) -> Int? {
        guard let value = info[key] else { return nil }
        return Int(value)
    }
}

// MARK: - VariantType

/// Classification of variant types.
public enum VariantType: String, Codable, Sendable, CaseIterable {
    /// Single nucleotide polymorphism (A>G)
    case snp = "SNP"

    /// Multi-nucleotide polymorphism (AT>GC)
    case mnp = "MNP"

    /// Insertion (A>ATG)
    case insertion = "INS"

    /// Deletion (ATG>A)
    case deletion = "DEL"

    /// Complex variant (multiple changes)
    case complex = "COMPLEX"

    /// Reference/monomorphic site
    case reference = "REF"

    /// Default color for this variant type (IGV-inspired colors).
    public var defaultColor: AnnotationColor {
        switch self {
        case .snp:
            // Green for SNPs (IGV default)
            return AnnotationColor(red: 0.0, green: 0.6, blue: 0.0)
        case .mnp:
            // Blue-green for MNPs
            return AnnotationColor(red: 0.0, green: 0.5, blue: 0.5)
        case .insertion:
            // Purple/magenta for insertions (IGV default)
            return AnnotationColor(red: 0.6, green: 0.0, blue: 0.6)
        case .deletion:
            // Red for deletions (IGV default)
            return AnnotationColor(red: 0.8, green: 0.0, blue: 0.0)
        case .complex:
            // Orange for complex variants
            return AnnotationColor(red: 0.9, green: 0.5, blue: 0.0)
        case .reference:
            // Gray for reference sites
            return AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
        }
    }

    /// User-friendly description of the variant type.
    public var displayName: String {
        switch self {
        case .snp: return "Single Nucleotide Polymorphism"
        case .mnp: return "Multi-Nucleotide Polymorphism"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .complex: return "Complex Variant"
        case .reference: return "Reference"
        }
    }
}

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

// MARK: - VariantTrackDisplaySettings

/// Display settings for variant track visualization.
public struct VariantTrackDisplaySettings: Sendable {

    /// Color scheme for variant rendering
    public var colorScheme: VariantColorScheme

    /// Custom colors per variant type (overrides scheme)
    public var customColors: [VariantType: AnnotationColor]

    /// Track height in pixels
    public var trackHeight: Double

    /// Whether to show variant labels
    public var showLabels: Bool

    /// Minimum quality score to display
    public var minQualityFilter: Double?

    /// Variant types to show (nil = all)
    public var visibleTypes: Set<VariantType>?

    /// Whether to show only passing variants
    public var showOnlyPassing: Bool

    /// Creates default display settings.
    public init(
        colorScheme: VariantColorScheme = .byType,
        customColors: [VariantType: AnnotationColor] = [:],
        trackHeight: Double = 20.0,
        showLabels: Bool = true,
        minQualityFilter: Double? = nil,
        visibleTypes: Set<VariantType>? = nil,
        showOnlyPassing: Bool = false
    ) {
        self.colorScheme = colorScheme
        self.customColors = customColors
        self.trackHeight = trackHeight
        self.showLabels = showLabels
        self.minQualityFilter = minQualityFilter
        self.visibleTypes = visibleTypes
        self.showOnlyPassing = showOnlyPassing
    }
}

// MARK: - VariantColorScheme

/// Color schemes for variant visualization.
public enum VariantColorScheme: String, Sendable, CaseIterable {
    /// Color by variant type (SNP, indel, etc.)
    case byType

    /// Color by quality score (gradient)
    case byQuality

    /// Color by allele frequency
    case byFrequency

    /// Single color for all variants
    case uniform
}

// MARK: - VCFMetadata

/// Metadata from VCF file header.
public struct VCFMetadata: Sendable {

    /// VCF format version
    public var fileFormat: String?

    /// File date
    public var fileDate: String?

    /// Reference genome used
    public var reference: String?

    /// Contig/chromosome definitions
    public var contigs: [ContigInfo]

    /// INFO field definitions
    public var infoFields: [String: FieldDefinition]

    /// FORMAT field definitions
    public var formatFields: [String: FieldDefinition]

    /// FILTER definitions
    public var filters: [String: String]

    /// Source program
    public var source: String?

    /// Creates empty metadata.
    public init(
        fileFormat: String? = nil,
        fileDate: String? = nil,
        reference: String? = nil,
        contigs: [ContigInfo] = [],
        infoFields: [String: FieldDefinition] = [:],
        formatFields: [String: FieldDefinition] = [:],
        filters: [String: String] = [:],
        source: String? = nil
    ) {
        self.fileFormat = fileFormat
        self.fileDate = fileDate
        self.reference = reference
        self.contigs = contigs
        self.infoFields = infoFields
        self.formatFields = formatFields
        self.filters = filters
        self.source = source
    }
}

// MARK: - ContigInfo

/// Information about a contig/chromosome from VCF header.
public struct ContigInfo: Sendable, Identifiable {
    public var id: String { name }

    /// Contig name
    public let name: String

    /// Contig length in base pairs
    public let length: Int?

    /// Assembly identifier
    public let assembly: String?

    public init(name: String, length: Int? = nil, assembly: String? = nil) {
        self.name = name
        self.length = length
        self.assembly = assembly
    }
}

// MARK: - FieldDefinition

/// Definition of an INFO or FORMAT field from VCF header.
public struct FieldDefinition: Sendable {

    /// Field identifier
    public let id: String

    /// Number of values (A=per-alt, R=per-allele, G=per-genotype, .=variable)
    public let number: String

    /// Data type (Integer, Float, Flag, Character, String)
    public let type: String

    /// Field description
    public let description: String

    /// Source (for INFO fields)
    public let source: String?

    /// Version (for INFO fields)
    public let version: String?

    public init(
        id: String,
        number: String,
        type: String,
        description: String,
        source: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.number = number
        self.type = type
        self.description = description
        self.source = source
        self.version = version
    }
}

// MARK: - VCFVariant to SequenceAnnotation Extension

extension VCFVariant {

    /// Converts this variant to a sequence annotation for rendering.
    ///
    /// The annotation uses existing annotation types and colors to integrate
    /// with the standard rendering system.
    ///
    /// - Parameters:
    ///   - colorScheme: The color scheme to use
    ///   - customColors: Custom colors per variant type
    /// - Returns: A `SequenceAnnotation` representing this variant
    public func toAnnotation(
        colorScheme: VariantColorScheme = .byType,
        customColors: [VariantType: AnnotationColor] = [:]
    ) -> SequenceAnnotation {
        // Map variant type to annotation type
        let annotationType: AnnotationType
        switch variantType {
        case .snp:
            annotationType = .snp
        case .insertion:
            annotationType = .insertion
        case .deletion:
            annotationType = .deletion
        default:
            annotationType = .variation
        }

        // Determine color
        let color: AnnotationColor
        if let customColor = customColors[variantType] {
            color = customColor
        } else {
            switch colorScheme {
            case .byType:
                color = variantType.defaultColor
            case .byQuality:
                color = qualityToColor(quality)
            case .byFrequency:
                let af = infoDouble("AF") ?? 0.5
                color = frequencyToColor(af)
            case .uniform:
                color = AnnotationColor(red: 0.3, green: 0.3, blue: 0.7)
            }
        }

        // Build qualifiers from INFO fields
        var qualifiers: [String: AnnotationQualifier] = [:]
        qualifiers["variant_type"] = AnnotationQualifier(variantType.rawValue)
        qualifiers["ref"] = AnnotationQualifier(reference)
        qualifiers["alt"] = AnnotationQualifier(alternates.joined(separator: ","))

        if let q = quality {
            qualifiers["quality"] = AnnotationQualifier(String(format: "%.2f", q))
        }
        if let f = filter {
            qualifiers["filter"] = AnnotationQualifier(f)
        }
        for (key, value) in info {
            qualifiers["info_\(key)"] = AnnotationQualifier(value)
        }

        // Build note/description
        var noteComponents: [String] = []
        noteComponents.append("\(variantType.displayName): \(reference) > \(alternates.joined(separator: ", "))")
        if let q = quality {
            noteComponents.append("Quality: \(String(format: "%.1f", q))")
        }
        if let f = filter, f != "." {
            noteComponents.append("Filter: \(f)")
        }
        let note = noteComponents.joined(separator: "\n")

        return SequenceAnnotation(
            id: id,
            type: annotationType,
            name: displayLabel,
            chromosome: chromosome,
            start: zeroBasedStart,
            end: zeroBasedEnd,
            strand: .unknown,
            qualifiers: qualifiers,
            color: color,
            note: note
        )
    }

    /// Converts quality score to a color (gradient from red to green).
    private func qualityToColor(_ quality: Double?) -> AnnotationColor {
        guard let q = quality else {
            return AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        // Normalize quality (0-60 scale)
        let normalized = min(1.0, max(0.0, q / 60.0))
        return AnnotationColor(
            red: 1.0 - normalized,
            green: normalized,
            blue: 0.0
        )
    }

    /// Converts allele frequency to a color (gradient from blue to red).
    private func frequencyToColor(_ frequency: Double) -> AnnotationColor {
        let f = min(1.0, max(0.0, frequency))
        return AnnotationColor(
            red: f,
            green: 0.0,
            blue: 1.0 - f
        )
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

// MARK: - VariantTrackDisplaySettings Codable

// Hand-rolled Codable is REQUIRED here: the VariantType-keyed `customColors`
// dictionary and the `visibleTypes` Set must serialize using VariantType's
// String rawValues rather than the synthesized (non-String-keyed) form.
extension VariantTrackDisplaySettings: Codable {

    enum CodingKeys: String, CodingKey {
        case colorScheme
        case customColors
        case trackHeight
        case showLabels
        case minQualityFilter
        case visibleTypes
        case showOnlyPassing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorScheme = try container.decode(VariantColorScheme.self, forKey: .colorScheme)

        // Decode custom colors with String keys, convert to VariantType
        let stringColors = try container.decodeIfPresent(
            [String: AnnotationColor].self,
            forKey: .customColors
        ) ?? [:]
        customColors = Dictionary(uniqueKeysWithValues: stringColors.compactMap { key, value in
            guard let variantType = VariantType(rawValue: key) else { return nil }
            return (variantType, value)
        })

        trackHeight = try container.decode(Double.self, forKey: .trackHeight)
        showLabels = try container.decode(Bool.self, forKey: .showLabels)
        minQualityFilter = try container.decodeIfPresent(Double.self, forKey: .minQualityFilter)

        // Decode visible types
        if let typeStrings = try container.decodeIfPresent([String].self, forKey: .visibleTypes) {
            visibleTypes = Set(typeStrings.compactMap { VariantType(rawValue: $0) })
        } else {
            visibleTypes = nil
        }

        showOnlyPassing = try container.decode(Bool.self, forKey: .showOnlyPassing)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorScheme, forKey: .colorScheme)

        // Encode custom colors with String keys
        let stringColors = Dictionary(uniqueKeysWithValues: customColors.map { ($0.key.rawValue, $0.value) })
        try container.encode(stringColors, forKey: .customColors)

        try container.encode(trackHeight, forKey: .trackHeight)
        try container.encode(showLabels, forKey: .showLabels)
        try container.encodeIfPresent(minQualityFilter, forKey: .minQualityFilter)

        // Encode visible types
        if let types = visibleTypes {
            try container.encode(types.map(\.rawValue), forKey: .visibleTypes)
        } else {
            try container.encodeNil(forKey: .visibleTypes)
        }

        try container.encode(showOnlyPassing, forKey: .showOnlyPassing)
    }
}

// MARK: - VCFMetadata Codable

extension VCFMetadata: Codable {}
extension ContigInfo: Codable {}
extension FieldDefinition: Codable {}
extension VariantColorScheme: Codable {}
