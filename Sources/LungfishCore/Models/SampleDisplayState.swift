// SampleDisplayState.swift - Sample display ordering, filtering, and visibility state
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - SampleDisplayState

/// State controlling how samples are displayed in the genotype viewer.
///
/// Manages sort order, filtering, and visibility for per-sample genotype rows.
/// This is stored per-bundle and persists across sessions.
public struct SampleDisplayState: Sendable, Codable, Equatable {
    public static let minRowHeight: CGFloat = 2
    public static let maxRowHeight: CGFloat = 30
    public static let defaultRowHeight: CGFloat = 12

    public static let minSummaryBarHeight: CGFloat = 10
    public static let maxSummaryBarHeight: CGFloat = 60
    public static let defaultSummaryBarHeight: CGFloat = 20

    /// Fields to sort samples by, in priority order.
    /// Empty means default order (as they appear in the VCF header).
    public var sortFields: [SortField] = []

    /// Active filters on sample metadata fields.
    public var filters: [SampleFilter] = []

    /// Set of sample names that are explicitly hidden.
    public var hiddenSamples: Set<String> = []

    /// Whether to show per-sample genotype rows (vs. summary bar only).
    public var showGenotypeRows: Bool = true

    /// Height per genotype row in pixels (2–30). Default 12.
    public var rowHeight: CGFloat = Self.defaultRowHeight

    /// Height of the variant summary bar in pixels (10–60). Default 20.
    public var summaryBarHeight: CGFloat = Self.defaultSummaryBarHeight

    /// Explicit sample ordering. When non-nil, `visibleSamples(from:)` uses this
    /// order instead of VCF default order. When nil, falls back to VCF order.
    public var sampleOrder: [String]?

    /// Metadata field to use as display label instead of sample name.
    public var displayNameField: String?

    public init() {}

    public init(
        sortFields: [SortField] = [],
        filters: [SampleFilter] = [],
        hiddenSamples: Set<String> = [],
        showGenotypeRows: Bool = true,
        rowHeight: CGFloat = Self.defaultRowHeight,
        summaryBarHeight: CGFloat = Self.defaultSummaryBarHeight,
        sampleOrder: [String]? = nil,
        displayNameField: String? = nil
    ) {
        self.sortFields = sortFields
        self.filters = filters
        self.hiddenSamples = hiddenSamples
        self.showGenotypeRows = showGenotypeRows
        self.rowHeight = Self.clampRowHeight(rowHeight)
        self.summaryBarHeight = Self.clampSummaryBarHeight(summaryBarHeight)
        self.sampleOrder = sampleOrder
        self.displayNameField = displayNameField
    }

    public static func clampRowHeight(_ value: CGFloat) -> CGFloat {
        max(minRowHeight, min(maxRowHeight, value))
    }

    public static func clampSummaryBarHeight(_ value: CGFloat) -> CGFloat {
        max(minSummaryBarHeight, min(maxSummaryBarHeight, value))
    }

    // MARK: - Codable (backward compatibility)

    private enum CodingKeys: String, CodingKey {
        case sortFields, filters, hiddenSamples, showGenotypeRows
        case rowHeight, summaryBarHeight, sampleOrder, displayNameField
        // Legacy key for migration
        case rowHeightMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortFields = try container.decodeIfPresent([SortField].self, forKey: .sortFields) ?? []
        filters = try container.decodeIfPresent([SampleFilter].self, forKey: .filters) ?? []
        hiddenSamples = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenSamples) ?? []
        showGenotypeRows = try container.decodeIfPresent(Bool.self, forKey: .showGenotypeRows) ?? true
        let decodedSummary = try container.decodeIfPresent(CGFloat.self, forKey: .summaryBarHeight) ?? Self.defaultSummaryBarHeight
        summaryBarHeight = Self.clampSummaryBarHeight(decodedSummary)
        sampleOrder = try container.decodeIfPresent([String].self, forKey: .sampleOrder)
        displayNameField = try container.decodeIfPresent(String.self, forKey: .displayNameField)

