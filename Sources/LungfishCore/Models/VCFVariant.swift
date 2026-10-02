// VCFVariant.swift - A single variant from a VCF file
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
