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

    /// Fields to sort samples by, in priority order.
    /// Empty means default order (as they appear in the VCF header).
    public var sortFields: [SortField] = []

    /// Active filters on sample metadata fields.
    public var filters: [SampleFilter] = []

    /// Set of sample names that are explicitly hidden.
    public var hiddenSamples: Set<String> = []

    /// Whether to show per-sample genotype rows (vs. summary bar only).
    public var showGenotypeRows: Bool = true

    /// Height mode for genotype rows.
    public var rowHeightMode: RowHeightMode = .automatic

    public init() {}

    public init(
        sortFields: [SortField] = [],
        filters: [SampleFilter] = [],
        hiddenSamples: Set<String> = [],
        showGenotypeRows: Bool = true,
        rowHeightMode: RowHeightMode = .automatic
    ) {
        self.sortFields = sortFields
        self.filters = filters
        self.hiddenSamples = hiddenSamples
        self.showGenotypeRows = showGenotypeRows
        self.rowHeightMode = rowHeightMode
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
        var samples = allSamples

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

// MARK: - RowHeightMode

/// Controls how genotype row heights are determined.
public enum RowHeightMode: String, Sendable, Codable, CaseIterable {
    /// Automatically choose between squished and expanded based on zoom level.
    case automatic
    /// Always use squished mode (2px per row).
    case squished
    /// Always use expanded mode (10px per row with labels).
    case expanded
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

    public init(position: Int, ref: String, alt: String, variantType: String, genotypes: [String: GenotypeDisplayCall]) {
        self.position = position
        self.ref = ref
        self.alt = alt
        self.variantType = variantType
        self.genotypes = genotypes
    }
}

// MARK: - GenotypeDisplayCall

/// A genotype call for rendering purposes.
public enum GenotypeDisplayCall: String, Sendable, CaseIterable {
    case homRef = "HOM_REF"
    case het = "HET"
    case homAlt = "HOM_ALT"
    case noCall = "NO_CALL"

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