        // Migrate from legacy RowHeightMode if present
        if let height = try container.decodeIfPresent(CGFloat.self, forKey: .rowHeight) {
            rowHeight = Self.clampRowHeight(height)
        } else if let legacyMode = try container.decodeIfPresent(String.self, forKey: .rowHeightMode) {
            switch legacyMode {
            case "squished": rowHeight = 2
            case "expanded": rowHeight = 10
            default: rowHeight = Self.defaultRowHeight  // automatic → default
            }
        } else {
            rowHeight = Self.defaultRowHeight
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sortFields, forKey: .sortFields)
        try container.encode(filters, forKey: .filters)
        try container.encode(hiddenSamples, forKey: .hiddenSamples)
        try container.encode(showGenotypeRows, forKey: .showGenotypeRows)
        try container.encode(rowHeight, forKey: .rowHeight)
        try container.encode(summaryBarHeight, forKey: .summaryBarHeight)
        try container.encodeIfPresent(sampleOrder, forKey: .sampleOrder)
        try container.encodeIfPresent(displayNameField, forKey: .displayNameField)
    }

    /// Returns the ordered, filtered list of sample names to display.
    ///
    /// - Parameters:
    ///   - allSamples: All sample names from the VCF
    ///   - metadata: Sample metadata keyed by sample name
    /// - Returns: Ordered list of visible sample names
    public func visibleSamples(
        from allSamples: [String],
        metadata: [String: [String: String]] = [:]
    ) -> [String] {
        // 0. Apply explicit ordering if set
        var samples: [String]
        if let order = sampleOrder {
            let allSet = Set(allSamples)
            // Ordered samples first, then any new samples not in order
            var ordered = order.filter { allSet.contains($0) }
            let orderedSet = Set(ordered)
            ordered.append(contentsOf: allSamples.filter { !orderedSet.contains($0) })
            samples = ordered
        } else {
            samples = allSamples
        }

        // 1. Remove hidden samples
        if !hiddenSamples.isEmpty {
            samples = samples.filter { !hiddenSamples.contains($0) }
        }

        // 2. Apply metadata filters
        for filter in filters {
            samples = samples.filter { name in
                let value = metadata[name]?[filter.field] ?? ""
                return filter.matches(value)
            }
        }

        // 3. Sort by metadata fields
        if !sortFields.isEmpty {
            samples.sort { a, b in
                let metaA = metadata[a] ?? [:]
                let metaB = metadata[b] ?? [:]
                for sortField in sortFields {
                    let valA = metaA[sortField.field] ?? ""
                    let valB = metaB[sortField.field] ?? ""
                    let cmp = valA.localizedCaseInsensitiveCompare(valB)
                    if cmp != .orderedSame {
                        return sortField.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                    }
                }
                return false
            }
        }

        return samples
    }
}

// MARK: - SortField

/// A metadata field used for sorting samples.
public struct SortField: Sendable, Codable, Equatable {
    /// The metadata field name to sort by.
    public let field: String

    /// Sort direction.
    public let ascending: Bool

