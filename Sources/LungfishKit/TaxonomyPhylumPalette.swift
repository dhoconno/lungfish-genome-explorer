// TaxonomyPhylumPalette.swift - Colorblind-safe phylum color palette for taxonomy views
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - PhylumPalette

/// Colorblind-safe color palette for the top 20 phyla in taxonomy visualizations.
///
/// Colors are assigned by phylum (the third rank in the taxonomy hierarchy). All
/// taxa within a phylum share the same base hue. Deeper ranks use the same hue
/// at progressively lighter tints (decreasing saturation, increasing brightness),
/// creating natural visual grouping in sunburst charts.
///
/// The palette is designed to be:
/// - Distinguishable for people with protanopia, deuteranopia, and tritanopia
/// - Legible in both light and dark mode
/// - Distinct from UI chrome (no grays, no pure whites)
///
/// ## Depth Tinting
///
/// For a node at depth `d` below its phylum ancestor:
/// ```
/// saturation = base.saturation * (1.0 - 0.12 * d)   // clamped >= 0.15
/// brightness = min(0.95, base.brightness + 0.06 * d) // clamped <= 0.95
/// ```
@MainActor
public enum PhylumPalette {

    // MARK: - Palette Definition

    /// The 20 phylum color slots, defined as dynamic colors that adapt to light/dark mode.
    ///
    /// | Slot | Example Phylum                      | Light Hex | Dark Hex |
    /// |------|-------------------------------------|-----------|----------|
    /// |   0  | Pseudomonadota (Proteobacteria)     | #4A90D9   | #6BABEF  |
    /// |   1  | Bacillota (Firmicutes)              | #E8853D   | #F0A060  |
    /// |   2  | Actinomycetota (Actinobacteria)     | #4CAF50   | #6ECF72  |
    /// |   3  | Bacteroidota (Bacteroidetes)        | #D64541   | #E86E6A  |
    /// |   4  | Cyanobacteriota                     | #26A69A   | #4CC8BC  |
    /// |   5  | Chloroflexota                       | #F2B825   | #F5CA55  |
    /// |   6  | Planctomycetota                     | #9C5BB5   | #B880D0  |
    /// |   7  | Verrucomicrobiota                   | #E57399   | #F09AB8  |
    /// |   8  | Spirochaetota                       | #00ACC1   | #33CCDD  |
    /// |   9  | Deinococcota                        | #A07855   | #C09878  |
    /// |  10  | Tenericutes                         | #7986CB   | #9AA4E0  |
    /// |  11  | Fusobacteriota                      | #EF6C6C   | #F59090  |
    /// |  12  | Chlamydiota                         | #8BC34A   | #A8D870  |
    /// |  13  | Euryarchaeota                       | #7B1FA2   | #A050C8  |
    /// |  14  | Ascomycota                          | #FFB74D   | #FFCC80  |
    /// |  15  | Basidiomycota                       | #009688   | #33B8AA  |
    /// |  16  | Chordata                            | #607D8B   | #8AA0AC  |
    /// |  17  | Arthropoda                          | #C2185B   | #E04080  |
    /// |  18  | Nematoda                            | #CDDC39   | #DBE868  |
    /// |  19  | Other / overflow                    | #9E9E9E   | #BDBDBD  |
    public static let phylumColors: [NSColor] = [
        dynamicColor(light: (0x4A, 0x90, 0xD9), dark: (0x6B, 0xAB, 0xEF)),  // 0: Proteobacteria
        dynamicColor(light: (0xE8, 0x85, 0x3D), dark: (0xF0, 0xA0, 0x60)),  // 1: Firmicutes
        dynamicColor(light: (0x4C, 0xAF, 0x50), dark: (0x6E, 0xCF, 0x72)),  // 2: Actinobacteria
        dynamicColor(light: (0xD6, 0x45, 0x41), dark: (0xE8, 0x6E, 0x6A)),  // 3: Bacteroidetes
        dynamicColor(light: (0x26, 0xA6, 0x9A), dark: (0x4C, 0xC8, 0xBC)),  // 4: Cyanobacteria
        dynamicColor(light: (0xF2, 0xB8, 0x25), dark: (0xF5, 0xCA, 0x55)),  // 5: Chloroflexota
        dynamicColor(light: (0x9C, 0x5B, 0xB5), dark: (0xB8, 0x80, 0xD0)),  // 6: Planctomycetota
        dynamicColor(light: (0xE5, 0x73, 0x99), dark: (0xF0, 0x9A, 0xB8)),  // 7: Verrucomicrobiota
        dynamicColor(light: (0x00, 0xAC, 0xC1), dark: (0x33, 0xCC, 0xDD)),  // 8: Spirochaetota
        dynamicColor(light: (0xA0, 0x78, 0x55), dark: (0xC0, 0x98, 0x78)),  // 9: Deinococcota
        dynamicColor(light: (0x79, 0x86, 0xCB), dark: (0x9A, 0xA4, 0xE0)),  // 10: Tenericutes
        dynamicColor(light: (0xEF, 0x6C, 0x6C), dark: (0xF5, 0x90, 0x90)),  // 11: Fusobacteriota
        dynamicColor(light: (0x8B, 0xC3, 0x4A), dark: (0xA8, 0xD8, 0x70)),  // 12: Chlamydiota
        dynamicColor(light: (0x7B, 0x1F, 0xA2), dark: (0xA0, 0x50, 0xC8)),  // 13: Euryarchaeota
        dynamicColor(light: (0xFF, 0xB7, 0x4D), dark: (0xFF, 0xCC, 0x80)),  // 14: Ascomycota
        dynamicColor(light: (0x00, 0x96, 0x88), dark: (0x33, 0xB8, 0xAA)),  // 15: Basidiomycota
        dynamicColor(light: (0x60, 0x7D, 0x8B), dark: (0x8A, 0xA0, 0xAC)),  // 16: Chordata
        dynamicColor(light: (0xC2, 0x18, 0x5B), dark: (0xE0, 0x40, 0x80)),  // 17: Arthropoda
        dynamicColor(light: (0xCD, 0xDC, 0x39), dark: (0xDB, 0xE8, 0x68)),  // 18: Nematoda
        dynamicColor(light: (0x9E, 0x9E, 0x9E), dark: (0xBD, 0xBD, 0xBD)),  // 19: Other
    ]

