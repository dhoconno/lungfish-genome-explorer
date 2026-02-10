// SequenceAnnotation.swift - Feature annotations with qualifiers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A feature annotation on a sequence.
///
/// Annotations represent features like genes, CDS, primers, restriction sites, etc.
/// They support discontinuous features (like intron-containing genes) through
/// multiple intervals.
///
/// ## Example
/// ```swift
/// let annotation = SequenceAnnotation(
///     type: .gene,
///     name: "BRCA1",
///     chromosome: "chr17",
///     intervals: [
///         AnnotationInterval(start: 1000, end: 2000),
///         AnnotationInterval(start: 3000, end: 4000)
///     ],
///     strand: .forward
/// )
/// ```
public struct SequenceAnnotation: Identifiable, Codable, Sendable {
    /// Unique identifier
    public let id: UUID

    /// Type of feature
    public var type: AnnotationType

    /// Feature name
    public var name: String

    /// The chromosome or sequence name this annotation belongs to.
    /// Used to associate annotations with their parent sequence in multi-sequence views.
    public var chromosome: String?

    /// The intervals making up this feature (supports discontinuous features)
    public var intervals: [AnnotationInterval]

    /// Strand orientation
    public var strand: Strand

    /// GFF3/GenBank-style qualifiers
    public var qualifiers: [String: AnnotationQualifier]

    /// Optional custom color for display
    public var color: AnnotationColor?

    /// Optional note or description
    public var note: String?

    /// Parent feature ID (for hierarchical features like gene->mRNA->exon)
    public var parentID: UUID?

    /// Creates a new annotation.
    public init(
        id: UUID = UUID(),
        type: AnnotationType,
        name: String,
        chromosome: String? = nil,
        intervals: [AnnotationInterval],
        strand: Strand = .unknown,
        qualifiers: [String: AnnotationQualifier] = [:],
        color: AnnotationColor? = nil,
        note: String? = nil,
        parentID: UUID? = nil
    ) {
        precondition(!intervals.isEmpty, "Annotation must have at least one interval")
        self.id = id
        self.type = type
        self.name = name
        self.chromosome = chromosome
        self.intervals = intervals.sorted { $0.start < $1.start }
        self.strand = strand
        self.qualifiers = qualifiers
        self.color = color
        self.note = note
        self.parentID = parentID
    }

    /// Convenience initializer for single-interval features
    public init(
        id: UUID = UUID(),
        type: AnnotationType,
        name: String,
        chromosome: String? = nil,
        start: Int,
        end: Int,
        strand: Strand = .unknown,
        qualifiers: [String: AnnotationQualifier] = [:],
        color: AnnotationColor? = nil,
        note: String? = nil,
        parentID: UUID? = nil
    ) {
        self.init(
            id: id,
            type: type,
            name: name,
            chromosome: chromosome,
            intervals: [AnnotationInterval(start: start, end: end)],
            strand: strand,
            qualifiers: qualifiers,
            color: color,
            note: note,
            parentID: parentID
        )
    }

    /// The overall bounding region of this annotation
    public var boundingRegion: (start: Int, end: Int) {
        let minStart = intervals.map(\.start).min() ?? 0
        let maxEnd = intervals.map(\.end).max() ?? 0
        return (minStart, maxEnd)
    }

    /// Total length covered by all intervals
    public var totalLength: Int {
        intervals.reduce(0) { $0 + $1.length }
    }

    /// Returns the start position (leftmost coordinate)
    public var start: Int {
        boundingRegion.start
    }

    /// Returns the end position (rightmost coordinate)
    public var end: Int {
        boundingRegion.end
    }

    /// Whether this is a discontinuous feature (multiple intervals)
    public var isDiscontinuous: Bool {
        intervals.count > 1
    }

    /// Checks if this annotation overlaps a given range
    public func overlaps(start: Int, end: Int) -> Bool {
        for interval in intervals {
            if interval.start < end && interval.end > start {
                return true
            }
        }
        return false
    }

    /// Returns a qualifier value by key
    public func qualifier(_ key: String) -> String? {
        qualifiers[key]?.firstValue
    }

    /// Returns all values for a qualifier key (qualifiers can be multi-valued)
    public func qualifierValues(_ key: String) -> [String] {
        qualifiers[key]?.values ?? []
    }

    /// Checks if this annotation belongs to a sequence with the given name.
    /// Matches if the chromosome field equals the sequence name, or if chromosome is nil.
    public func belongsToSequence(named sequenceName: String) -> Bool {
        guard let chromosome = chromosome else {
            // If no chromosome is specified, annotation applies to all sequences
            return true
        }
        return chromosome == sequenceName
    }
}

