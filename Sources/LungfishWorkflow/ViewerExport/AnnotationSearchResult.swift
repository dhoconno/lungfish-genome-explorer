// AnnotationSearchResult.swift - One annotation or variant row of the annotation table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A search result representing a single annotation or variant feature.
public struct AnnotationSearchResult: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let trackId: String
    public let trackName: String?

    /// Row IDs are only unique within their owning SQLite track.
    package var variantIdentity: VariantIdentity? {
        variantRowId.map { VariantIdentity(trackId: trackId, rowId: $0) }
    }

    package struct VariantIdentity: Hashable {
        let trackId: String
        let rowId: Int64
    }
    public let type: String
    public let strand: String

    // Variant-specific fields (nil for annotations)
    public let ref: String?
    public let alt: String?
    public let quality: Double?
    public let filter: String?
    public let sampleCount: Int?
    public let variantRowId: Int64?
    /// Structured INFO key-value pairs (nil for annotations or legacy databases).
    public let infoDict: [String: String]?
    /// Human-readable source name (e.g. VCF filename) for provenance display.
    public let sourceFile: String?
    /// Parsed annotation attribute key-value pairs (nil for variants or legacy rows).
    public let attributes: [String: String]?
    /// Stable SQLite row id for annotation rows (nil for variants or in-memory rows).
    public let annotationRowId: Int64?

    /// Whether this result represents a variant (vs annotation).
    public var isVariant: Bool { ref != nil }

    public init(id: UUID = UUID(), name: String, chromosome: String, start: Int, end: Int,
                trackId: String, trackName: String? = nil, type: String = "gene", strand: String = ".",
                ref: String? = nil, alt: String? = nil, quality: Double? = nil,
                filter: String? = nil, sampleCount: Int? = nil, variantRowId: Int64? = nil,
                infoDict: [String: String]? = nil, sourceFile: String? = nil,
                attributes: [String: String]? = nil, annotationRowId: Int64? = nil) {
        self.id = id
        self.name = name
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.trackId = trackId
        self.trackName = trackName
        self.type = type
        self.strand = strand
        self.ref = ref
        self.alt = alt
        self.quality = quality
        self.filter = filter
        self.sampleCount = sampleCount
        self.variantRowId = variantRowId
        self.infoDict = infoDict
        self.sourceFile = sourceFile
        self.attributes = attributes
        self.annotationRowId = annotationRowId
    }
}

// MARK: - VariantDatabaseRecord → SearchResult Conversion

extension VariantDatabaseRecord {
    /// Converts this variant record to an `AnnotationSearchResult`
    /// for unified display in the annotation table drawer.
    public func toSearchResult(
        trackId: String = "variants",
        infoDict: [String: String]? = nil,
        sourceFile: String? = nil
    ) -> AnnotationSearchResult {
        AnnotationSearchResult(
            name: variantID,
            chromosome: chromosome,
            start: position,
            end: end,
            trackId: trackId,
            trackName: sourceFile,
            type: variantType,
            strand: ".",
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            sampleCount: sampleCount,
            variantRowId: id,
            infoDict: infoDict,
            sourceFile: sourceFile
        )
    }
}
