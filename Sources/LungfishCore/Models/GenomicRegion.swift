// GenomicRegion.swift - Coordinate-based genomic region
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A coordinate-based region on a chromosome or sequence.
///
/// Uses 0-based, half-open intervals [start, end) following BED convention.
///
/// ## Example
/// ```swift
/// let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
/// print(region.length)  // 1000
/// ```
public struct GenomicRegion: Hashable, Codable, Sendable {
    /// The chromosome or sequence name
    public let chromosome: String

    /// Start position (0-based, inclusive)
    public let start: Int

    /// End position (0-based, exclusive)
    public let end: Int

    /// Creates a genomic region with the specified coordinates.
    ///
    /// - Parameters:
    ///   - chromosome: The chromosome or sequence name
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (0-based, exclusive)
    /// - Precondition: `start >= 0` and `end >= start`
    public init(chromosome: String, start: Int, end: Int) {
        precondition(start >= 0, "Start position must be non-negative")
        precondition(end >= start, "End must be greater than or equal to start")
        self.chromosome = chromosome
        self.start = start
        self.end = end
    }

    /// The length of this region in bases
    public var length: Int {
        end - start
    }

    /// Whether this region is empty (zero length)
    public var isEmpty: Bool {
        length == 0
    }

    /// Returns the center position of this region
    public var center: Int {
        start + length / 2
    }

    /// Checks if this region contains the specified position
    public func contains(position: Int) -> Bool {
        position >= start && position < end
    }

    /// Checks if this region fully contains another region
    public func contains(_ other: GenomicRegion) -> Bool {
        guard chromosome == other.chromosome else { return false }
        return start <= other.start && end >= other.end
    }

    /// Checks if this region overlaps with another region
    public func overlaps(_ other: GenomicRegion) -> Bool {
        guard chromosome == other.chromosome else { return false }
        guard !isEmpty, !other.isEmpty else { return false }
        return start < other.end && end > other.start
    }

    /// Returns the intersection of this region with another, or nil if they don't overlap
    public func intersection(_ other: GenomicRegion) -> GenomicRegion? {
        guard overlaps(other) else { return nil }
        return GenomicRegion(
            chromosome: chromosome,
            start: max(start, other.start),
            end: min(end, other.end)
        )
    }

    /// Returns the union (bounding box) of this region with another on the same chromosome
    public func union(_ other: GenomicRegion) -> GenomicRegion? {
        guard chromosome == other.chromosome else { return nil }
        return GenomicRegion(
            chromosome: chromosome,
            start: min(start, other.start),
            end: max(end, other.end)
        )
    }

    /// Returns a new region expanded by the specified amount on each side
    public func expanded(by amount: Int) -> GenomicRegion {
        GenomicRegion(
            chromosome: chromosome,
            start: max(0, start - amount),
            end: end + amount
        )
    }

    /// Returns the distance to another region, or 0 if they overlap
    public func distance(to other: GenomicRegion) -> Int? {
        guard chromosome == other.chromosome else { return nil }
        if overlaps(other) { return 0 }
        if end <= other.start {
            return other.start - end
        } else {
            return start - other.end
        }
    }
}

// MARK: - CustomStringConvertible

extension GenomicRegion: CustomStringConvertible {
    public var description: String {
        "\(chromosome):\(start)-\(end)"
    }
}

// MARK: - Comparable

extension GenomicRegion: Comparable {
    public static func < (lhs: GenomicRegion, rhs: GenomicRegion) -> Bool {
        if lhs.chromosome != rhs.chromosome {
            return lhs.chromosome < rhs.chromosome
        }
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.end < rhs.end
    }
}

// MARK: - Range Conversion

extension GenomicRegion {
    /// Converts to a Swift Range for array subscripting
    public var range: Range<Int> {
        start..<end
    }

    /// Creates a GenomicRegion from a chromosome and range
    public init(chromosome: String, range: Range<Int>) {
        self.init(chromosome: chromosome, start: range.lowerBound, end: range.upperBound)
    }
}

// MARK: - Display String (SCI-13)

extension GenomicRegion {
    /// The single, canonical way to show or copy a region as text:
    /// 1-based, closed (`chrom:start-end`), with thousands separators on each
    /// number (matching how the coordinate ruler already displays a range).
    ///
    /// Internal storage is 0-based half-open `[start, end)`. The equivalent
    /// 1-based closed range is `[start+1, end]`. Every user-visible
    /// `chr:start-end` string in the app (ruler display, Copy Coordinates,
    /// FASTA headers, CLI region echoes) should be built from this property
    /// instead of ad hoc interpolation of the raw 0-based fields, so the
    /// displayed convention is always the same one `LocusQueryParser` accepts
    /// back in.
    ///
    /// A single-base region (`length == 1`) displays as `chrom:pos` rather
    /// than `chrom:pos-pos`, matching common usage (e.g. a SNP position).
    public var displayString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","

        func formatted(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        let displayStart = start + 1
        if isEmpty {
            // A zero-length region has no 1-based closed representation;
            // show the boundary position it sits before.
            return "\(chromosome):\(formatted(displayStart))"
        }
        if end == displayStart {
            return "\(chromosome):\(formatted(displayStart))"
        }
        return "\(chromosome):\(formatted(displayStart))-\(formatted(end))"
    }
}
