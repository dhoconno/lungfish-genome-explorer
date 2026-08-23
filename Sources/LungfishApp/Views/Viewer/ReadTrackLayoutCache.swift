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
/// `prioritizedRegion` only reorders the input, which changes the outcome *only*
/// when a max-row cap is active (it decides which reads win the scarce rows).
/// With unlimited rows every read is placed, so the region is deliberately
/// excluded from the key in that case — this is what lets panning reuse the
/// layout instead of repacking every frame.
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

enum ReadTrackCulling {

    /// Computes the row range whose read rects intersect `rect` vertically.
    ///
    /// - Parameters:
    ///   - rect: The full content rect the layout was laid out into (its `minY`
    ///     is row 0's top).
    ///   - clip: The rect actually being painted, in the same coordinate space
    ///     as `rect` (i.e. after any scroll translation has been applied to the
    ///     context, so this is the *content-space* window).
    ///   - rowCount: Total number of rows in the layout.
    ///   - rowHeight: Height of one read.
    ///   - rowGap: Gap between rows.
    static func visibleRowRange(
        rect: CGRect,
        clip: CGRect,
        rowCount: Int,
        rowHeight: CGFloat,
        rowGap: CGFloat
    ) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let pitch = rowHeight + rowGap
        guard pitch > 0 else { return 0..<rowCount }

        // A row `r` occupies [rect.minY + r*pitch, rect.minY + r*pitch + rowHeight].
        // It is drawn only when its bottom is within `rect` (existing behavior)
        // and it intersects `clip` vertically.
        let firstRaw = (clip.minY - rect.minY - rowHeight) / pitch
        let lastRaw = (clip.maxY - rect.minY) / pitch

        var lower = firstRaw.isFinite ? Int(firstRaw.rounded(.down)) : 0
        var upper = lastRaw.isFinite ? Int(lastRaw.rounded(.down)) + 1 : rowCount
        lower = max(0, lower)
        upper = min(rowCount, upper)

        // Preserve the legacy `y + readHeight <= rect.maxY` guard: rows whose
        // bottom falls past the content rect were never drawn.
        let maxDrawableRaw = (rect.maxY - rect.minY - rowHeight) / pitch
        if maxDrawableRaw.isFinite {
            let maxDrawable = Int(maxDrawableRaw.rounded(.down)) + 1
            upper = min(upper, max(0, maxDrawable))
        }

        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }

    /// Index range within a **position-sorted** row bucket whose reads can
    /// intersect `[genomicStart, genomicEnd)`.
    ///
    /// Reads within a row are emitted in ascending `position` order by
    /// `packReads` (rows are filled left to right), so a binary search for the
    /// first candidate plus an early stop at the first read starting past the
    /// window is exact.
    ///
    /// - Note: A read starting before the window may still overlap it, so the
    ///   lower bound backs off by `maxReadSpan` rather than by the window start.
    static func visibleReadRange(
        in reads: [AlignedRead],
        genomicStart: Int,
        genomicEnd: Int,
        maxReadSpan: Int
    ) -> Range<Int> {
        guard !reads.isEmpty, genomicEnd > genomicStart else { return 0..<0 }

        let searchFrom = genomicStart - max(0, maxReadSpan)

        // Lower bound: first index with position >= searchFrom.
        var lo = 0
        var hi = reads.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if reads[mid].position < searchFrom { lo = mid + 1 } else { hi = mid }
        }
        let lower = lo

        // Upper bound: first index with position >= genomicEnd.
        lo = lower
        hi = reads.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if reads[mid].position < genomicEnd { lo = mid + 1 } else { hi = mid }
        }
        let upper = lo

        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }

    /// Largest `alignmentEnd - position` across a layout, used to size the
    /// binary-search back-off. Computed once per pack, not per frame.
    static func maxReadSpan(_ packedReads: [(row: Int, read: AlignedRead)]) -> Int {
        var span = 0
        for (_, read) in packedReads {
            span = max(span, read.alignmentEnd - read.position)
        }
        return max(1, span)
    }
}

// MARK: - Mismatch precomputation

/// Per-read MD-tag derived mismatch positions, computed once when a read batch
/// is stored rather than re-parsed on every draw.
///
/// Only the MD/CIGAR string parse is cached. When a reference sequence *is*
/// loaded the mismatch test is already a zero-allocation byte comparison, so
/// caching it would trade a cheap loop for memory with no benefit.
public struct ReadMismatchCache: Sendable {

    private var positionsByReadID: [UUID: Set<Int>]

    public init() {
        positionsByReadID = [:]
    }

    init(positionsByReadID: [UUID: Set<Int>]) {
        self.positionsByReadID = positionsByReadID
    }

    public var count: Int { positionsByReadID.count }

    public var isEmpty: Bool { positionsByReadID.isEmpty }

    /// Cached MD-derived mismatch positions for `read`, or nil when the read has
    /// no MD tag (matching `read.mdTag.map { ... }` semantics exactly).
    public func positions(for read: AlignedRead) -> Set<Int>? {
        positionsByReadID[read.id]
    }

    /// Builds the cache for a batch of reads. Pure and `nonisolated` so it can
    /// run on the fetch's background thread before the reads are handed to the
    /// main actor.
    public nonisolated static func build(for reads: [AlignedRead]) -> ReadMismatchCache {
        var map: [UUID: Set<Int>] = [:]
        map.reserveCapacity(reads.count)
        for read in reads {
            guard let mdTag = read.mdTag else { continue }
            map[read.id] = ReadTrackRenderer.mismatchPositionsFromMDTagNonisolated(
                mdTag,
                readStart: read.position
            )
        }
        return ReadMismatchCache(positionsByReadID: map)
    }
}

// MARK: - Row-bucketed layout

/// A packed layout pre-bucketed by row, so drawing can iterate only the rows a
/// draw rect actually intersects and binary-search within each row.
///
/// Rows preserve `packReads` emission order, which is ascending `position`
/// within a row (rows are filled left to right), so the binary search in
/// `ReadTrackCulling.visibleReadRange` is exact.
public struct PackedReadLayout {

    /// Row index -> reads in that row, ascending by position.
    public private(set) var rows: [[AlignedRead]]

    /// Largest read span in the layout, used to size the search back-off.
    public private(set) var maxReadSpan: Int

    public var rowCount: Int { rows.count }

    public init(packedReads: [(row: Int, read: AlignedRead)]) {
        var maxRow = -1
        for (row, _) in packedReads { maxRow = max(maxRow, row) }
        var buckets = [[AlignedRead]](repeating: [], count: max(0, maxRow + 1))
        var span = 1
        for (row, read) in packedReads {
            buckets[row].append(read)
            span = max(span, read.alignmentEnd - read.position)
        }
        rows = buckets
        maxReadSpan = span
    }
}
