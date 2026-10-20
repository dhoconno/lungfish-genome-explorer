// ReadTrackLayoutCache.swift - Frame-stable read layout, culling, and mismatch precomputation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - Pack cache key

/// Identity of a packed read layout.
///
/// `ReadTrackRenderer.packReads` is **not** purely genomic: it drops reads
/// narrower than `minReadPixels` and separates rows by a fixed 2px gap, so the
/// row assignment genuinely depends on the pixel scale. The key therefore
/// carries `scale` (quantized so sub-pixel jitter from float division does not
/// thrash the cache) rather than pretending packing is scale-free.
///
/// `prioritizedRegion` moves the reads of a window to the front of the pack so
/// they win the scarce rows of a max-row cap, and so a sort other than position
/// keeps them at the top. The pack uses exactly the region in its key. With
/// unlimited rows and position sort the key holds no region and the pack keeps
/// plain position order, which is what lets panning reuse the layout instead of
/// repacking every frame. A prioritized order with no region in the key put
/// every read left of the first window below all of that window's rows once
/// the user panned left (blank rows above the reads).
struct ReadPackCacheKey: Equatable {

    /// Bumped whenever `cachedAlignedReads` is reassigned.
    var readGeneration: Int

    /// Chromosome the layout was packed for.
    var chromosome: String

    /// Quantized bp-per-pixel scale (see `quantizeScale`).
    var scaleTier: Int64

    /// Sort mode raw value.
    var sortMode: String

    /// Focal position for `.baseAtPosition` sorting, otherwise nil.
    var sortPosition: Int?

    /// Row cap in force, or nil for unlimited rows.
    var maxRows: Int?

    /// Vertical-compress display setting (changes row metrics, not assignment,
    /// but is cheap to include and keeps the cache honest if that ever changes).
    var verticalCompress: Bool

    /// Prioritized region — only meaningful when `maxRows != nil`.
    var prioritizedRegion: Range<Int>?

    /// Extra discriminator for callers that pre-filter reads by a pack window
    /// (the bundle path narrows reads to viewport +/- padding before packing).
    var filterWindow: Range<Int>?

    /// Quantizes bp-per-pixel to a stable integer so that float noise in
    /// `(end - start) / dataPixelWidth` does not invalidate an otherwise
    /// identical layout. 1e-6 resolution is far finer than any visible change.
    static func quantizeScale(_ scale: Double) -> Int64 {
        guard scale.isFinite else { return 0 }
        return Int64((scale * 1_000_000).rounded())
    }
}

// MARK: - Cached pack layout

/// A packed layout plus the key that produced it.
struct ReadPackCacheEntry {
    var key: ReadPackCacheKey
    var packed: [(row: Int, read: AlignedRead)]
    var overflow: Int
}

// MARK: - Visible-range culling

/// The slice of a row-bucketed packed layout that intersects a draw rect.
///
/// `rows` is the inclusive-exclusive range of row indices whose rects overlap
/// `rect` vertically. Rows above or below are skipped entirely instead of being
/// walked read-by-read.
struct ReadDrawWindow: Equatable {
    var rows: Range<Int>
    var genomicStart: Int
    var genomicEnd: Int

    static let empty = ReadDrawWindow(rows: 0..<0, genomicStart: 0, genomicEnd: 0)

    var isEmpty: Bool { rows.isEmpty }
}