    /// The number of distinct phylum color slots in the palette.
    public static let slotCount: Int = 20

    // MARK: - Color Assignment

    /// Returns the phylum-level base color for a slot index.
    ///
    /// Indices beyond the palette size wrap using modular arithmetic, with the
    /// last slot (19) reserved for "Other / overflow".
    ///
    /// - Parameter index: Zero-based phylum slot index.
    /// - Returns: The phylum base color.
    public static func phylumColor(index: Int) -> NSColor {
        guard index >= 0, index < phylumColors.count else {
            return phylumColors[slotCount - 1]  // overflow -> "Other" gray
        }
        return phylumColors[index]
    }

    /// Returns the display color for a given taxon node.
    ///
    /// The color is determined by the node's phylum ancestor. All taxa within
    /// the same phylum share a base hue, with progressively lighter tints at
    /// deeper levels.
    ///
    /// - Parameter node: The taxon node to color.
    /// - Returns: An appearance-adaptive `NSColor` for the node.
    public static func color(for node: TaxonNode) -> NSColor {
        let (phylumIndex, depthBelowPhylum) = phylumInfo(for: node)
        let baseColor = phylumColor(index: phylumIndex)
        if depthBelowPhylum == 0 {
            return baseColor
        }
        return tintedColor(base: baseColor, depthBelowPhylum: depthBelowPhylum)
    }

    /// Returns the "Other" / aggregation color used for tiny segments.
    public static var otherColor: NSColor {
        NSColor.tertiaryLabelColor
    }

    // MARK: - Phylum Index Resolution

