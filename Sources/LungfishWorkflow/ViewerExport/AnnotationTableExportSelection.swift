// AnnotationTableExportSelection.swift - What the annotation table export's selection file carries beyond identities
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The annotation table's part of the selection file (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 4).
///
/// The GUI resolves the exported rows before `begin` and writes their identities in the selection's `identities`, in
/// order. This value holds the rest of what the table showed, which no source file holds: the scope, the columns as
/// shown, the column kinds, the drawer's query description, the chromosome aliases of the variant tracks and the
/// region whose coding features the derived columns came from. It holds no rendered cell.
public struct AnnotationTableExportSelection: Codable, Sendable, Equatable {
    /// The scope the user chose, as the base's `--scope` spelled it.
    public var scope: String
    /// The columns in display order, with the ids and titles shown.
    public var columns: [ScientificTableColumn]
    /// The ids of the numeric columns, sorted, so one selection always writes one digest.
    public var numericColumnIDs: [String]
    /// The ids of the integer columns, sorted.
    public var integerColumnIDs: [String]
    /// The drawer's query description, which the record writes verbatim as `resolved.query`.
    public var query: [String: String]
    /// The variant track chromosome names keyed by the names the reference uses.
    public var variantChromosomeAliases: [String: String]
    /// The region whose coding features the derived variant columns came from, nil when no derived column is shown.
    public var codingFeatureRegion: AnnotationTableFeatureRegion?
    /// The annotation tracks whose CDS the leaf reads across the bundle, over the exported rows, sorted. Nil for a
    /// region selection and when no derived column is shown.
    ///
    /// When a derived column is written, exactly one of this and `codingFeatureRegion` is set, and the app sets only
    /// this one (Phase 2.13 lane 13.38, V1-1). A selection that sets it writes schema 3.
    public var bundleCodingFeatureTrackIDs: [String]?

    public init(
        scope: String,
        columns: [ScientificTableColumn],
        numericColumnIDs: [String] = [],
        integerColumnIDs: [String] = [],
        query: [String: String] = [:],
        variantChromosomeAliases: [String: String] = [:],
        codingFeatureRegion: AnnotationTableFeatureRegion? = nil,
        bundleCodingFeatureTrackIDs: [String]? = nil
    ) {
        self.scope = scope
        self.columns = columns
        self.numericColumnIDs = numericColumnIDs.sorted()
        self.integerColumnIDs = integerColumnIDs.sorted()
        self.query = query
        self.variantChromosomeAliases = variantChromosomeAliases
        self.codingFeatureRegion = codingFeatureRegion
        self.bundleCodingFeatureTrackIDs = bundleCodingFeatureTrackIDs?.sorted()
    }
}

/// The viewer's cached annotation region (ARCH ruling on 12.39 R1 item 4). The leaf loads the coding features of
/// these tracks over this region from the bundle, the call the viewer makes, so the derived columns match.
public struct AnnotationTableFeatureRegion: Codable, Sendable, Equatable {
    public var chromosome: String
    public var start: Int
    public var end: Int
    /// The `annotation_db_track_id` qualifiers of the cached annotations, sorted.
    public var trackIDs: [String]

    public init(chromosome: String, start: Int, end: Int, trackIDs: [String]) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.trackIDs = trackIDs.sorted()
    }
}