    public init(field: String, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

// MARK: - SampleFilter

/// A filter on a sample metadata field.
public struct SampleFilter: Sendable, Codable, Equatable {

    /// The metadata field name to filter on.
    public let field: String

    /// The filter operation.
    public let op: FilterOp

    /// The value to compare against.
    public let value: String

    public init(field: String, op: FilterOp, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }

    /// Tests whether a metadata value passes this filter.
    public func matches(_ metadataValue: String) -> Bool {
        switch op {
        case .equals:
            return metadataValue.localizedCaseInsensitiveCompare(value) == .orderedSame
        case .notEquals:
            return metadataValue.localizedCaseInsensitiveCompare(value) != .orderedSame
        case .contains:
            return metadataValue.localizedCaseInsensitiveContains(value)
        }
    }
}

// MARK: - FilterOp

/// Filter comparison operators.
public enum FilterOp: String, Sendable, Codable, CaseIterable {
    case equals
    case notEquals
    case contains
}

// MARK: - GenotypeDisplayData

/// Cached genotype data for rendering in the viewer.
///
/// Contains the pre-fetched genotype calls for the visible region,
/// organized for efficient rendering.
public struct GenotypeDisplayData: Sendable {

    /// Ordered list of sample names to display.
    public let sampleNames: [String]

    /// Variant sites in the visible region, sorted by position.
    public let sites: [VariantSite]

    /// The genomic region this data covers.
    public let region: GenomicRegion

    public init(sampleNames: [String], sites: [VariantSite], region: GenomicRegion) {
        self.sampleNames = sampleNames
        self.sites = sites
        self.region = region
    }
}

// MARK: - VariantImpact

/// Classification of a variant's predicted effect on protein sequence.
public enum VariantImpact: String, Sendable, CaseIterable {
    /// No amino acid change (silent mutation).
    case synonymous = "SYNONYMOUS"
    /// Different amino acid (non-synonymous).
    case missense = "MISSENSE"
    /// Creates a premature stop codon.
    case nonsense = "NONSENSE"
    /// Insertion or deletion shifts the reading frame.
    case frameshift = "FRAMESHIFT"
    /// Variant near an exon-intron boundary.
    case spliceRegion = "SPLICE_REGION"
    /// No CDS overlap or unknown effect.
    case unknown = "UNKNOWN"

    /// Initializes from a VEP/CSQ IMPACT string (HIGH, MODERATE, LOW, MODIFIER)
    /// combined with a Consequence string for more precise classification.
    public static func fromCSQ(impact: String?, consequence: String?) -> VariantImpact {
        let csq = consequence?.lowercased() ?? ""
        // Order matters: check most damaging first so compound terms like
        // "splice_region_variant&synonymous_variant" get the higher-impact call.
        if csq.contains("frameshift") { return .frameshift }
        if csq.contains("stop_gained") || csq.contains("nonsense") { return .nonsense }
        if csq.contains("missense") { return .missense }
        if csq.contains("splice") { return .spliceRegion }
        if csq.contains("synonymous") { return .synonymous }

        // Fall back to IMPACT field
        switch impact?.uppercased() {
        case "HIGH":     return .nonsense
        case "MODERATE": return .missense
        case "LOW":      return .synonymous
        default:         return .unknown
        }
    }
}

// MARK: - VariantSite

/// A single variant site with per-sample genotype calls.
public struct VariantSite: Sendable {

    /// 0-based genomic position.
    public let position: Int

    /// Reference allele.
    public let ref: String

    /// Alternate allele(s).
    public let alt: String

    /// Variant type (SNP, INS, DEL, etc.).
    public let variantType: String

    /// Per-sample genotype calls keyed by sample name.
    public let genotypes: [String: GenotypeDisplayCall]

    /// Database row ID for looking up INFO/CSQ fields (nil for legacy data).
    public let databaseRowId: Int64?

    /// Variant ID string (e.g., rsID or generated ID).
    public let variantID: String?

    /// Source variant track ID for resolving the correct backing database.
    public let sourceTrackId: String?

    /// Predicted amino acid impact (from CSQ or computed). Nil if not determined.
    public var impact: VariantImpact?

    /// Human-readable amino acid change description (e.g., "p.Arg123Cys").
    public var aminoAcidChange: String?

    /// Compact amino acid change (e.g., "S28P"). Single-letter ref AA + position + single-letter alt AA.
    public var shortAAChange: String?

    /// Gene symbol associated with this variant (from CSQ or annotation overlap).
    public var geneSymbol: String?

    public init(position: Int, ref: String, alt: String, variantType: String, genotypes: [String: GenotypeDisplayCall], databaseRowId: Int64? = nil, variantID: String? = nil, sourceTrackId: String? = nil, impact: VariantImpact? = nil, aminoAcidChange: String? = nil, shortAAChange: String? = nil, geneSymbol: String? = nil) {
        self.position = position
        self.ref = ref
        self.alt = alt
        self.variantType = variantType
        self.genotypes = genotypes
        self.databaseRowId = databaseRowId
        self.variantID = variantID
        self.sourceTrackId = sourceTrackId
        self.impact = impact
        self.aminoAcidChange = aminoAcidChange
        self.shortAAChange = shortAAChange
        self.geneSymbol = geneSymbol
    }
}

// MARK: - GenotypeDisplayCall

/// A genotype call for rendering purposes.
public enum GenotypeDisplayCall: String, Sendable, CaseIterable {
    case homRef = "HOM_REF"
    case het = "HET"
    case homAlt = "HOM_ALT"
    case noCall = "NO_CALL"

    /// Classifies a genotype call from its raw VCF components.
    ///
    /// - Parameters:
    ///   - genotype: The GT string (e.g., "0/1", "1|1", ".", nil)
    ///   - allele1: First allele index (-1 for missing)
    ///   - allele2: Second allele index (-1 for missing)
    /// - Returns: The classified genotype display call
    public static func classify(genotype: String?, allele1: Int, allele2: Int) -> GenotypeDisplayCall {
        guard let gtStr = genotype else { return .noCall }
        let trimmed = gtStr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == "./." || trimmed == ".|." {
            return .noCall
        }
        if allele1 < 0 || allele2 < 0 { return .noCall }
        if allele1 == 0 && allele2 == 0 { return .homRef }
        if allele1 == allele2 { return .homAlt }
        return .het
    }

    /// IGV-compatible RGB color for this genotype.
    public var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .homRef:  return (r: 200/255, g: 200/255, b: 200/255)  // light gray
        case .het:     return (r: 34/255,  g: 12/255,  b: 253/255)  // dark blue
        case .homAlt:  return (r: 17/255,  g: 248/255, b: 254/255)  // cyan
        case .noCall:  return (r: 250/255, g: 250/255, b: 250/255)  // near-white
        }
    }
}