    /// Finds the phylum ancestor of a node and returns its palette index and
    /// the number of ranks between the phylum and the node.
    ///
    /// The palette index is derived from the phylum node's `taxId`, hashed into
    /// the 20-slot palette. Nodes above phylum rank (root, domain, kingdom) use
    /// a hash of their own `taxId`.
    ///
    /// - Parameter node: The taxon node.
    /// - Returns: A tuple of (phylum slot index, depth below phylum).
    public static func phylumInfo(for node: TaxonNode) -> (phylumIndex: Int, depthBelowPhylum: Int) {
        // Walk up to find the phylum ancestor
        var current: TaxonNode? = node
        var stepsFromNode = 0

        while let n = current {
            if n.rank == .phylum {
                let index = stablePhylumIndex(taxId: n.taxId)
                return (index, stepsFromNode)
            }
            // If we've reached a rank above phylum, stop
            if n.rank == .root || n.rank == .domain || n.rank == .kingdom {
                // Nodes at or above phylum: hash their own taxId
                let index = stablePhylumIndex(taxId: node.taxId)
                return (index, 0)
            }
            current = n.parent
            stepsFromNode += 1
        }

        // Fallback: no phylum ancestor found (e.g., unclassified)
        let index = stablePhylumIndex(taxId: node.taxId)
        return (index, 0)
    }

    /// Maps a taxonomy ID to a stable palette slot index (0..<19).
    ///
    /// Slot 19 is reserved for "Other", so real taxa map into 0..<19.
    /// Uses a simple multiplicative hash for stable, uniform distribution.
    ///
    /// - Parameter taxId: The NCBI taxonomy ID.
    /// - Returns: A palette slot index in `0..<19`.
    static func stablePhylumIndex(taxId: Int) -> Int {
        // Multiplicative hash (Knuth variant) for good distribution
        let hash = UInt64(bitPattern: Int64(taxId)) &* 0x9E3779B97F4A7C15
        return Int(hash % UInt64(slotCount - 1))
    }

    // MARK: - Depth Tinting

    /// Applies depth-based tinting to a base phylum color.
    ///
    /// The tinting formula:
    /// - Saturation decreases by 12% per depth level (clamped at 0.15)
    /// - Brightness increases by 6% per depth level (capped at 0.95)
    ///
    /// - Parameters:
    ///   - base: The phylum base color.
    ///   - depthBelowPhylum: Number of ranks below the phylum.
    /// - Returns: A tinted color at the specified depth.
    public static func tintedColor(base: NSColor, depthBelowPhylum: Int) -> NSColor {
        guard depthBelowPhylum > 0 else { return base }

        // Create a dynamic color that adapts to appearance.
        // Inside the NSColor(name:) provider, the appearance parameter tells us
        // whether we are in light or dark mode. We resolve the base color under
        // that appearance using performAsCurrentDrawingAppearance.
        return NSColor(name: nil) { appearance in
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0

            // Resolve the base color under the target appearance so that
            // dynamic colors (like our palette) resolve to the correct variant.
            appearance.performAsCurrentDrawingAppearance {
                let rgbColor = base.usingColorSpace(.sRGB) ?? base
                rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            }

            let d = CGFloat(depthBelowPhylum)
            let newSaturation = max(0.15, saturation * (1.0 - 0.12 * d))
            let newBrightness = min(0.95, brightness + 0.06 * d)

            return NSColor(
                hue: hue,
                saturation: newSaturation,
                brightness: newBrightness,
                alpha: alpha
            )
        }
    }

    // MARK: - Contrast Helpers

    /// Returns black or white, whichever provides better contrast against the
    /// given background color, per WCAG luminance ratio guidelines.
    ///
    /// - Parameter background: The background color.
    /// - Returns: `.white` or `.black`.
    public static func contrastingTextColor(for background: NSColor) -> NSColor {
        let resolved = background.usingColorSpace(.sRGB) ?? background
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)

        // Relative luminance (WCAG 2.0)
        let luminance = relativeLuminance(r: r, g: g, b: b)

        // Use white text on dark backgrounds, black on light
        return luminance > 0.4 ? .black : .white
    }

    /// Computes the relative luminance of an sRGB color per WCAG 2.0.
    ///
    /// - Parameters:
    ///   - r: Red component (0...1).
    ///   - g: Green component (0...1).
    ///   - b: Blue component (0...1).
    /// - Returns: Relative luminance (0...1).
    public static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    // MARK: - Private Helpers

    /// Creates a dynamic `NSColor` that adapts between light and dark appearances.
    private static func dynamicColor(
        light: (UInt8, UInt8, UInt8),
        dark: (UInt8, UInt8, UInt8)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }
}