// MARK: - AnnotationInterval

/// A single interval within an annotation (e.g., an exon).
public struct AnnotationInterval: Codable, Sendable, Comparable {
    /// Start position (0-based, inclusive)
    public let start: Int

    /// End position (0-based, exclusive)
    public let end: Int

    /// Optional phase for CDS features (0, 1, or 2)
    public var phase: Int?

    public init(start: Int, end: Int, phase: Int? = nil) {
        precondition(start >= 0, "Start must be non-negative")
        precondition(end >= start, "End must be >= start")
        self.start = start
        self.end = end
        self.phase = phase
    }

    /// Length of this interval
    public var length: Int {
        end - start
    }

    public static func < (lhs: AnnotationInterval, rhs: AnnotationInterval) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.end < rhs.end
    }
}

// MARK: - AnnotationType

/// Types of sequence features
public enum AnnotationType: String, Codable, Sendable, CaseIterable {
    // Gene structure
    case gene
    case mRNA
    case transcript
    case exon
    case intron
    case cds = "CDS"
    case utr5 = "5'UTR"
    case utr3 = "3'UTR"

    // Regulatory
    case promoter
    case enhancer
    case silencer
    case terminator
    case polyASignal = "polyA_signal"
    case regulatory
    case ncRNA

    // Primers and PCR
    case primer
    case primerPair = "primer_pair"
    case amplicon

    // Restriction sites
    case restrictionSite = "restriction_site"

    // Variation
    case snp = "SNP"
    case variation
    case insertion
    case deletion

    // Structural
    case repeatRegion = "repeat_region"
    case stem_loop
    case misc_feature

    // Protein processing
    case mat_peptide
    case sig_peptide
    case transit_peptide

    // Binding
    case misc_binding
    case protein_bind

    // Assembly
    case contig
    case gap
    case scaffold

    // Misc
    case region
    case source
    case custom

    /// Default color for this annotation type
    public var defaultColor: AnnotationColor {
        switch self {
        case .gene: return AnnotationColor(red: 0.2, green: 0.6, blue: 0.8)       // Blue
        case .mRNA: return AnnotationColor(red: 0.2, green: 0.5, blue: 0.9)       // Darker blue
        case .transcript: return AnnotationColor(red: 0.4, green: 0.4, blue: 0.7) // Muted indigo
        case .cds: return AnnotationColor(red: 0.8, green: 0.4, blue: 0.2)        // Orange
        case .exon: return AnnotationColor(red: 0.6, green: 0.6, blue: 0.2)       // Yellow-green
        case .intron: return AnnotationColor(red: 0.6, green: 0.5, blue: 0.4)     // Tan
        case .utr5, .utr3: return AnnotationColor(red: 0.7, green: 0.3, blue: 0.3) // Muted red
        case .region: return AnnotationColor(red: 0.55, green: 0.5, blue: 0.45)   // Warm neutral
        case .promoter: return AnnotationColor(red: 0.9, green: 0.6, blue: 0.1)   // Gold
        case .enhancer: return AnnotationColor(red: 0.85, green: 0.7, blue: 0.2)  // Amber
        case .silencer: return AnnotationColor(red: 0.7, green: 0.5, blue: 0.2)   // Brown-gold
        case .terminator: return AnnotationColor(red: 0.6, green: 0.4, blue: 0.3) // Brown
        case .polyASignal: return AnnotationColor(red: 0.8, green: 0.55, blue: 0.15) // Dark gold
        case .regulatory: return AnnotationColor(red: 0.95, green: 0.5, blue: 0.1) // Bright orange
        case .ncRNA: return AnnotationColor(red: 0.3, green: 0.7, blue: 0.5)      // Teal-green
        case .primer, .primerPair: return AnnotationColor(red: 0.2, green: 0.8, blue: 0.2)
        case .restrictionSite: return AnnotationColor(red: 0.8, green: 0.2, blue: 0.2)
        case .snp, .variation: return AnnotationColor(red: 0.8, green: 0.2, blue: 0.8)
        case .insertion: return AnnotationColor(red: 0.2, green: 0.7, blue: 0.3)  // Green
        case .deletion: return AnnotationColor(red: 0.9, green: 0.3, blue: 0.3)   // Red
        case .repeatRegion: return AnnotationColor(red: 0.6, green: 0.3, blue: 0.6) // Purple
        case .stem_loop: return AnnotationColor(red: 0.5, green: 0.6, blue: 0.4)  // Sage
        case .misc_feature: return AnnotationColor(red: 0.55, green: 0.55, blue: 0.55) // Medium gray
        case .mat_peptide: return AnnotationColor(red: 0.7, green: 0.2, blue: 0.5) // Magenta
        case .sig_peptide: return AnnotationColor(red: 0.5, green: 0.8, blue: 0.3) // Lime green
        case .transit_peptide: return AnnotationColor(red: 0.3, green: 0.5, blue: 0.7) // Steel blue
        case .misc_binding: return AnnotationColor(red: 0.6, green: 0.4, blue: 0.8) // Lavender
        case .protein_bind: return AnnotationColor(red: 0.4, green: 0.3, blue: 0.7) // Dark lavender
        case .amplicon: return AnnotationColor(red: 0.3, green: 0.6, blue: 0.3)    // Forest green
        case .contig: return AnnotationColor(red: 0.45, green: 0.45, blue: 0.55)  // Cool gray
        case .gap: return AnnotationColor(red: 0.6, green: 0.6, blue: 0.6)        // Light gray
        case .scaffold: return AnnotationColor(red: 0.5, green: 0.45, blue: 0.4)  // Warm gray
        case .source: return AnnotationColor(red: 0.4, green: 0.4, blue: 0.4)     // Dark gray
        case .custom: return AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)     // Gray
        }
    }
}

