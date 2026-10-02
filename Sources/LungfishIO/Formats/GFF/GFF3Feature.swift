// GFF3Feature.swift - A feature record from a GFF3 file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A feature record from a GFF3 file.
public struct GFF3Feature: Sendable, Identifiable {

    /// Unique identifier (from ID attribute)
    public var id: String { attributes["ID"] ?? "\(seqid):\(start)-\(end)" }

    /// Sequence ID (chromosome or contig name)
    public let seqid: String

    /// Source of the feature (e.g., "ENSEMBL", "GenBank")
    public let source: String

    /// Feature type (e.g., "gene", "mRNA", "CDS", "exon")
    public let type: String

    /// Start position (1-based, inclusive)
    public let start: Int

    /// End position (1-based, inclusive)
    public let end: Int

    /// Score (or nil if ".")
    public let score: Double?

    /// Strand (+, -, ., or ?)
    public let strand: Strand

    /// Phase for CDS features (0, 1, 2, or nil)
    public let phase: Int?

    /// Key-value attributes
    public let attributes: [String: String]

    /// Parent feature IDs (from Parent attribute).
    ///
    /// The GFF3 spec allows comma-separated values for multi-parent features,
    /// e.g. `Parent=mRNA1,mRNA2`. This property splits on commas and returns
    /// all parent IDs.
    public var parentIDs: [String] {
        guard let raw = attributes["Parent"] else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    /// First parent feature ID (from Parent attribute).
    ///
    /// For features with multiple parents, returns only the first.
    /// Use `parentIDs` to get all parents.
    public var parentID: String? {
        parentIDs.first
    }

    /// Feature name (from Name/gene attributes or ID)
    public var name: String {
        attributes["Name"]
            ?? attributes["gene_name"]
            ?? attributes["gene"]
            ?? attributes["gene_id"]
            ?? attributes["transcript_name"]
            ?? attributes["transcript_id"]
            ?? attributes["ID"]
            ?? type
    }

    /// Creates a GFF3 feature from parsed fields.
    public init(
        seqid: String,
        source: String,
        type: String,
        start: Int,
        end: Int,
        score: Double?,
        strand: Strand,
        phase: Int?,
        attributes: [String: String]
    ) {
        self.seqid = seqid
        self.source = source
        self.type = type
        self.start = start
        self.end = end
        self.score = score
        self.strand = strand
        self.phase = phase
        self.attributes = attributes
    }

    /// Converts to a SequenceAnnotation.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType = AnnotationType.from(rawString: type) ?? .region

        // Convert qualifiers, splitting comma-separated values per GFF3 spec
        var qualifiers: [String: AnnotationQualifier] = [:]
        for (key, value) in attributes {
            let values = value.split(separator: ",").map(String.init)
            qualifiers[key] = AnnotationQualifier(values)
        }

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            chromosome: seqid,  // Associate annotation with its source sequence
            // Convert to 0-based; carry the GFF3 phase column onto the interval
            // so translation can honor it instead of always assuming
            // phase 0. Only meaningful for CDS features; GFF3 writes "." (nil)
            // for everything else.
            intervals: [AnnotationInterval(start: start - 1, end: end, phase: phase)],
            strand: strand,
            qualifiers: qualifiers
        )
    }
}
