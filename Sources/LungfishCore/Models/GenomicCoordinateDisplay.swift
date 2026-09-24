// GenomicCoordinateDisplay.swift - stored 0-based half-open <-> displayed 1-based closed
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Converts between the app's stored coordinate convention and the one users see.
///
/// Every reader (GenBank, GFF, BED, VCF) normalises features to 0-based half-open
/// `[start, end)` before they reach an index or a table. The UI, the ruler,
/// Go to Location and `GenomicRegion.displayString` all show 1-based closed
/// `[start+1, end]`, which is what the source GenBank or GFF record printed.
/// Any table cell, tooltip, form field or filter clause that shows or reads a
/// single coordinate should go through these helpers rather than adding or
/// subtracting 1 inline, so the convention is applied in exactly one place.
public enum GenomicCoordinateDisplay {
    /// The 1-based inclusive start for a stored 0-based start.
    public static func displayStart(_ storedStart: Int) -> Int {
        storedStart + 1
    }

    /// The 1-based inclusive end for a stored exclusive end. Numerically identical,
    /// named so call sites read symmetrically with `displayStart`.
    public static func displayEnd(_ storedEnd: Int) -> Int {
        storedEnd
    }

    /// The stored 0-based start for a 1-based start typed or shown to a user.
    public static func storedStart(fromDisplay displayStart: Int) -> Int {
        displayStart - 1
    }

    /// The stored exclusive end for a 1-based inclusive end typed or shown to a user.
    public static func storedEnd(fromDisplay displayEnd: Int) -> Int {
        displayEnd
    }

    /// Stored interval length; identical for both conventions.
    public static func displayLength(storedStart: Int, storedEnd: Int) -> Int {
        storedEnd - storedStart
    }

    /// `displayStart` with thousands separators, matching the ruler.
    public static func formattedStart(_ storedStart: Int) -> String {
        formatted(displayStart(storedStart))
    }

    /// `displayEnd` with thousands separators, matching the ruler.
    public static func formattedEnd(_ storedEnd: Int) -> String {
        formatted(displayEnd(storedEnd))
    }

    private static func formatted(_ value: Int) -> String {
        // NumberFormatter is not Sendable, so build one per call rather than
        // caching it in a static (mirrors GenomicRegion.displayString).
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