extension AnnotationType {
    /// Maps a raw type string (from GenBank/GFF3/SQLite) to an AnnotationType.
    /// Handles case-insensitive matching and common GenBank feature type names.
    public static func from(rawString: String) -> AnnotationType? {
        // Try exact rawValue match first
        if let exact = AnnotationType(rawValue: rawString) { return exact }
        // Case-insensitive match for all known types
        switch rawString.lowercased() {
        case "gene": return .gene
        case "mrna": return .mRNA
        case "transcript": return .transcript
        case "exon": return .exon
        case "intron": return .intron
        case "cds", "coding_sequence": return .cds
        case "5'utr", "five_prime_utr": return .utr5
        case "3'utr", "three_prime_utr": return .utr3
        case "promoter": return .promoter
        case "enhancer": return .enhancer
        case "silencer": return .silencer
        case "terminator": return .terminator
        case "polya_signal": return .polyASignal
        case "primer", "primer_bind": return .primer
        case "primer_pair": return .primerPair
        case "amplicon": return .amplicon
        case "restriction_site": return .restrictionSite
        case "snp": return .snp
        case "variation": return .variation
        case "insertion": return .insertion
        case "deletion": return .deletion
        case "repeat_region": return .repeatRegion
        case "stem_loop": return .stem_loop
        case "misc_feature": return .misc_feature
        case "contig": return .contig
        case "gap": return .gap
        case "scaffold": return .scaffold
        case "region": return .region
        case "source": return .source
        case "mat_peptide": return .mat_peptide
        case "sig_peptide": return .sig_peptide
        case "transit_peptide": return .transit_peptide
        case "regulatory": return .regulatory
        case "ncrna": return .ncRNA
        case "misc_binding": return .misc_binding
        case "protein_bind": return .protein_bind
        default: return nil
        }
    }
}

// MARK: - AnnotationQualifier

/// A qualifier value (can be single or multi-valued).
public struct AnnotationQualifier: Codable, Sendable {
    public let values: [String]

    public init(_ value: String) {
        self.values = [value]
    }

    public init(_ values: [String]) {
        self.values = values
    }

    public var firstValue: String? {
        values.first
    }

    public var isSingleValued: Bool {
        values.count == 1
    }
}

// MARK: - AnnotationColor

/// RGB color for annotation display.
public struct AnnotationColor: Codable, Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = max(0, min(1, red))
        self.green = max(0, min(1, green))
        self.blue = max(0, min(1, blue))
        self.alpha = max(0, min(1, alpha))
    }

    /// Creates a color from a hex string (e.g., "#FF5500" or "FF5500")
    public init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6,
              let value = UInt32(hexString, radix: 16) else {
            return nil
        }

        self.red = Double((value >> 16) & 0xFF) / 255.0
        self.green = Double((value >> 8) & 0xFF) / 255.0
        self.blue = Double(value & 0xFF) / 255.0
        self.alpha = 1.0
    }

    /// Returns the hex string representation
    public var hexString: String {
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
