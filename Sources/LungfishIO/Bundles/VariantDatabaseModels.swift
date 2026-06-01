// VariantDatabaseModels.swift - Value types for the variant database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - VariantDatabaseRecord

/// A single variant record from the SQLite database.
public struct VariantDatabaseRecord: Sendable, Equatable {
    /// Auto-increment row ID.
    public let id: Int64?

    /// Chromosome name
    public let chromosome: String

    /// 0-based start position
    public let position: Int

    /// 0-based end position (exclusive)
    public let end: Int

    /// Variant ID (rsID or generated)
    public let variantID: String

    /// Reference allele
    public let ref: String

    /// Alternate allele(s), comma-separated
    public let alt: String

    /// Variant type (SNP, INS, DEL, MNP, COMPLEX)
    public let variantType: String

    /// Quality score (PHRED-scaled), nil if unknown
    public let quality: Double?

    /// Filter status (PASS, filter name, or nil)
    public let filter: String?

    /// INFO field as raw string for optional parsing
    public let info: String?

    /// Number of samples with genotype data at this site
    public let sampleCount: Int

    public init(
        id: Int64? = nil,
        chromosome: String, position: Int, end: Int, variantID: String,
        ref: String, alt: String, variantType: String,
        quality: Double?, filter: String?, info: String?,
        sampleCount: Int = 0
    ) {
        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.end = end
        self.variantID = variantID
        self.ref = ref
        self.alt = alt
        self.variantType = variantType
        self.quality = quality
        self.filter = filter
        self.info = info
        self.sampleCount = sampleCount
    }

    /// Converts this record to a `BundleVariant` for use by the rendering pipeline.
    public func toBundleVariant() -> BundleVariant {
        BundleVariant(
            id: variantID,
            chromosome: chromosome,
            position: Int64(position),
            ref: ref,
            alt: alt.split(separator: ",").map(String.init),
            quality: quality.map { Float($0) },
            variantId: variantID,
            filter: filter
        )
    }

    /// Converts this record to a `SequenceAnnotation` for rendering in the annotation pipeline.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType: AnnotationType
        switch variantType {
        case "SNP": annotationType = .snp
        case "INS": annotationType = .insertion
        case "DEL": annotationType = .deletion
        default: annotationType = .variation
        }

        let vtype = VariantType(rawValue: variantType) ?? .complex
        let color = vtype.defaultColor

        var qualifiers: [String: AnnotationQualifier] = [:]
        qualifiers["variant_type"] = AnnotationQualifier(variantType)
        qualifiers["ref"] = AnnotationQualifier(ref)
        qualifiers["alt"] = AnnotationQualifier(alt)
        if let q = quality {
            qualifiers["quality"] = AnnotationQualifier(String(format: "%.2f", q))
        }
        if let f = filter {
            qualifiers["filter"] = AnnotationQualifier(f)
        }
        qualifiers["sample_count"] = AnnotationQualifier(String(sampleCount))
        if let rowId = id {
            qualifiers["variant_row_id"] = AnnotationQualifier(String(rowId))
        }

        let alts = alt.split(separator: ",").map(String.init)
        var noteComponents: [String] = []
        noteComponents.append("\(vtype.displayName): \(ref) > \(alts.joined(separator: ", "))")
        if let q = quality {
            noteComponents.append("Quality: \(String(format: "%.1f", q))")
        }
        if let f = filter, f != "." {
            noteComponents.append("Filter: \(f)")
        }

        return SequenceAnnotation(
            type: annotationType,
            name: variantID,
            chromosome: chromosome,
            start: position,
            end: end,
            strand: .unknown,
            qualifiers: qualifiers,
            color: color,
            note: noteComponents.joined(separator: "\n")
        )
    }
}

// MARK: - GenotypeRecord

/// A single sample genotype record from the SQLite database.
public struct GenotypeRecord: Sendable, Equatable {
    /// The variant row ID this genotype belongs to.
    public let variantRowId: Int64

    /// Sample name (matches VCF header sample column).
    public let sampleName: String

    /// Raw genotype string from GT field (e.g. "0/1", "1|1", "./.").
    public let genotype: String?

    /// First allele index (0 = ref, 1+ = alt, -1 = missing).
    public let allele1: Int

    /// Second allele index (0 = ref, 1+ = alt, -1 = missing).
    public let allele2: Int

    /// Whether the genotype is phased (| separator vs /).
    public let isPhased: Bool

    /// Read depth at this site (DP field).
    public let depth: Int?

    /// Genotype quality (GQ field).
    public let genotypeQuality: Int?

    /// Allele depths as comma-separated string (AD field).
    public let alleleDepths: String?

    /// All FORMAT fields as semicolon-delimited key=value pairs.
    public let rawFields: String?

    public init(
        variantRowId: Int64, sampleName: String, genotype: String?,
        allele1: Int, allele2: Int, isPhased: Bool,
        depth: Int?, genotypeQuality: Int?,
        alleleDepths: String?, rawFields: String?
    ) {
        self.variantRowId = variantRowId
        self.sampleName = sampleName
        self.genotype = genotype
        self.allele1 = allele1
        self.allele2 = allele2
        self.isPhased = isPhased
        self.depth = depth
        self.genotypeQuality = genotypeQuality
        self.alleleDepths = alleleDepths
        self.rawFields = rawFields
    }

    /// Genotype classification for rendering.
    public var genotypeCall: GenotypeCall {
        if allele1 < 0 || allele2 < 0 { return .noCall }
        if allele1 == 0 && allele2 == 0 { return .homRef }
        if allele1 == allele2 { return .homAlt }
        return .het
    }
}

/// Classification of a genotype call for rendering purposes.
public enum GenotypeCall: String, Sendable, CaseIterable {
    case homRef = "HOM_REF"
    case het = "HET"
    case homAlt = "HOM_ALT"
    case noCall = "NO_CALL"

    /// IGV-compatible display colors.
    public var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .homRef:  return (0.784, 0.784, 0.784)   // rgb(200, 200, 200) light gray
        case .het:     return (0.133, 0.047, 0.992)    // rgb(34, 12, 253)   dark blue
        case .homAlt:  return (0.067, 0.973, 0.996)    // rgb(17, 248, 254)  cyan
        case .noCall:  return (0.980, 0.980, 0.980)    // rgb(250, 250, 250) near-white
        }
    }

    public var displayName: String {
        switch self {
        case .homRef: return "Hom Ref"
        case .het: return "Het"
        case .homAlt: return "Hom Alt"
        case .noCall: return "No Call"
        }
    }
}

// MARK: - MetadataFormat

/// Supported formats for sample metadata import.
public enum MetadataFormat: String, Sendable {
    case tsv
    case csv
    case excel
}

/// Runtime profile for VCF import resource tuning.
public enum VCFImportProfile: String, Sendable, Codable, CaseIterable {
    case auto
    case lowMemory = "low-memory"
    case fast
    case ultraLowMemory = "ultra-low-memory"
}

/// Behavioral mode for VCF import.
///
/// Standard imports preserve the existing sample/genotype semantics used for
/// cohort-style VCFs. Viral-frequency imports keep no-sample callsets truthful
/// by avoiding synthetic sample rows and synthetic homozygous-alt genotypes.
public enum VCFImportSemantics: String, Sendable, Codable {
    case standard
    case viralFrequency = "viral-frequency"
}
