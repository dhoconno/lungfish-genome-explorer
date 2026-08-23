// ReadRowAllocator.swift - O(log rows) first-fit row assignment for read packing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Immutable snapshot of a `ReferenceFrame`'s genomic-to-pixel mapping.
///
/// `ReferenceFrame` is a `@MainActor` class holding mutable viewport state, so
/// it cannot cross into the background pack task. The mapping it provides is a
/// plain affine function of three numbers, and those are all packing needs, so
/// the pack captures this value type instead and is trivially `Sendable`.
///
/// Snapshotting also makes the pack immune to the user panning mid-pack: the
/// layout is computed against the frame as it was when the pack was queued, and
/// the pack cache key carries the same scale, so a superseded layout is
/// rejected rather than drawn against a frame it was not packed for.
public struct ReadPackFrame: Sendable, Equatable {
    public var leadingInset: CGFloat
    public var start: Double
    public var scale: Double

    public init(leadingInset: CGFloat, start: Double, scale: Double) {
        self.leadingInset = leadingInset
        self.start = start
        self.scale = scale
    }

    /// Mirrors `ReferenceFrame.screenPosition(for:)` exactly.
    public func genomicToPixel(_ position: Double) -> CGFloat {
        leadingInset + CGFloat((position - start) / scale)
    }
}

extension ReadPackFrame {
    /// Snapshots a live viewport frame for use off the main actor.
    @MainActor
    public init(_ frame: ReferenceFrame) {
        self.init(leadingInset: frame.leadingInset, start: frame.start, scale: frame.scale)
    }
}

/// First-fit row assignment in `O(log rows)` per read.
///
/// The greedy packer this replaces scanned every row for every read, which is
/// `O(reads x rows)`. At extreme depth (a microsatellite window where hundreds
/// of thousands of reads pile up) that scan is the dominant cost and it ran on
/// the main thread inside `draw(_:)`.
///
/// This allocator keeps `rowEndPixels` in the leaves of a min-segment-tree, so
/// "leftmost row whose end pixel is at most `limit`" is a single descent.
/// Placement semantics are **identical** to the linear scan:
///
/// * a read goes into the lowest-index row satisfying `startPx >= end + gap`;
/// * with a row cap, a read that fits nowhere counts as overflow;
/// * without a cap, a read that fits nowhere opens a new row at the end.
///
/// Correctness does not depend on the reads arriving in any particular order —
/// unlike a "free rows" heap, the tree is re-queried against the live end
/// pixels for every read, so `prioritizedRegion` reordering is handled exactly
/// as the linear scan handled it.
struct ReadRowAllocator {

    /// Number of leaves in the tree (a power of two, >= the row capacity).
    private var capacity: Int

    /// `tree[1...]` is a 1-indexed min-heap-shaped segment tree over the leaves.
    /// `tree[capacity + i]` is row `i`'s end pixel; internal nodes hold the min
    /// of their children. Unused leaves hold `.infinity` so they never match.
    private var tree: [CGFloat]

    /// Hard row cap, or nil when rows may grow without bound.
    private let rowCap: Int?

    /// Number of rows currently in use (only meaningful when `rowCap == nil`;
    /// with a cap all `rowCap` rows exist from the start, seeded to `-1`).
    private(set) var rowCount: Int

    /// - Parameters:
    ///   - rowCap: Row limit, or nil for unlimited rows.
    ///   - expectedRows: Hint for the initial leaf count when unlimited.
    init(rowCap: Int?, expectedRows: Int = 64) {
        self.rowCap = rowCap
        let initialRows = rowCap ?? max(1, expectedRows)
        var leaves = 1
        while leaves < max(1, initialRows) { leaves <<= 1 }
        capacity = leaves
        tree = [CGFloat](repeating: .infinity, count: leaves * 2)
        if let rowCap {
            // Every capped row exists immediately, seeded to the same -1 the
            // linear scan used, so row 0 is available to the first read.
            rowCount = rowCap
            for index in 0..<rowCap {
                tree[capacity + index] = -1
            }
            rebuildInternalNodes()
        } else {
            rowCount = 0
        }
    }

    private mutating func rebuildInternalNodes() {
        guard capacity > 1 else { return }
        for index in stride(from: capacity - 1, through: 1, by: -1) {
            tree[index] = min(tree[index * 2], tree[index * 2 + 1])
        }
    }

    /// Doubles the leaf count, preserving existing values. Only used when rows
    /// are unbounded.
    private mutating func grow() {
        let newCapacity = capacity * 2
        var newTree = [CGFloat](repeating: .infinity, count: newCapacity * 2)
        for index in 0..<capacity {
            newTree[newCapacity + index] = tree[capacity + index]
        }
        capacity = newCapacity
        tree = newTree
        rebuildInternalNodes()
    }

    /// Sets row `row`'s end pixel and repairs the ancestors.
    private mutating func assign(row: Int, endPixel: CGFloat) {
        var index = capacity + row
        tree[index] = endPixel
        index /= 2
        while index >= 1 {
            tree[index] = min(tree[index * 2], tree[index * 2 + 1])
            if index == 1 { break }
            index /= 2
        }
    }

    /// Leftmost row index in `0..<bound` whose stored end pixel is `<= limit`,
    /// or nil when no such row exists.
    private func leftmostRow(atMost limit: CGFloat, bound: Int) -> Int? {
        guard bound > 0, tree[1] <= limit else { return nil }
        var node = 1
        while node < capacity {
            if tree[node * 2] <= limit {
                node = node * 2
            } else {
                node = node * 2 + 1
            }
        }
        let row = node - capacity
        return row < bound ? row : nil
    }

    /// Result of placing one read.
    enum Placement {
        /// The read was written into `row`.
        case placed(row: Int)
        /// No row was available and the cap forbade opening one.
        case overflow
    }

    /// Places a read spanning `startPx...endPx`, using a `gap` pixel separation
    /// between consecutive reads in the same row.
    mutating func place(startPx: CGFloat, endPx: CGFloat, gap: CGFloat) -> Placement {
        // `startPx >= rowEnd + gap` is equivalent to `rowEnd <= startPx - gap`.
        let limit = startPx - gap
        if let row = leftmostRow(atMost: limit, bound: rowCount) {
            assign(row: row, endPixel: endPx)
            return .placed(row: row)
        }
        if rowCap != nil {
            return .overflow
        }
        // Unlimited rows: open a new row at the end.
        if rowCount >= capacity {
            grow()
        }
        let newRow = rowCount
        rowCount += 1
        assign(row: newRow, endPixel: endPx)
        return .placed(row: newRow)
    }
}
