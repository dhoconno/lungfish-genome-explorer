// GenotypeViewProjection.swift - Serialized snapshot of a rendered genotype view
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A serialized snapshot of exactly what the genotype inspector viewport
/// rendered: the visible sample columns (in display order), the visible rows
/// with their cell values, and the per-cell / per-row colors.
///
/// This is the contract the GUI export serializes and the
/// `genotype export --view-projection <path>` CLI subcommand deserializes,
/// so a headless `lungfish-cli` invocation can reproduce the analyst's
/// colored view in an XLSX or delimited export without re-deriving the
/// matrix from the bundle. It lives in `LungfishIO` so both the CLI and the
/// App target can import it without a new dependency edge (the genotype
/// result/bundle types it complements already live here).
public struct GenotypeViewProjection: Codable, Sendable, Equatable {
    /// The lens the viewport was showing (e.g. `"haplotype"`, `"allele"`).
    public let lens: String

    /// Visible sample columns in left-to-right display order. The export's
    /// columns are exactly these, after intersecting with any `--sample`
    /// filters the command also received.
    public let sampleColumns: [String]

    /// Visible rows top-to-bottom. Each row's `cells` align positionally to
    /// `sampleColumns`.
    public let rows: [GenotypeViewProjectionRow]

    /// Identifier for the cell color scheme the GUI applied (e.g.
    /// `"budde2010"`). `nil` when the view rendered without cell coloring.
    public let cellColorMode: String?

    /// Effective allele-row group order, recorded with the exported view for replay.
    public let genotypeLocusDisplayOrder: [String]?
    public let genotypeNumericPrefixOrder: Bool?

    /// Display-only scope; never changes scientific calls in the source bundle.
    public let diagnosticAllelesOnly: Bool?
    /// Append a read sum across the exported sample columns.
    public let includeTotalReads: Bool?
    /// Ordered, exact effective calls for the projection's visible scope.
    /// Nil identifies a legacy projection whose workbook companions retain
    /// their historical behavior.
    public let haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]?
    public let sourceRevision: GenotypeViewProjectionSourceRevision?
    public let filterContext: [String: String]?

    public init(
        lens: String,
        sampleColumns: [String],
        rows: [GenotypeViewProjectionRow],
        cellColorMode: String? = nil,
        genotypeLocusDisplayOrder: [String]? = nil,
        genotypeNumericPrefixOrder: Bool? = nil,
        diagnosticAllelesOnly: Bool? = nil,
        includeTotalReads: Bool? = nil,
        haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]? = nil,
        sourceRevision: GenotypeViewProjectionSourceRevision? = nil,
        filterContext: [String: String]? = nil
    ) {
        self.lens = lens
        self.sampleColumns = sampleColumns
        self.rows = rows
        self.cellColorMode = cellColorMode
        self.genotypeLocusDisplayOrder = genotypeLocusDisplayOrder
        self.genotypeNumericPrefixOrder = genotypeNumericPrefixOrder
        self.diagnosticAllelesOnly = diagnosticAllelesOnly
        self.includeTotalReads = includeTotalReads
        self.haplotypeCalls = haplotypeCalls
        self.sourceRevision = sourceRevision
        self.filterContext = filterContext
    }
}

public struct GenotypeViewProjectionSourceRevision: Codable, Sendable, Equatable {
    public let assayID: String
    public let analysisRevisionID: String?
    public let definitionSetID: String

    public init(assayID: String, analysisRevisionID: String?, definitionSetID: String) {
        self.assayID = assayID
        self.analysisRevisionID = analysisRevisionID
        self.definitionSetID = definitionSetID
    }
}

public struct GenotypeViewProjectionHaplotypeCall: Codable, Sendable, Equatable {
    public let sample: String
    public let locus: String
    public let haplotype1: String
    public let haplotype2: String
    public let haplotype1Status: String
    public let haplotype2Status: String
    public let haplotype1Source: String
    public let haplotype2Source: String
    public let baselineHaplotype1: String
    public let baselineHaplotype2: String
    public let comment: String?

    public init(
        sample: String, locus: String, haplotype1: String, haplotype2: String,
        haplotype1Status: String, haplotype2Status: String,
        haplotype1Source: String, haplotype2Source: String,
        baselineHaplotype1: String, baselineHaplotype2: String,
        comment: String? = nil
    ) {
        self.sample = sample; self.locus = locus
        self.haplotype1 = haplotype1; self.haplotype2 = haplotype2
        self.haplotype1Status = haplotype1Status; self.haplotype2Status = haplotype2Status
        self.haplotype1Source = haplotype1Source; self.haplotype2Source = haplotype2Source
        self.baselineHaplotype1 = baselineHaplotype1; self.baselineHaplotype2 = baselineHaplotype2
        self.comment = comment
    }
}

/// One rendered row in a ``GenotypeViewProjection``.
public struct GenotypeViewProjectionRow: Codable, Sendable, Equatable {
    /// Row header label as rendered (e.g. `"MHC-A H1"`).
    public let label: String

    /// Original reference identity for annotations when the display label is abbreviated.
    /// Older projections omit this and use `label` as their identity.
    public let rawGenotype: String?

    /// Optional locus identity for row-level/cell-level matrix annotations.
    /// Older projection JSON omits this and remains decodable.
    public let locus: String?

    /// Optional stable candidate identity used to disambiguate rows whose
    /// rendered genotype labels and loci are identical. Older projection JSON
    /// omits this and decodes it as `nil`.
    public let stableClusterID: String?

    /// Cell values aligned positionally to the projection's `sampleColumns`.
    /// An empty / absent cell is the empty string (or `"-"`).
    public let cells: [String]

    /// Per-cell color hex strings aligned positionally to `cells`. `nil`
    /// (or a shorter array) means individual cells fall back to the
    /// projection's `cellColorMode`. Each entry is a `#RRGGBB` string or
    /// `nil` for "no fill".
    public let cellColorsHex: [String?]?

    /// Row-wide highlight color hex (`#RRGGBB`), or `nil` for none. Applied
    /// to the row header / all cells lacking an explicit cell color.
    public let rowColorHex: String?

    public init(
        label: String,
        rawGenotype: String? = nil,
        locus: String? = nil,
        stableClusterID: String? = nil,
        cells: [String],
        cellColorsHex: [String?]? = nil,
        rowColorHex: String? = nil
    ) {
        self.label = label
        self.rawGenotype = rawGenotype
        self.locus = locus
        self.stableClusterID = stableClusterID
        self.cells = cells
        self.cellColorsHex = cellColorsHex
        self.rowColorHex = rowColorHex
    }
}
