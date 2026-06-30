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

    public init(
        lens: String,
        sampleColumns: [String],
        rows: [GenotypeViewProjectionRow],
        cellColorMode: String? = nil
    ) {
        self.lens = lens
        self.sampleColumns = sampleColumns
        self.rows = rows
        self.cellColorMode = cellColorMode
    }
}

/// One rendered row in a ``GenotypeViewProjection``.
public struct GenotypeViewProjectionRow: Codable, Sendable, Equatable {
    /// Row header label as rendered (e.g. `"MHC-A H1"`).
    public let label: String

    /// Optional locus identity for row-level/cell-level matrix annotations.
    /// Older projection JSON omits this and remains decodable.
    public let locus: String?

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
        locus: String? = nil,
        cells: [String],
        cellColorsHex: [String?]? = nil,
        rowColorHex: String? = nil
    ) {
        self.label = label
        self.locus = locus
        self.cells = cells
        self.cellColorsHex = cellColorsHex
        self.rowColorHex = rowColorHex
    }
}
